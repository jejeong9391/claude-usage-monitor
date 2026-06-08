import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var onRefresh: () -> Void
    var onQuit: () -> Void

    var body: some View {
        ZStack {
            Theme.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.05))
                content
                Divider().background(Color.white.opacity(0.05))
                footer
            }
        }
        .frame(width: 420, height: 640)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accentSoft)
                Image(systemName: "flame.fill")
                    .foregroundColor(Theme.accent)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("공식 사용량 · api.anthropic.com")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("새로고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if case .noToken = store.officialState {
                    notice("Claude Code 로그인 필요", "Keychain 에서 자격증명을 찾지 못했습니다. 터미널에서 Claude Code 에 로그인하세요.", "lock")
                } else if case .unauthorized = store.officialState {
                    notice("토큰 만료 — 재인증 필요", "Claude Code 를 한 번 사용하면 토큰이 자동 갱신됩니다.", "exclamationmark.triangle")
                } else if store.official == nil, store.officialState.isError {
                    notice("공식 데이터 오프라인", "네트워크 연결을 확인하세요.", "wifi.slash")
                }

                if let off = store.official {
                    if store.officialState.isError {
                        offlineBadge
                    }
                    fiveHourCard(off.fiveHour)
                    weeklyCard(off.sevenDay)
                    if let sonnet = off.sevenDaySonnet { sonnetCard(sonnet) }
                    if let opus = off.sevenDayOpus { opusCard(opus) }
                    if let extra = off.extraUsage, extra.isEnabled == true { extraCard(extra) }
                }

                if let b = store.block {
                    costCard(b)
                    tokenCard(b)
                } else if store.official != nil {
                    Text("활성 5h 블록 없음 — 상세(비용·토큰) 미표시")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.loading && store.official == nil {
                    ProgressView().controlSize(.large).padding(.top, 40)
                }
                disclaimer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    // MARK: Cards (공식)

    @ViewBuilder
    func fiveHourCard(_ w: UsageWindow?) -> some View {
        let pct = w?.utilization ?? 0
        let color = Theme.percentColor(pct)
        let reset = parseDate(w?.resetsAt)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(pct.rounded()))%")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                        Text("현재 5시간 세션")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if let b = store.block {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "$%.2f", b.costUSD))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.textPrimary)
                            Text("현재 비용")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                ProgressBar(percent: pct, color: color, height: 10)
                HStack(spacing: 8) {
                    StatChip(label: "재설정까지", value: compactRemaining(until: reset))
                    StatChip(label: "재설정 시각", value: formatResetClock(reset))
                    if let b = store.block {
                        StatChip(label: "entries", value: "\(b.entries)")
                    }
                }
                if let b = store.block, !b.models.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
                        Text(b.models.map { $0.replacingOccurrences(of: "claude-", with: "") }.joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func weeklyCard(_ w: UsageWindow?) -> some View {
        let pct = w?.utilization ?? 0
        let color = Theme.percentColor(pct)
        let reset = parseDate(w?.resetsAt)
        Card("주간 한도 · 모든 모델") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                    Spacer()
                    if let c = store.weeklyCost {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "$%.2f", c))
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Text("주간 비용").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                ProgressBar(percent: pct, color: color, height: 8)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
                    Text("\(friendlyRemaining(until: reset)) · \(formatResetClock(reset))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    func smallWindowCard(_ title: String, _ w: UsageWindow) -> some View {
        let pct = w.utilization
        let color = Theme.percentColor(pct)
        Card(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                    Spacer()
                    Text(friendlyRemaining(until: parseDate(w.resetsAt)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                ProgressBar(percent: pct, color: color, height: 6)
            }
        }
    }

    @ViewBuilder func sonnetCard(_ w: UsageWindow) -> some View { smallWindowCard("주간 한도 · Sonnet 전용", w) }
    @ViewBuilder func opusCard(_ w: UsageWindow) -> some View { smallWindowCard("주간 한도 · Opus 전용", w) }

    @ViewBuilder
    func extraCard(_ e: ExtraUsage) -> some View {
        Card("추가 사용량 크레딧") {
            VStack(spacing: 8) {
                if let u = e.utilization {
                    ProgressBar(percent: u, color: Theme.accent, height: 6)
                }
                KVRow(label: "사용 크레딧",
                      value: String(format: "%@ %.2f", e.currency ?? "$", e.usedCredits ?? 0))
                if let limit = e.monthlyLimit {
                    KVRow(label: "월 한도", value: String(format: "%@ %.2f", e.currency ?? "$", limit))
                }
            }
        }
    }

    // MARK: Cards (ccusage 상세)

    @ViewBuilder
    func costCard(_ b: Block) -> some View {
        Card("비용 (ccusage 추정)") {
            VStack(spacing: 8) {
                KVRow(label: "현재", value: String(format: "$%.2f", b.costUSD))
                if let br = b.burnRate, let cph = br.costPerHour {
                    KVRow(label: "Burn rate", value: String(format: "$%.2f / hr", cph), valueColor: Theme.accent)
                }
                if let p = b.projection {
                    KVRow(label: "예측 (블록 종료시)",
                          value: String(format: "$%.2f · %@", p.totalCost ?? 0, formatNum(p.totalTokens ?? 0)),
                          valueColor: Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    func tokenCard(_ b: Block) -> some View {
        let tc = b.tokenCounts
        let maxV = Swift.max(tc.inputTokens, tc.outputTokens, tc.cacheCreationInputTokens, tc.cacheReadInputTokens)
        Card("토큰 세부 (ccusage 추정)") {
            VStack(spacing: 8) {
                TokenBarRow(label: "입력",  value: tc.inputTokens,              max: maxV, color: .blue)
                TokenBarRow(label: "출력",  value: tc.outputTokens,             max: maxV, color: .green)
                TokenBarRow(label: "캐시W", value: tc.cacheCreationInputTokens, max: maxV, color: .purple)
                TokenBarRow(label: "캐시R", value: tc.cacheReadInputTokens,     max: maxV, color: .teal)
                Divider().background(Color.white.opacity(0.06))
                KVRow(label: "총합", value: formatNum(tc.total))
            }
        }
    }

    // MARK: Misc

    @ViewBuilder
    func notice(_ title: String, _ body: String, _ icon: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(Theme.warn)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text(body).font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var offlineBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundColor(Theme.warn)
            Text("공식 데이터 갱신 실패 — 직전 값 표시 중")
                .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            Spacer()
        }
    }

    var disclaimer: some View {
        Text("%·재설정 시각은 Anthropic 공식 사용량 기준. 비용·토큰은 ccusage 로컬 추정치(참고용).")
            .font(.system(size: 9))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    var footer: some View {
        HStack {
            Image(systemName: "clock").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
            Text("갱신 \(formatTimeOnly(store.lastUpdate))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            Button(action: onQuit) {
                Text("종료")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
