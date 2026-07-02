import AppKit
import SwiftUI

enum PopoverSection: String, CaseIterable, Identifiable {
    case usage = "사용량"
    case settings = "설정"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .usage: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: UpdateService
    var onRefresh: () -> Void
    var onPrimaryProviderChange: () -> Void
    var onQuit: () -> Void

    @State private var section: PopoverSection = .usage
    @State private var openAIKeyInput = ""
    @State private var cursorKeyInput = ""
    @State private var anthropicAdminKeyInput = ""
    @State private var selectedProvider: AIProviderKind?
    @State private var settingsProvider: AIProviderKind = .claude

    var visibleProvider: AIProviderKind { selectedProvider ?? store.primaryProvider }
    var visibleSnapshot: ProviderSnapshot {
        store.snapshot(for: visibleProvider) ?? store.primarySnapshot
    }

    var body: some View {
        ZStack {
            Theme.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.06))
                if section == .usage {
                    providerTabsBar
                    Divider().background(Color.white.opacity(0.06))
                }
                content
                Divider().background(Color.white.opacity(0.06))
                footer
            }
        }
        .frame(width: 460, height: 680)
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    var header: some View {
        let snapshot = section == .usage ? visibleSnapshot : store.primarySnapshot
        let color = providerColor(snapshot.provider)
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: snapshot.provider.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(snapshot.title) · \(snapshot.sourceKind.label) · \(snapshot.confidence.label)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            IconButton(symbol: "arrow.clockwise", action: onRefresh, help: "새로고침")
            if section == .settings {
                HeaderActionButton(symbol: "chart.bar.xaxis", title: "사용량") {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        selectedProvider = settingsProvider
                        section = .usage
                    }
                }
            } else {
                IconButton(
                    symbol: "gearshape",
                    action: {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            settingsProvider = visibleProvider
                            section = .settings
                        }
                    },
                    help: "설정"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var providerTabsBar: some View {
        HStack(spacing: 6) {
            ForEach(AIProviderKind.allCases) { provider in
                ProviderTab(
                    provider: provider,
                    snapshot: store.snapshot(for: provider),
                    isSelected: visibleProvider == provider,
                    isMenuBarDefault: store.primaryProvider == provider,
                    action: { selectedProvider = provider }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if section == .usage {
                    usageContent(for: visibleProvider)
                } else {
                    settingsContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            Text("메뉴바 \(store.primaryProvider.displayName)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundColor(Theme.textTertiary)
            Text(formatTimeOnly(store.lastUpdate))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            updateControl
            Button(action: onQuit) {
                Text("종료")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Usage

    @ViewBuilder
    func usageContent(for provider: AIProviderKind) -> some View {
        switch provider {
        case .claude:
            claudeUsage
        case .openAI:
            setupUsage(
                snapshot: store.snapshot(for: .openAI) ?? visibleSnapshot,
                title: "OpenAI API 사용량",
                body: "공식 Usage API와 Cost API로 API 사용량을 가져오는 구조입니다. Admin key와 조직 정보를 설정하면 수집기를 붙일 준비가 됩니다.",
                metrics: ["일 비용", "입력/출력 토큰", "모델별 비용", "프로젝트/API key 기준 그룹"],
                credentialReady: store.hasOpenAIAdminKey
            )
        case .codex:
            codexUsage
        case .cursor:
            setupUsage(
                snapshot: store.snapshot(for: .cursor) ?? visibleSnapshot,
                title: "Cursor 팀 사용량",
                body: "Cursor Team API key로 Admin/Analytics API를 연결하면 요청 수, 토큰, 비용, 주 사용 모델을 표시할 수 있습니다.",
                metrics: ["Composer/Chat/Agent 요청", "토큰 사용량", "charged cents", "주 사용 모델"],
                credentialReady: store.hasCursorTeamKey
            )
        }
    }

    var codexUsage: some View {
        Group {
            if store.codexLocalSession.isLoggedIn {
                codexSessionCard
                sourceFootnote("Codex 로그인은 로컬 캐시 또는 codex login status로 자동 감지합니다. 토큰 값은 저장하거나 표시하지 않습니다.")
            } else {
                setupUsage(
                    snapshot: store.snapshot(for: .codex) ?? visibleSnapshot,
                    title: "Codex 로컬 로그인",
                    body: (store.snapshot(for: .codex) ?? visibleSnapshot).stateMessage,
                    metrics: ["Codex CLI 로그인 상태", "ChatGPT/API key 인증 방식", "개인 Codex quota는 공식 API 확인 후 연결"],
                    credentialReady: false
                )
            }
        }
    }

    var codexSessionCard: some View {
        let session = store.codexLocalSession
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(providerColor(.codex).opacity(0.16))
                        Image(systemName: AIProviderKind.codex.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(providerColor(.codex))
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex 로컬 세션")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("현재 Mac의 Codex 로그인을 감지했습니다. 개인 Codex 사용량 수치는 공식 API가 확인되기 전까지 표시하지 않습니다.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StateBadge(text: "로그인됨", color: Theme.success)
                }

                VStack(spacing: 9) {
                    SettingStatusRow(label: "로그인 방식", value: session.authModeLabel, color: Theme.textSecondary)
                    SettingStatusRow(label: "계정 식별자", value: session.accountLabel, color: session.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                    SettingStatusRow(label: "자격증명 위치", value: session.credentialLocationLabel, color: Theme.textSecondary)
                    SettingStatusRow(label: "마지막 갱신", value: formatResetClock(session.lastRefresh), color: session.lastRefresh == nil ? Theme.textTertiary : Theme.textSecondary)
                    Divider().background(Color.white.opacity(0.06))
                    SettingStatusRow(label: "사용량 수집", value: "공식 개인 API 없음", color: Theme.textTertiary)
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        settingsProvider = .codex
                        section = .settings
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("Codex 설정")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    var claudeUsage: some View {
        Group {
            claudeNotice

            if store.loading && store.official == nil {
                loadingCard("Claude 공식 사용량을 불러오는 중입니다.")
            } else if let off = store.official {
                if store.officialState.isError {
                    inlineStatus("공식 데이터 갱신 실패", "직전 공식 값을 유지해서 표시 중입니다.", "wifi.slash", Theme.warn)
                }
                claudeOverviewCard(off.fiveHour)
                claudeLimitsCard(off)
                if let b = store.block {
                    claudeSessionCard(b)
                } else {
                    inlineStatus("활성 5시간 블록 없음", "비용과 토큰 상세는 ccusage 활성 블록이 있을 때 표시합니다.", "clock", Theme.textTertiary)
                }
            } else {
                setupUsage(
                    snapshot: store.snapshot(for: .claude) ?? visibleSnapshot,
                    title: "Claude 사용량",
                    body: (store.snapshot(for: .claude) ?? visibleSnapshot).stateMessage,
                    metrics: ["5시간 사용률", "주간 한도", "ccusage 비용/토큰 추정"],
                    credentialReady: false
                )
            }

            sourceFootnote("Claude %와 reset은 Anthropic 공식 사용량 기준입니다. 비용과 토큰은 ccusage 로컬 추정치입니다.")
        }
    }

    @ViewBuilder
    var claudeNotice: some View {
        if case .noToken = store.officialState {
            inlineStatus("Claude Code 로그인 필요", "Keychain에서 Claude Code 자격증명을 찾지 못했습니다.", "lock", Theme.warn)
        } else if case .unauthorized = store.officialState {
            inlineStatus("토큰 만료", "Claude Code를 한 번 사용하면 토큰이 자동 갱신됩니다.", "exclamationmark.triangle", Theme.warn)
        } else if case .rateLimited = store.officialState {
            inlineStatus("사용량 API 호출 제한", "잠시 후 자동 갱신에서 다시 시도합니다.", "hourglass", Theme.warn)
        } else if store.official == nil, store.officialState.isError {
            inlineStatus("공식 데이터 오프라인", "네트워크 연결 또는 Anthropic API 응답을 확인하세요.", "wifi.slash", Theme.warn)
        }
    }

    @ViewBuilder
    func claudeOverviewCard(_ window: UsageWindow?) -> some View {
        let pct = window?.utilization ?? 0
        let reset = parseDate(window?.resetsAt)
        let color = Theme.percentColor(pct)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(pct.rounded()))%")
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("현재 5시간 세션")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        StateBadge(
                            text: (store.snapshot(for: .claude) ?? visibleSnapshot).state.label,
                            color: stateColor((store.snapshot(for: .claude) ?? visibleSnapshot).state)
                        )
                        Text(formatResetClock(reset))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }

                ProgressBar(percent: pct, color: color, height: 9)

                HStack(spacing: 10) {
                    MetricTile(label: "재설정", value: compactRemaining(until: reset))
                    MetricTile(label: "비용", value: store.block.map { String(format: "$%.2f", $0.costUSD) } ?? "—")
                    MetricTile(label: "토큰", value: store.block.map { formatNum($0.tokenCounts.total) } ?? "—")
                    MetricTile(label: "요청", value: store.block.map { "\($0.entries)" } ?? "—")
                }

                if let models = store.block?.models, !models.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                        Text(models.map { $0.replacingOccurrences(of: "claude-", with: "") }.joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func claudeLimitsCard(_ usage: OfficialUsage) -> some View {
        Card("한도") {
            VStack(spacing: 10) {
                UsageWindowRow(title: "주간 · 모든 모델", window: usage.sevenDay, trailing: store.weeklyCost.map { String(format: "$%.2f", $0) })
                if let sonnet = usage.sevenDaySonnet {
                    Divider().background(Color.white.opacity(0.06))
                    UsageWindowRow(title: "주간 · Sonnet", window: sonnet, trailing: nil)
                }
                if let opus = usage.sevenDayOpus {
                    Divider().background(Color.white.opacity(0.06))
                    UsageWindowRow(title: "주간 · Opus", window: opus, trailing: nil)
                }
                if let extra = usage.extraUsage, extra.isEnabled == true {
                    Divider().background(Color.white.opacity(0.06))
                    extraUsageRow(extra)
                }
            }
        }
    }

    @ViewBuilder
    func extraUsageRow(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("추가 사용량 크레딧")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(String(format: "%@ %.2f", extra.currency ?? "$", extra.usedCredits ?? 0))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            if let utilization = extra.utilization {
                ProgressBar(percent: utilization, color: Theme.accent, height: 6)
            }
        }
    }

    @ViewBuilder
    func claudeSessionCard(_ block: Block) -> some View {
        Card("세션 상세 · ccusage") {
            VStack(spacing: 10) {
                KVRow(label: "현재 비용", value: String(format: "$%.2f", block.costUSD))
                if let burnRate = block.burnRate?.costPerHour {
                    KVRow(label: "Burn rate", value: String(format: "$%.2f / hr", burnRate), valueColor: Theme.accent)
                }
                if let projection = block.projection {
                    KVRow(
                        label: "종료 예상",
                        value: String(format: "$%.2f · %@", projection.totalCost ?? 0, formatNum(projection.totalTokens ?? 0)),
                        valueColor: Theme.textSecondary
                    )
                }
                Divider().background(Color.white.opacity(0.06))
                let tc = block.tokenCounts
                let maxV = Swift.max(tc.inputTokens, tc.outputTokens, tc.cacheCreationInputTokens, tc.cacheReadInputTokens)
                TokenBarRow(label: "입력", value: tc.inputTokens, max: maxV, color: .blue)
                TokenBarRow(label: "출력", value: tc.outputTokens, max: maxV, color: .green)
                TokenBarRow(label: "캐시W", value: tc.cacheCreationInputTokens, max: maxV, color: .purple)
                TokenBarRow(label: "캐시R", value: tc.cacheReadInputTokens, max: maxV, color: .teal)
            }
        }
    }

    @ViewBuilder
    func setupUsage(
        snapshot: ProviderSnapshot,
        title: String,
        body: String,
        metrics: [String],
        credentialReady: Bool
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(providerColor(snapshot.provider).opacity(0.16))
                        Image(systemName: snapshot.provider.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(providerColor(snapshot.provider))
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(body)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StateBadge(text: credentialReady ? "설정됨" : snapshot.state.label, color: credentialReady ? Theme.success : stateColor(snapshot.state))
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(metrics, id: \.self) { metric in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(credentialReady ? Theme.success : Theme.textTertiary)
                            Text(metric)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                        }
                    }
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        settingsProvider = snapshot.provider
                        section = .settings
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text(credentialReady ? "설정 확인" : "계정 설정")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        sourceFootnote("연결 전 상태는 사용량 0이 아닙니다. 자격증명 또는 공식 API 지원 여부를 명확히 분리해 표시합니다.")
    }

    @ViewBuilder
    func unavailableUsage(snapshot: ProviderSnapshot, title: String, body: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(providerColor(snapshot.provider).opacity(0.16))
                        Image(systemName: snapshot.provider.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(providerColor(snapshot.provider))
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(body)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StateBadge(text: "수집 미지원", color: Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    UnsupportedRow(text: "Codex 자체를 사용할 수 없다는 뜻이 아닙니다.")
                    UnsupportedRow(text: "개인 Codex quota를 OpenAI API 사용량과 합산하지 않습니다.")
                    UnsupportedRow(text: "공식 사용량 API가 확인되면 이 provider에 연결합니다.")
                }
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder
    var settingsContent: some View {
        mainProviderSettings
        localDiscoveryCard
        settingsProviderTabs
        if let message = store.settingsMessage {
            inlineStatus("설정 변경", message, "checkmark.circle", Theme.success)
        }
        settingsDetail(for: settingsProvider)
        settingsReviewCard
    }

    var localDiscoveryCard: some View {
        Card("로컬 자동 감지") {
            VStack(spacing: 9) {
                LocalSessionRow(
                    provider: "Claude",
                    state: store.claudeLocalSession.state.label,
                    detail: store.claudeLocalSession.statusText ?? "Claude Code OAuth 감지 상태",
                    color: sessionColor(store.claudeLocalSession)
                )
                Divider().background(Color.white.opacity(0.06))
                LocalSessionRow(
                    provider: "OpenAI",
                    state: store.openAILocalSession.state.label,
                    detail: store.openAILocalSession.statusText ?? "OpenAI API 자격증명 감지 상태",
                    color: sessionColor(store.openAILocalSession)
                )
                Divider().background(Color.white.opacity(0.06))
                LocalSessionRow(
                    provider: "Codex",
                    state: store.codexLocalSession.state.label,
                    detail: store.codexLocalSession.statusText ?? "Codex CLI 세션 감지 상태",
                    color: sessionColor(store.codexLocalSession)
                )
                Divider().background(Color.white.opacity(0.06))
                LocalSessionRow(
                    provider: "Cursor",
                    state: store.cursorLocalSession.state.label,
                    detail: store.cursorLocalSession.statusText ?? "Cursor 앱/Team key 감지 상태",
                    color: sessionColor(store.cursorLocalSession)
                )
            }
        }
    }

    var settingsProviderTabs: some View {
        Card("AI 계정 설정") {
            HStack(spacing: 6) {
                ForEach(AIProviderKind.allCases) { provider in
                    ProviderTab(
                        provider: provider,
                        snapshot: store.snapshot(for: provider),
                        isSelected: settingsProvider == provider,
                        isMenuBarDefault: store.primaryProvider == provider,
                        action: { settingsProvider = provider }
                    )
                }
            }
        }
    }

    @ViewBuilder
    func settingsDetail(for provider: AIProviderKind) -> some View {
        switch provider {
        case .claude:
            claudeSettings
        case .openAI:
            openAISettings
        case .codex:
            codexSettings
        case .cursor:
            cursorSettings
        }
    }

    @ViewBuilder
    var mainProviderSettings: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.accentSoft))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("메뉴바 기본 AI")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("이 선택값이 메뉴바에 항상 표시됩니다. 상세 화면에서 탭을 눌러 다른 AI를 보더라도 메뉴바 기본값은 바뀌지 않습니다.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("", selection: mainProviderBinding) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    var mainProviderBinding: Binding<AIProviderKind> {
        Binding(
            get: { store.primaryProvider },
            set: { provider in
                store.setPrimaryProvider(provider)
                selectedProvider = provider
                onPrimaryProviderChange()
            }
        )
    }

    func settingsDescription(for provider: AIProviderKind) -> String {
        switch provider {
        case .claude:
            return "개인 Claude Code 사용량은 기존 Keychain OAuth를 사용합니다. 조직 공식 집계가 필요하면 Anthropic Admin key를 별도로 저장합니다."
        case .openAI:
            return "OpenAI API 사용량은 Admin key와 선택적 Organization/Project 범위로 집계합니다. API key는 Keychain에만 저장합니다."
        case .codex:
            return "Codex 개인 제품 사용량은 현재 공식 수집 API가 없어 계정 키 입력을 받지 않습니다."
        case .cursor:
            return "Cursor는 Team API key 기준으로 팀/조직 사용량을 집계합니다. 개인 계정 quota와 구분합니다."
        }
    }

    var claudeSettings: some View {
        VStack(spacing: 12) {
            Card("개인 Claude Code") {
                VStack(spacing: 10) {
                    SettingStatusRow(label: "로컬 세션", value: store.claudeLocalSession.state.label, color: sessionColor(store.claudeLocalSession))
                    SettingStatusRow(label: "로그인 방식", value: store.claudeLocalSession.authModeLabel, color: store.claudeLocalSession.authMode == nil ? Theme.textTertiary : Theme.textSecondary)
                    SettingStatusRow(label: "계정 식별자", value: store.claudeLocalSession.accountLabel, color: store.claudeLocalSession.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                    SettingStatusRow(label: "자격증명 위치", value: store.claudeLocalSession.credentialLocationLabel, color: Theme.textSecondary)
                    SettingStatusRow(label: "공식 source", value: "api.anthropic.com OAuth usage", color: Theme.textSecondary)
                    SettingStatusRow(label: "로컬 상세", value: "ccusage --offline", color: Theme.textSecondary)
                    ExternalAuthActionRow(
                        title: "로그인 / 로그아웃",
                        detail: "로그인은 Claude Code 실행 시 브라우저로 진행됩니다. 로그아웃은 Claude Code 프롬프트에서 /logout을 입력해야 합니다.",
                        primaryTitle: "Claude 열기",
                        secondaryTitle: "로그아웃 안내",
                        onPrimary: { openExternalURL("https://claude.ai/code") },
                        onSecondary: { store.settingsMessage = "Claude Code 터미널에서 /logout 입력 후 재로그인하세요." }
                    )
                }
            }

            Card("Anthropic Admin") {
                VStack(spacing: 10) {
                    SettingStatusRow(label: "Admin key", value: store.hasAnthropicAdminKey ? "Keychain 저장됨" : "선택 사항", color: store.hasAnthropicAdminKey ? Theme.success : Theme.textTertiary)
                    SettingStatusRow(label: "계정 범위", value: store.anthropicAdminWorkspaceID.isEmpty ? "미지정" : store.anthropicAdminWorkspaceID, color: store.anthropicAdminWorkspaceID.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                    SettingsTextField(
                        label: "Workspace / Org ID",
                        placeholder: "선택 사항",
                        text: Binding(get: { store.anthropicAdminWorkspaceID }, set: { store.setAnthropicAdminWorkspaceID($0) })
                    )
                    SecretInputRow(
                        title: "Admin API key",
                        placeholder: "sk-ant-admin...",
                        text: $anthropicAdminKeyInput,
                        isStored: store.hasAnthropicAdminKey,
                        onSave: {
                            store.saveSecret(.anthropicAdminKey, value: anthropicAdminKeyInput)
                            anthropicAdminKeyInput = ""
                        },
                        onDelete: { store.deleteSecret(.anthropicAdminKey) }
                    )
                    SettingsHint("조직 Usage/Cost API와 Claude Code Analytics API를 붙일 때 사용합니다.")
                }
            }
        }
    }

    var openAISettings: some View {
        Card("OpenAI Admin API") {
            VStack(spacing: 10) {
                SettingStatusRow(label: "로컬 감지", value: store.openAILocalSession.state.label, color: sessionColor(store.openAILocalSession))
                SettingStatusRow(label: "감지 방식", value: store.openAILocalSession.authModeLabel, color: store.openAILocalSession.authMode == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "자격증명 위치", value: store.openAILocalSession.credentialLocationLabel, color: store.openAILocalSession.credentialLocation == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "Admin key", value: store.hasOpenAIAdminKey ? "Keychain 저장됨" : "필수", color: store.hasOpenAIAdminKey ? Theme.success : Theme.warn)
                SettingStatusRow(label: "계정 범위", value: store.openAIOrganizationID.isEmpty ? "조직 전체" : store.openAIOrganizationID, color: Theme.textSecondary)
                SettingsTextField(
                    label: "Organization ID",
                    placeholder: "org_... 또는 비워두기",
                    text: Binding(get: { store.openAIOrganizationID }, set: { store.setOpenAIOrganizationID($0) })
                )
                SettingsTextField(
                    label: "Project ID",
                    placeholder: "proj_... 또는 비워두기",
                    text: Binding(get: { store.openAIProjectID }, set: { store.setOpenAIProjectID($0) })
                )
                SecretInputRow(
                    title: "Admin API key",
                    placeholder: "sk-admin-...",
                    text: $openAIKeyInput,
                    isStored: store.hasOpenAIAdminKey,
                    onSave: {
                        store.saveSecret(.openAIAdminKey, value: openAIKeyInput)
                        openAIKeyInput = ""
                    },
                    onDelete: { store.deleteSecret(.openAIAdminKey) }
                )
                SettingsHint("수집 대상: /v1/organization/usage/completions, /v1/organization/costs. API 제품 사용량이며 Codex 제품 quota와 분리합니다.")
            }
        }
    }

    var codexSettings: some View {
        Card("Codex") {
            VStack(spacing: 10) {
                SettingStatusRow(label: "로컬 세션", value: store.codexLocalSession.state.label, color: codexSessionColor)
                SettingStatusRow(label: "로그인 방식", value: store.codexLocalSession.authModeLabel, color: store.codexLocalSession.authMode == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "계정 식별자", value: store.codexLocalSession.accountLabel, color: store.codexLocalSession.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "자격증명 위치", value: store.codexLocalSession.credentialLocationLabel, color: Theme.textSecondary)
                SettingStatusRow(label: "마지막 갱신", value: formatResetClock(store.codexLocalSession.lastRefresh), color: store.codexLocalSession.lastRefresh == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "공식 사용량 API", value: "개인 quota API 없음", color: Theme.textTertiary)
                ExternalAuthActionRow(
                    title: "로그인 / 로그아웃",
                    detail: "앱이 로컬 Codex 세션을 자동 감지합니다. 로그인이 필요하면 터미널에서 codex login을 실행하고, 로그아웃은 여기서 codex logout을 실행할 수 있습니다.",
                    primaryTitle: "Codex 열기",
                    secondaryTitle: "CLI 로그아웃",
                    onPrimary: { openExternalURL("https://chatgpt.com/codex/") },
                    onSecondary: {
                        runShellCommand(
                            "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\" codex logout",
                            successMessage: "codex logout 실행됨",
                            failureMessage: "codex logout 실행 실패",
                            onComplete: { store.refreshLocalSessions() }
                        )
                    }
                )
                SettingsHint("입력받을 로그인 정보는 없습니다. 로컬 세션은 자동 감지하고, OpenAI API Admin key는 OpenAI API 사용량 수집용으로만 별도 관리합니다.")
            }
        }
    }

    var cursorSettings: some View {
        Card("Cursor Team API") {
            VStack(spacing: 10) {
                SettingStatusRow(label: "로컬 감지", value: store.cursorLocalSession.state.label, color: sessionColor(store.cursorLocalSession))
                SettingStatusRow(label: "감지 방식", value: store.cursorLocalSession.authModeLabel, color: store.cursorLocalSession.authMode == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "로컬 위치", value: store.cursorLocalSession.credentialLocationLabel, color: store.cursorLocalSession.credentialLocation == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "Team key", value: store.hasCursorTeamKey ? "Keychain 저장됨" : "필수", color: store.hasCursorTeamKey ? Theme.success : Theme.warn)
                SettingStatusRow(label: "계정 범위", value: store.cursorTeamID.isEmpty ? "팀 미지정" : store.cursorTeamID, color: store.cursorTeamID.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                SettingsTextField(
                    label: "Team / Workspace",
                    placeholder: "팀 식별용 이름 또는 ID",
                    text: Binding(get: { store.cursorTeamID }, set: { store.setCursorTeamID($0) })
                )
                SecretInputRow(
                    title: "Team API key",
                    placeholder: "key_...",
                    text: $cursorKeyInput,
                    isStored: store.hasCursorTeamKey,
                    onSave: {
                        store.saveSecret(.cursorTeamKey, value: cursorKeyInput)
                        cursorKeyInput = ""
                    },
                    onDelete: { store.deleteSecret(.cursorTeamKey) }
                )
                SettingsHint("수집 대상: Cursor Admin/Analytics API. 팀 단위 request, token, charged cents, 모델 정보를 표시합니다.")
            }
        }
    }

    var settingsReviewCard: some View {
        Card("연동 가능 범위") {
            VStack(spacing: 9) {
                CapabilityRow(provider: "Claude", capability: "공식 개인 사용량 읽기 가능 · 로그인/로그아웃은 Claude Code CLI에서 처리")
                CapabilityRow(provider: "OpenAI API", capability: "Keychain/환경변수 감지 가능 · Usage/Cost API는 Admin 권한 필요")
                CapabilityRow(provider: "Codex", capability: "로컬 CLI 세션 자동 감지 · 개인 Codex quota API는 공개 확인 전까지 수집 제외")
                CapabilityRow(provider: "Cursor", capability: "앱 설치/Team key 감지 가능 · 팀 Analytics/Admin API는 Team key 필요")
            }
        }
    }

    var claudeCredentialLabel: String {
        switch store.officialState {
        case .noToken: return "로그인 필요"
        case .unauthorized: return "재인증 필요"
        case .loading: return "확인 중"
        default: return store.official == nil ? "확인 필요" : "연결됨"
        }
    }

    var claudeCredentialColor: Color {
        switch store.officialState {
        case .noToken, .unauthorized: return Theme.warn
        default: return store.official == nil ? Theme.textTertiary : Theme.success
        }
    }

    var codexSessionColor: Color {
        sessionColor(store.codexLocalSession)
    }

    func sessionColor(_ session: LocalProviderSession) -> Color {
        switch session.state {
        case .loggedIn: return Theme.success
        case .loggedOut: return Theme.warn
        case .unavailable: return Theme.textTertiary
        }
    }

    func openExternalURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    func runShellCommand(_ command: String, successMessage: String, failureMessage: String, onComplete: (() -> Void)? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            store.settingsMessage = task.terminationStatus == 0 ? successMessage : failureMessage
        } catch {
            store.settingsMessage = failureMessage
        }
        onComplete?()
    }

    // MARK: - Common

    @ViewBuilder
    func loadingCard(_ text: String) -> some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func inlineStatus(_ title: String, _ body: String, _ icon: String, _ color: Color) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(body)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    func sourceFootnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    var updateControl: some View {
        switch updater.state {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text("업데이트 중")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        case .failed(let message):
            Button(action: { updater.startUpdate() }) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.warn)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(message)
        case .idle:
            Button(action: { updater.startUpdate() }) {
                Text("업데이트")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(updater.canUpdate ? Theme.textSecondary : Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(!updater.canUpdate)
            .help(updater.canUpdate ? "git pull + 재빌드 + 재시작" : "소스 경로를 찾을 수 없습니다 (SourceRoot)")
        }
    }
}

// MARK: - Small Components

struct IconButton: View {
    let symbol: String
    let action: () -> Void
    let help: String

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HeaderActionButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("\(title) 보기")
    }
}

struct ProviderTab: View {
    let provider: AIProviderKind
    let snapshot: ProviderSnapshot?
    let isSelected: Bool
    let isMenuBarDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: provider.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? providerColor(provider) : Theme.textSecondary)
                Text(provider.menuName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Circle()
                    .fill(stateColor(snapshot?.state ?? .loading))
                    .frame(width: isMenuBarDefault ? 6 : 4, height: isMenuBarDefault ? 6 : 4)
                    .opacity(isSelected ? 1 : 0.55)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? providerColor(provider).opacity(0.13) : Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? providerColor(provider).opacity(0.35) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct MetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageWindowRow: View {
    let title: String
    let window: UsageWindow?
    let trailing: String?

    var body: some View {
        let pct = window?.utilization ?? 0
        let reset = parseDate(window?.resetsAt)
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                }
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.percentColor(pct))
            }
            ProgressBar(percent: pct, color: Theme.percentColor(pct), height: 6)
            HStack {
                Text(friendlyRemaining(until: reset))
                Spacer()
                Text(formatResetClock(reset))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
        }
    }
}

struct UnsupportedRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

struct SettingStatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

struct CapabilityRow: View {
    let provider: String
    let capability: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(provider)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 76, alignment: .leading)
            Text(capability)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct LocalSessionRow: View {
    let provider: String
    let state: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(provider)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(state)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ExternalAuthActionRow: View {
    let title: String
    let detail: String
    let primaryTitle: String
    let secondaryTitle: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(primaryTitle, action: onPrimary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .buttonStyle(.plain)
                Button(secondaryTitle, action: onSecondary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                    .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}

struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        }
    }
}

struct SecretInputRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let isStored: Bool
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Text(isStored ? "저장됨" : "미저장")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isStored ? Theme.success : Theme.warn)
            }
            HStack(spacing: 8) {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))

                Button("로그인", action: onSave)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("로그아웃", action: onDelete)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isStored ? Theme.warn : Theme.textTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                    .buttonStyle(.plain)
                    .disabled(!isStored)
            }
        }
    }
}

struct SettingsHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func providerColor(_ provider: AIProviderKind) -> Color {
    switch provider {
    case .claude:
        return Theme.accent
    case .openAI:
        return Color(red: 0.36, green: 0.78, blue: 0.64)
    case .codex:
        return Color(red: 0.56, green: 0.66, blue: 1.00)
    case .cursor:
        return Color(red: 0.95, green: 0.76, blue: 0.34)
    }
}

func sourceColor(_ source: UsageSourceKind) -> Color {
    switch source {
    case .officialPersonal, .officialAdmin:
        return Theme.success
    case .localSession:
        return Theme.success
    case .localEstimate:
        return Theme.accent
    case .setupRequired:
        return Theme.warn
    case .unavailable:
        return Theme.textTertiary
    }
}

func stateColor(_ state: ProviderState) -> Color {
    switch state {
    case .ready, .configured:
        return Theme.success
    case .loading, .stale, .rateLimited:
        return Theme.warn
    case .setupRequired, .unauthorized, .offline:
        return Theme.warn
    case .unavailable:
        return Theme.textTertiary
    }
}

struct SourceBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
    }
}

struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.10)))
    }
}
