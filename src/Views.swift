import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var geminiKeyInput = ""
    @State private var cursorKeyInput = ""
    @State private var anthropicAdminKeyInput = ""
    @State private var selectedProvider: AIProviderKind?
    @State private var settingsProvider: AIProviderKind = .claude
    @State private var draggingProvider: AIProviderKind?

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
                ProviderBrandMark(provider: snapshot.provider, size: 16, color: color)
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
            ForEach(store.providerOrder) { provider in
                ProviderTab(
                    provider: provider,
                    snapshot: store.snapshot(for: provider),
                    isSelected: visibleProvider == provider,
                    isMenuBarDefault: store.primaryProvider == provider,
                    action: { selectedProvider = provider }
                )
                .onDrag {
                    draggingProvider = provider
                    return NSItemProvider(object: provider.rawValue as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: ProviderTabDropDelegate(
                        target: provider,
                        draggingProvider: $draggingProvider,
                        moveAction: store.moveProviderTab
                    )
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
        case .codex:
            codexUsage
        case .cursor:
            cursorUsage
        case .gemini:
            geminiUsage
        case .openAI:
            openAIUsage
        }
    }

    var geminiUsage: some View {
        let snapshot = store.snapshot(for: .gemini) ?? visibleSnapshot
        return Group {
            setupUsage(
                snapshot: snapshot,
                title: "Gemini CLI 사용량",
                body: snapshot.stateMessage,
                metrics: ["Gemini CLI OAuth", "세션 /stats", "로컬 로그", "API key는 보조"],
                credentialReady: store.geminiLocalSession.isLoggedIn
            )
            sourceFootnote("Gemini CLI는 Google OAuth 로그인을 우선 감지합니다. API key는 CLI 세션 사용량을 대체하지 않는 보조 경로입니다.")
        }
    }

    var openAIUsage: some View {
        Group {
            if let summary = store.openAIUsage {
                providerOverviewCard(provider: .openAI, summary: summary)
                providerWindowCard(provider: .openAI, summary: summary)
                providerSessionDetailCard(provider: .openAI, title: "세션 상세 · OpenAI API", summary: summary)
                sourceFootnote("OpenAI 공식 Organization Usage/Cost API 기준입니다. ChatGPT/Codex 구독 사용량이 아니라 API 조직 사용량만 집계합니다.")
            } else {
                setupUsage(
                    snapshot: store.snapshot(for: .openAI) ?? visibleSnapshot,
                    title: "OpenAI API 사용량",
                    body: (store.snapshot(for: .openAI) ?? visibleSnapshot).stateMessage,
                    metrics: ["오늘 API 비용", "입력/출력/캐시 토큰", "요청 수", "모델별 사용량"],
                    credentialReady: store.hasOpenAIAdminKey
                )
            }
        }
    }

    var codexUsage: some View {
        Group {
            if let summary = store.codexUsage {
                codexOverviewCard(summary)
                codexLimitsCard(summary)
                codexSessionDetailCard(summary)
                sourceFootnote("Codex TUI /status, /usage에 쓰이는 token_count.rate_limits 로그 기준입니다. 공개 API 호출 없이 로컬 파일만 읽습니다.")
            } else if store.codexLocalSession.isLoggedIn {
                codexSessionCard
                sourceFootnote("Codex 로그인은 감지했지만 로컬 session 로그의 token_count 사용량을 찾지 못했습니다.")
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

    @ViewBuilder
    func codexOverviewCard(_ summary: LocalUsageSummary) -> some View {
        let pct = summary.primary.percentValue ?? 0
        let reset = summary.primaryResetAt
        let color = Theme.percentColor(pct)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.primary.valueText)
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
                            text: (store.snapshot(for: .codex) ?? visibleSnapshot).state.label,
                            color: stateColor((store.snapshot(for: .codex) ?? visibleSnapshot).state)
                        )
                        Text(formatResetClock(reset))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }

                ProgressBar(percent: pct, color: color, height: 9)

                HStack(spacing: 10) {
                    MetricTile(label: "재설정", value: compactRemaining(until: reset))
                    MetricTile(label: "비용", value: "—")
                    MetricTile(label: "토큰", value: summary.totalTokens.map(formatNum) ?? "—")
                    MetricTile(label: "요청", value: summary.requestCount.map { "\($0)" } ?? "—")
                }

                if let modelSummary = summary.modelSummary, !modelSummary.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                        Text(modelSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func codexLimitsCard(_ summary: LocalUsageSummary) -> some View {
        Card("한도") {
            VStack(spacing: 10) {
                UsageLimitRow(
                    title: "주간 · 모든 모델",
                    percent: summary.secondary?.percentValue,
                    resetAt: summary.secondaryResetAt,
                    trailing: nil
                )
            }
        }
    }

    @ViewBuilder
    func codexSessionDetailCard(_ summary: LocalUsageSummary) -> some View {
        Card("세션 상세 · Codex 로그") {
            VStack(spacing: 10) {
                KVRow(label: "오늘 토큰", value: summary.totalTokens.map(formatNum) ?? "—")
                if let requestCount = summary.requestCount {
                    KVRow(label: "요청", value: "\(requestCount)")
                }
                KVRow(label: "마지막 갱신", value: formatResetClock(summary.updatedAt), valueColor: Theme.textSecondary)
                Divider().background(Color.white.opacity(0.06))
                let input = summary.inputTokens ?? 0
                let output = summary.outputTokens ?? 0
                let cached = summary.cachedInputTokens ?? 0
                let reasoning = summary.reasoningTokens ?? 0
                let maxV = Swift.max(input, output, cached, reasoning)
                TokenBarRow(label: "입력", value: input, max: maxV, color: .blue)
                TokenBarRow(label: "출력", value: output, max: maxV, color: .green)
                TokenBarRow(label: "캐시", value: cached, max: maxV, color: .teal)
                TokenBarRow(label: "추론", value: reasoning, max: maxV, color: .purple)
            }
        }
    }

    var cursorUsage: some View {
        Group {
            if let summary = store.cursorUsage {
                providerOverviewCard(provider: .cursor, summary: summary)
                providerWindowCard(provider: .cursor, summary: summary)
                providerSessionDetailCard(
                    provider: .cursor,
                    title: summary.sourceKind == .officialAdmin ? "세션 상세 · Cursor Team API" : "세션 상세 · Cursor 로컬",
                    summary: summary
                )
                sourceFootnote(summary.sourceKind == .officialAdmin
                    ? "Cursor 공식 Team Analytics/Admin API 기준입니다. 팀 API key 권한으로 오늘 요청, 토큰, 비용을 집계합니다."
                    : "Cursor Team API 연결 전에는 로컬 composer 저장소 기반 추정치를 표시합니다. token/cost는 공식 Team API 연결 후 표시합니다.")
            } else {
                setupUsage(
                    snapshot: store.snapshot(for: .cursor) ?? visibleSnapshot,
                    title: "Cursor 사용량",
                    body: (store.snapshot(for: .cursor) ?? visibleSnapshot).stateMessage,
                    metrics: ["Cursor Agent CLI", "로컬 대화 기록", "Composer/Agent 요청", "Team API는 보조"],
                    credentialReady: store.cursorLocalSession.executablePath != nil
                )
            }
        }
    }

    @ViewBuilder
    func providerOverviewCard(provider: AIProviderKind, summary: LocalUsageSummary) -> some View {
        let snapshot = store.snapshot(for: provider) ?? visibleSnapshot
        let pct = summary.primary.percentValue
        let color = pct.map(Theme.percentColor) ?? providerColor(provider)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.primary.valueText)
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(providerOverviewSubtitle(summary))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        StateBadge(text: snapshot.state.label, color: stateColor(snapshot.state))
                        Text(formatResetClock(summary.primaryResetAt ?? summary.updatedAt))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }

                if let pct {
                    ProgressBar(percent: pct, color: color, height: 9)
                } else {
                    ProgressBar(percent: 0, color: color, height: 9)
                        .opacity(0.55)
                }

                HStack(spacing: 10) {
                    MetricTile(label: "재설정", value: compactRemaining(until: summary.primaryResetAt))
                    MetricTile(label: "비용", value: summary.costUSD.map { String(format: "$%.2f", $0) } ?? "—")
                    MetricTile(label: "토큰", value: summary.totalTokens.map(formatNum) ?? "—")
                    MetricTile(label: "요청", value: summary.requestCount.map { "\($0)" } ?? "—")
                }

                if let modelSummary = summary.modelSummary, !modelSummary.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                        Text(modelSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func providerWindowCard(provider: AIProviderKind, summary: LocalUsageSummary) -> some View {
        let hasPercent = summary.primary.percentValue != nil || summary.secondary?.percentValue != nil
        Card(hasPercent ? "한도" : "기간") {
            VStack(spacing: 10) {
                if let pct = summary.primary.percentValue {
                    UsageLimitRow(
                        title: "\(summary.period.label) · 전체 사용량",
                        percent: pct,
                        resetAt: summary.primaryResetAt,
                        trailing: summary.costUSD.map { String(format: "$%.2f", $0) }
                    )
                } else {
                    UsageAmountRow(
                        title: "\(summary.period.label) · 전체 사용량",
                        value: summary.primary.valueText,
                        detail: summary.requestCount.map { "\(formatNum($0)) req" },
                        resetAt: summary.primaryResetAt,
                        color: providerColor(provider)
                    )
                }

                if let secondary = summary.secondary, let period = summary.secondaryPeriod {
                    Divider().background(Color.white.opacity(0.06))
                    UsageLimitRow(
                        title: "\(period.label) · 모든 모델",
                        percent: secondary.percentValue,
                        resetAt: summary.secondaryResetAt,
                        trailing: nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    func providerSessionDetailCard(provider: AIProviderKind, title: String, summary: LocalUsageSummary) -> some View {
        Card(title) {
            VStack(spacing: 10) {
                KVRow(label: "현재 비용", value: summary.costUSD.map { String(format: "$%.2f", $0) } ?? "—")
                if let requestCount = summary.requestCount {
                    KVRow(label: "요청", value: "\(requestCount)")
                }
                KVRow(label: "오늘 토큰", value: summary.totalTokens.map(formatNum) ?? "—")
                KVRow(label: "마지막 갱신", value: formatResetClock(summary.updatedAt), valueColor: Theme.textSecondary)
                Divider().background(Color.white.opacity(0.06))

                let input = summary.inputTokens ?? 0
                let output = summary.outputTokens ?? 0
                let cached = summary.cachedInputTokens ?? 0
                let reasoning = summary.reasoningTokens ?? 0
                let maxV = Swift.max(input, output, cached, reasoning)
                if maxV > 0 {
                    TokenBarRow(label: "입력", value: input, max: maxV, color: .blue)
                    TokenBarRow(label: "출력", value: output, max: maxV, color: .green)
                    TokenBarRow(label: "캐시", value: cached, max: maxV, color: .teal)
                    TokenBarRow(label: "추론", value: reasoning, max: maxV, color: .purple)
                } else {
                    Text(provider == .cursor && summary.sourceKind == .localEstimate
                        ? "로컬 Cursor 추정치에는 token/cost가 포함되지 않습니다."
                        : "이번 기간의 token 상세가 없습니다.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func providerOverviewSubtitle(_ summary: LocalUsageSummary) -> String {
        if summary.primary.percentValue != nil, summary.period == .fiveHour {
            return "현재 5시간 세션"
        }
        return "\(summary.period.label) 사용량"
    }

    func localUsageCard(provider: AIProviderKind, title: String, body: String, summary: LocalUsageSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(providerColor(provider).opacity(0.16))
                        ProviderBrandMark(provider: provider, size: 17, color: providerColor(provider))
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
                    StateBadge(text: provider == .codex ? "로컬 로그" : "로컬 추정", color: Theme.accent)
                }

                HStack(alignment: .lastTextBaseline) {
                    Text(summary.primary.valueText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(providerColor(provider))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text(summary.period.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }

                if let percent = summary.primary.percentValue {
                    ProgressView(value: min(max(percent, 0), 100), total: 100)
                        .tint(providerColor(provider))
                }

                VStack(spacing: 9) {
                    if let primaryResetAt = summary.primaryResetAt {
                        SettingStatusRow(label: "\(summary.period.label) 리셋", value: friendlyRemaining(until: primaryResetAt), color: Theme.textSecondary)
                    }
                    if let secondary = summary.secondary, let period = summary.secondaryPeriod {
                        SettingStatusRow(label: period.label, value: secondary.valueText, color: providerColor(provider))
                    }
                    if let secondaryResetAt = summary.secondaryResetAt, let period = summary.secondaryPeriod {
                        SettingStatusRow(label: "\(period.label) 리셋", value: friendlyRemaining(until: secondaryResetAt), color: Theme.textSecondary)
                    }
                    if let totalTokens = summary.totalTokens {
                        SettingStatusRow(label: provider == .codex ? "오늘 토큰" : "토큰", value: formatNum(totalTokens), color: Theme.textSecondary)
                    }
                    if let inputTokens = summary.inputTokens {
                        SettingStatusRow(label: "입력", value: formatNum(inputTokens), color: Theme.textSecondary)
                    }
                    if let cachedInputTokens = summary.cachedInputTokens, cachedInputTokens > 0 {
                        SettingStatusRow(label: "캐시 입력", value: formatNum(cachedInputTokens), color: Theme.textSecondary)
                    }
                    if let outputTokens = summary.outputTokens {
                        SettingStatusRow(label: "출력", value: formatNum(outputTokens), color: Theme.textSecondary)
                    }
                    if let reasoningTokens = summary.reasoningTokens, reasoningTokens > 0 {
                        SettingStatusRow(label: "추론", value: formatNum(reasoningTokens), color: Theme.textSecondary)
                    }
                    if let requestCount = summary.requestCount {
                        SettingStatusRow(label: provider == .cursor ? "대화 header" : "요청", value: formatNum(requestCount), color: Theme.textSecondary)
                    }
                    if let modelSummary = summary.modelSummary {
                        SettingStatusRow(label: provider == .cursor ? "로컬 크기" : "모델/Source", value: modelSummary, color: Theme.textSecondary)
                    }
                    SettingStatusRow(label: "마지막 갱신", value: formatResetClock(summary.updatedAt), color: summary.updatedAt == nil ? Theme.textTertiary : Theme.textSecondary)
                }
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
                        ProviderBrandMark(provider: .codex, size: 17, color: providerColor(.codex))
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex 로컬 세션")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("현재 Mac의 Codex 로그인을 감지했습니다. 로컬 session 로그의 token_count 사용량은 아직 없습니다.")
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
                    SettingStatusRow(label: "로컬 사용량", value: "오늘 데이터 없음", color: Theme.textTertiary)
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
            inlineStatus("공식 집계 일시 제한", "직전 공식 값을 유지하고 자동 갱신에서 다시 확인합니다.", "arrow.triangle.2.circlepath", Theme.accent)
        } else if store.officialState.isError {
            inlineStatus(
                "공식 데이터 갱신 실패",
                store.official == nil ? "네트워크 연결 또는 Anthropic API 응답을 확인하세요." : "직전 공식 값을 유지해서 표시 중입니다.",
                "wifi.slash",
                Theme.warn
            )
        }
    }

    @ViewBuilder
    func claudeOverviewCard(_ window: UsageWindow?) -> some View {
        let pct = fiveHourDisplayUtilization(window)
        let reset = fiveHourDisplayReset(window)
        let sessionStarted = fiveHourSessionStarted(window)
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
                        Text(sessionStarted ? "현재 5시간 세션" : "메시지를 보내면 시작")
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
                    MetricTile(label: "재설정", value: sessionStarted ? compactRemaining(until: reset) : "시작 전")
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
                        ProviderBrandMark(provider: snapshot.provider, size: 17, color: providerColor(snapshot.provider))
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
                        ProviderBrandMark(provider: snapshot.provider, size: 17, color: providerColor(snapshot.provider))
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
        accountStatusCard
        if let message = store.settingsMessage, isSettingsMessageVisible {
            inlineStatus("설정 변경", message, "checkmark.circle", Theme.success)
        }
        settingsDetail(for: settingsProvider)
        diagnosticsSettings
    }

    var isSettingsMessageVisible: Bool {
        store.settingsMessageProvider == nil || store.settingsMessageProvider == settingsProvider
    }

    var accountStatusCard: some View {
        Card("계정 상태") {
            HStack(spacing: 7) {
                ForEach(store.providerOrder) { provider in
                    AccountStatusPill(
                        provider: provider,
                        status: accountStatusText(for: provider),
                        color: accountStatusColor(for: provider),
                        isSelected: settingsProvider == provider,
                        action: { selectSettingsProvider(provider) }
                    )
                }
            }
        }
    }

    var settingsProviderTabs: some View {
        Card("AI 계정 설정") {
            HStack(spacing: 6) {
                ForEach(store.providerOrder) { provider in
                    ProviderTab(
                        provider: provider,
                        snapshot: store.snapshot(for: provider),
                        isSelected: settingsProvider == provider,
                        isMenuBarDefault: store.primaryProvider == provider,
                        action: { selectSettingsProvider(provider) }
                    )
                    .onDrag {
                        draggingProvider = provider
                        return NSItemProvider(object: provider.rawValue as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: ProviderTabDropDelegate(
                            target: provider,
                            draggingProvider: $draggingProvider,
                            moveAction: store.moveProviderTab
                        )
                    )
                }
            }
        }
    }

    func selectSettingsProvider(_ provider: AIProviderKind) {
        settingsProvider = provider
        store.clearSettingsMessage()
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
        case .gemini:
            geminiSettings
        }
    }

    @ViewBuilder
    var mainProviderSettings: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.accentSoft))
                    Text("메뉴바 기본 AI")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(store.primaryProvider.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }

                Picker("", selection: mainProviderBinding) {
                    ForEach(store.providerOrder) { provider in
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

    func accountStatusText(for provider: AIProviderKind) -> String {
        switch provider {
        case .claude:
            return store.claudeLocalSession.isLoggedIn ? "연결됨" : "로그인"
        case .codex:
            return store.codexLocalSession.isLoggedIn ? "연결됨" : "로그인"
        case .cursor:
            return store.cursorLocalSession.isLoggedIn ? "연결됨" : (store.cursorLocalSession.executablePath == nil ? "미감지" : "로그인")
        case .gemini:
            return store.geminiLocalSession.isLoggedIn ? "연결됨" : (store.geminiLocalSession.executablePath == nil ? "미감지" : "로그인")
        case .openAI:
            return store.hasOpenAIAdminKey ? "Admin" : "API 전용"
        }
    }

    func accountStatusColor(for provider: AIProviderKind) -> Color {
        switch provider {
        case .claude:
            return sessionColor(store.claudeLocalSession)
        case .codex:
            return sessionColor(store.codexLocalSession)
        case .cursor:
            return sessionColor(store.cursorLocalSession)
        case .gemini:
            return sessionColor(store.geminiLocalSession)
        case .openAI:
            return store.hasOpenAIAdminKey ? Theme.success : Theme.textTertiary
        }
    }

    func settingsDescription(for provider: AIProviderKind) -> String {
        switch provider {
        case .claude:
            return "개인 Claude Code 사용량은 기존 Keychain OAuth를 사용합니다. 조직 공식 집계가 필요하면 Anthropic Admin key를 별도로 저장합니다."
        case .openAI:
            return "OpenAI API는 직접 CLI 사용량이 아니라 API 조직 사용량만 다룹니다. OpenAI 계정 기반 CLI 사용량은 Codex 탭에서 처리합니다."
        case .codex:
            return "Codex는 codex login/logout과 로컬 auth/session 로그를 기준으로 자동 감지합니다."
        case .cursor:
            return "Cursor는 Agent CLI 로그인을 기본으로 감지합니다. Team API key는 팀 분석용 보조 설정입니다."
        case .gemini:
            return "Gemini는 gemini CLI의 Google OAuth를 기본으로 감지합니다. API key는 직접 API 호출용 보조 설정입니다."
        }
    }

    var claudeSettings: some View {
        Card("Claude") {
            VStack(spacing: 10) {
                AccountHeader(provider: .claude, status: store.claudeLocalSession.state.label, color: sessionColor(store.claudeLocalSession))
                SettingStatusRow(label: "계정", value: store.claudeLocalSession.accountLabel, color: store.claudeLocalSession.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "사용량", value: "Official + ccusage", color: Theme.textSecondary)
                AuthControlPanel(
                    title: "Claude Code",
                    detail: "터미널 로그인 후 앱이 Keychain OAuth를 자동 감지합니다.",
                    primaryTitle: "로그인",
                    secondaryTitle: "로그아웃",
                    onPrimary: {
                        openTerminalCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if claude auth login --help >/dev/null 2>&1; then
                              claude auth login
                            else
                              claude
                            fi
                            """,
                            title: "Claude Code 로그인",
                            provider: .claude
                        )
                    },
                    onSecondary: {
                        runShellCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if claude auth logout --help >/dev/null 2>&1; then
                              claude auth logout
                            else
                              exit 127
                            fi
                            """,
                            successMessage: "Claude Code 로그아웃 실행됨",
                            failureMessage: "Claude Code 로그아웃 실행 실패",
                            provider: .claude,
                            onComplete: { store.refreshLocalSessions() }
                        )
                    }
                )
                Divider().background(Color.white.opacity(0.06))
                SettingStatusRow(label: "Admin key", value: store.hasAnthropicAdminKey ? "저장됨" : "선택", color: store.hasAnthropicAdminKey ? Theme.success : Theme.textTertiary)
                SettingsTextField(
                    label: "Workspace",
                    placeholder: "선택 사항",
                    text: Binding(get: { store.anthropicAdminWorkspaceID }, set: { store.setAnthropicAdminWorkspaceID($0) })
                )
                SecretInputRow(
                    title: "Admin key",
                    placeholder: "sk-ant-admin...",
                    text: $anthropicAdminKeyInput,
                    isStored: store.hasAnthropicAdminKey,
                    onSave: {
                        store.saveSecret(.anthropicAdminKey, value: anthropicAdminKeyInput)
                        anthropicAdminKeyInput = ""
                    },
                    onDelete: { store.deleteSecret(.anthropicAdminKey) }
                )
            }
        }
    }

    var geminiSettings: some View {
        Card("Gemini CLI") {
            VStack(spacing: 10) {
                AccountHeader(provider: .gemini, status: store.geminiLocalSession.state.label, color: sessionColor(store.geminiLocalSession))
                SettingStatusRow(label: "로그인 방식", value: store.geminiLocalSession.authModeLabel, color: Theme.textSecondary)
                SettingStatusRow(label: "계정", value: store.geminiLocalSession.accountLabel, color: store.geminiLocalSession.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "자격증명", value: store.geminiLocalSession.credentialLocationLabel, color: store.geminiLocalSession.credentialLocation == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "사용량", value: "CLI /stats + 로컬 로그", color: Theme.textSecondary)
                AuthControlPanel(
                    title: "Gemini CLI",
                    detail: "터미널에서 gemini를 실행하고 Sign in with Google 또는 /auth로 인증합니다.",
                    primaryTitle: "CLI 열기",
                    secondaryTitle: "인증 변경",
                    onPrimary: {
                        openTerminalCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if command -v gemini >/dev/null 2>&1; then
                              echo "Gemini CLI에서 Sign in with Google을 선택하거나 /auth를 입력하세요."
                              gemini
                            else
                              echo "Gemini CLI가 설치되어 있지 않습니다."
                              echo "공식 설치 후 다시 시도하세요: npm install -g @google/gemini-cli"
                            fi
                            """,
                            title: "Gemini CLI 로그인",
                            provider: .gemini
                        )
                    },
                    onSecondary: {
                        openTerminalCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if command -v gemini >/dev/null 2>&1; then
                              echo "Gemini CLI가 열리면 /auth를 입력해 인증 방식을 변경하세요."
                              gemini
                            else
                              echo "Gemini CLI가 설치되어 있지 않습니다."
                            fi
                            """,
                            title: "Gemini 인증 변경",
                            provider: .gemini
                        )
                    },
                    docsTitle: "문서",
                    onDocs: { openExternalURL("https://geminicli.com/docs/get-started/authentication") }
                )
                if store.hasGeminiAPIKey {
                    Divider().background(Color.white.opacity(0.06))
                    SecretInputRow(
                        title: "API key 대안",
                        placeholder: "AIza...",
                        text: $geminiKeyInput,
                        isStored: store.hasGeminiAPIKey,
                        onSave: {
                            store.saveSecret(.geminiAPIKey, value: geminiKeyInput)
                            geminiKeyInput = ""
                        },
                        onDelete: { store.deleteSecret(.geminiAPIKey) }
                    )
                }
            }
        }
    }

    var openAISettings: some View {
        Card("OpenAI API (고급)") {
            VStack(spacing: 10) {
                AccountHeader(provider: .openAI, status: store.hasOpenAIAdminKey ? "Admin key" : "API 전용", color: store.hasOpenAIAdminKey ? Theme.success : Theme.textTertiary)
                SettingStatusRow(label: "자격증명", value: store.openAILocalSession.credentialLocationLabel, color: store.openAILocalSession.credentialLocation == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "CLI 사용량", value: "Codex 탭에서 처리", color: Theme.textSecondary)
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
                SettingsHint("OpenAI Platform API 사용량만 집계합니다. ChatGPT/Codex CLI 사용량은 Codex에서 확인합니다.")
            }
        }
    }

    var codexSettings: some View {
        Card("Codex") {
            VStack(spacing: 10) {
                AccountHeader(provider: .codex, status: store.codexLocalSession.state.label, color: codexSessionColor)
                SettingStatusRow(label: "계정", value: store.codexLocalSession.accountLabel, color: store.codexLocalSession.accountID == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "오늘 사용량", value: store.codexUsage?.primary.valueText ?? "없음", color: store.codexUsage == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "갱신", value: formatResetClock(store.codexLocalSession.lastRefresh), color: store.codexLocalSession.lastRefresh == nil ? Theme.textTertiary : Theme.textSecondary)
                AuthControlPanel(
                    title: "Codex CLI",
                    detail: "터미널 로그인 후 로컬 auth/session을 자동 감지합니다.",
                    primaryTitle: "로그인",
                    secondaryTitle: "로그아웃",
                    onPrimary: {
                        openTerminalCommand(
                            "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\"; codex login",
                            title: "Codex 로그인",
                            provider: .codex
                        )
                    },
                    onSecondary: {
                        runShellCommand(
                            "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\" codex logout",
                            successMessage: "codex logout 실행됨",
                            failureMessage: "codex logout 실행 실패",
                            provider: .codex,
                            onComplete: { store.refreshLocalSessions() }
                        )
                    }
                )
            }
        }
    }

    var cursorSettings: some View {
        Card("Cursor CLI") {
            VStack(spacing: 10) {
                AccountHeader(provider: .cursor, status: store.cursorLocalSession.state.label, color: sessionColor(store.cursorLocalSession))
                SettingStatusRow(label: "로그인 방식", value: store.cursorLocalSession.authModeLabel, color: Theme.textSecondary)
                SettingStatusRow(label: "CLI", value: store.cursorLocalSession.executablePath ?? "감지 불가", color: store.cursorLocalSession.executablePath == nil ? Theme.textTertiary : Theme.textSecondary)
                SettingStatusRow(label: "오늘 로컬 사용량", value: store.cursorUsage?.primary.valueText ?? "없음", color: store.cursorUsage == nil ? Theme.textTertiary : Theme.textSecondary)
                AuthControlPanel(
                    title: "Cursor Agent CLI",
                    detail: "터미널에서 agent login 또는 cursor-agent login을 실행해 현재 Mac의 Cursor CLI를 인증합니다.",
                    primaryTitle: "CLI 로그인",
                    secondaryTitle: "CLI 로그아웃",
                    onPrimary: {
                        openTerminalCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if command -v agent >/dev/null 2>&1; then
                              agent login
                            elif command -v cursor-agent >/dev/null 2>&1; then
                              cursor-agent login
                            else
                              echo "Cursor Agent CLI가 설치되어 있지 않습니다."
                              echo "공식 설치 후 다시 시도하세요: curl https://cursor.com/install -fsS | bash"
                            fi
                            """,
                            title: "Cursor CLI 로그인",
                            provider: .cursor
                        )
                    },
                    onSecondary: {
                        runShellCommand(
                            """
                            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                            if command -v agent >/dev/null 2>&1; then
                              agent logout
                            elif command -v cursor-agent >/dev/null 2>&1; then
                              cursor-agent logout
                            else
                              exit 127
                            fi
                            """,
                            successMessage: "Cursor CLI 로그아웃 실행됨",
                            failureMessage: "Cursor CLI 로그아웃 실행 실패",
                            provider: .cursor,
                            onComplete: { store.refreshLocalSessions() }
                        )
                    },
                    docsTitle: "문서",
                    onDocs: { openExternalURL("https://cursor.com/docs/cli/overview") }
                )
                if store.hasCursorTeamKey {
                    Divider().background(Color.white.opacity(0.06))
                    SettingsTextField(
                        label: "Team / Workspace",
                        placeholder: "팀 식별용 이름 또는 ID",
                        text: Binding(get: { store.cursorTeamID }, set: { store.setCursorTeamID($0) })
                    )
                    SecretInputRow(
                        title: "Team API key 대안",
                        placeholder: "key_...",
                        text: $cursorKeyInput,
                        isStored: store.hasCursorTeamKey,
                        onSave: {
                            store.saveSecret(.cursorTeamKey, value: cursorKeyInput)
                            cursorKeyInput = ""
                        },
                        onDelete: { store.deleteSecret(.cursorTeamKey) }
                    )
                }
            }
        }
    }

    // 부가 기능이므로 카드 강조 없이 뮤트된 하단 섹션으로 처리한다.
    var diagnosticsSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().background(Theme.cardStroke).padding(.bottom, 2)

            Text("진단")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)

            SettingToggleRow(
                title: "익명 사용 진단",
                subtitle: "문제 발생률·환경(프록시 등)만 익명으로 집계합니다. 토큰·사용량은 전송하지 않습니다.",
                isOn: Binding(
                    get: { store.telemetryEnabled },
                    set: { store.setTelemetryEnabled($0) }
                )
            )

            SettingToggleRow(
                title: "로컬 진단 로그",
                subtitle: "이 맥에만 기록합니다(최대 512KB). 문제 재현 시 켠 뒤 로그 파일을 공유하세요.",
                isOn: Binding(
                    get: { store.diagnosticLoggingEnabled },
                    set: { store.setDiagnosticLoggingEnabled($0) }
                )
            )

            Button(action: openDiagnosticLogFolder) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text("로그 폴더 열기")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(store.diagnosticLoggingEnabled ? 0.9 : 0.5)
            .padding(.top, 1)
        }
        .padding(.horizontal, 4)
    }

    func openDiagnosticLogFolder() {
        let dir = DiagnosticLog.directoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    var settingsReviewCard: some View {
        Card("연동 가능 범위") {
            VStack(spacing: 9) {
                CapabilityRow(provider: "Claude", capability: "공식 개인 사용량 읽기 가능 · 로그인/로그아웃은 Claude Code CLI에서 처리")
                CapabilityRow(provider: "Codex", capability: "로컬 CLI 세션 자동 감지 · 개인 Codex quota API는 공개 확인 전까지 수집 제외")
                CapabilityRow(provider: "Cursor", capability: "Cursor Agent CLI 실행 파일 감지 · login/logout은 CLI에서 처리")
                CapabilityRow(provider: "Gemini", capability: "Gemini CLI OAuth 감지 · /auth와 /stats 흐름 기준")
                CapabilityRow(provider: "OpenAI API", capability: "CLI 대상 아님 · API 조직 Usage/Cost는 Admin key 필요")
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

    func openTerminalCommand(_ command: String, title: String, provider: AIProviderKind) {
        let script = """
        #!/bin/zsh
        echo "\(title)"
        echo
        \(command)
        echo
        echo "로그인이 끝나면 이 창을 닫아도 됩니다."
        read -k 1 "?아무 키나 누르면 창을 닫습니다."
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            store.setSettingsMessage("\(title) 터미널을 열었습니다. 완료 후 자동 감지합니다.", provider: provider)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { store.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { store.refresh() }
        } catch {
            store.setSettingsMessage("\(title) 터미널 실행 준비에 실패했습니다.", provider: provider)
        }
    }

    func runShellCommand(
        _ command: String,
        successMessage: String,
        failureMessage: String,
        provider: AIProviderKind? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            store.setSettingsMessage(task.terminationStatus == 0 ? successMessage : failureMessage, provider: provider)
        } catch {
            store.setSettingsMessage(failureMessage, provider: provider)
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
                ProviderBrandMark(
                    provider: provider,
                    size: 15,
                    color: isSelected ? providerColor(provider) : Theme.textSecondary
                )
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

struct ProviderTabDropDelegate: DropDelegate {
    let target: AIProviderKind
    @Binding var draggingProvider: AIProviderKind?
    let moveAction: (AIProviderKind, AIProviderKind) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingProvider, draggingProvider != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            moveAction(draggingProvider, target)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProvider = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct ProviderBrandMark: View {
    let provider: AIProviderKind
    let size: CGFloat
    let color: Color

    var body: some View {
        Group {
            switch provider {
            case .claude:
                Text("✹")
                    .font(.system(size: size, weight: .bold, design: .rounded))
            case .codex:
                Text(">_")
                    .font(.system(size: size * 0.78, weight: .bold, design: .monospaced))
            case .cursor:
                Text("⌖")
                    .font(.system(size: size * 0.95, weight: .bold, design: .rounded))
            case .gemini:
                Text("✦")
                    .font(.system(size: size, weight: .bold, design: .rounded))
            case .openAI:
                Text("◎")
                    .font(.system(size: size * 1.05, weight: .bold, design: .rounded))
            }
        }
        .foregroundColor(color)
        .frame(width: size * 1.35, height: size * 1.35)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityLabel(provider.displayName)
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

struct UsageLimitRow: View {
    let title: String
    let percent: Double?
    let resetAt: Date?
    let trailing: String?

    var body: some View {
        let pct = percent ?? 0
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
                Text(percent == nil ? "—" : "\(Int(pct.rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(percent == nil ? Theme.textTertiary : Theme.percentColor(pct))
            }
            ProgressBar(percent: pct, color: percent == nil ? Theme.textTertiary : Theme.percentColor(pct), height: 6)
            HStack {
                Text(friendlyRemaining(until: resetAt))
                Spacer()
                Text(formatResetClock(resetAt))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
        }
    }
}

struct UsageAmountRow: View {
    let title: String
    let value: String
    let detail: String?
    let resetAt: Date?
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                }
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            ProgressBar(percent: 0, color: color, height: 6)
                .opacity(0.55)
            HStack {
                Text(friendlyRemaining(until: resetAt))
                Spacer()
                Text(formatResetClock(resetAt))
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

struct AccountStatusPill: View {
    let provider: AIProviderKind
    let status: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ProviderBrandMark(
                    provider: provider,
                    size: 14,
                    color: isSelected ? providerColor(provider) : Theme.textSecondary
                )
                Text(provider.menuName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                    Text(status)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? providerColor(provider).opacity(0.13) : Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? providerColor(provider).opacity(0.35) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct AccountHeader: View {
    let provider: AIProviderKind
    let status: String
    let color: Color

    var subtitle: String {
        switch provider {
        case .claude:
            return "Claude Code CLI"
        case .codex:
            return "Codex CLI"
        case .cursor:
            return "Cursor Agent CLI"
        case .gemini:
            return "Gemini CLI"
        case .openAI:
            return "API 고급 설정"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(providerColor(provider).opacity(0.16))
                ProviderBrandMark(provider: provider, size: 16, color: providerColor(provider))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer()
            StateBadge(text: status, color: color)
        }
    }
}

struct AuthControlPanel: View {
    let title: String
    let detail: String
    let primaryTitle: String
    let secondaryTitle: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let keyTitle: String?
    let keyPlaceholder: String
    let keyText: Binding<String>?
    let isKeyStored: Bool
    let onSaveKey: (() -> Void)?
    let docsTitle: String?
    let onDocs: (() -> Void)?

    init(
        title: String,
        detail: String,
        primaryTitle: String,
        secondaryTitle: String,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping () -> Void,
        keyTitle: String? = nil,
        keyPlaceholder: String = "",
        keyText: Binding<String>? = nil,
        isKeyStored: Bool = false,
        onSaveKey: (() -> Void)? = nil,
        docsTitle: String? = nil,
        onDocs: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.primaryTitle = primaryTitle
        self.secondaryTitle = secondaryTitle
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.keyTitle = keyTitle
        self.keyPlaceholder = keyPlaceholder
        self.keyText = keyText
        self.isKeyStored = isKeyStored
        self.onSaveKey = onSaveKey
        self.docsTitle = docsTitle
        self.onDocs = onDocs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                if keyTitle != nil {
                    Text(isKeyStored ? "저장됨" : "미저장")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isKeyStored ? Theme.success : Theme.warn)
                }
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                AuthButton(symbol: "person.crop.circle.badge.checkmark", title: primaryTitle, color: Theme.textPrimary, action: onPrimary)
                AuthButton(symbol: "rectangle.portrait.and.arrow.right", title: secondaryTitle, color: keyTitle == nil || isKeyStored ? Theme.warn : Theme.textTertiary, action: onSecondary)
                    .disabled(keyTitle != nil && !isKeyStored)
                if let docsTitle, let onDocs {
                    AuthButton(symbol: "book", title: docsTitle, color: Theme.textSecondary, action: onDocs)
                }
                Spacer(minLength: 0)
            }

            if let keyTitle, let keyText, let onSaveKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text(keyTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                    HStack(spacing: 8) {
                        SecureField(keyPlaceholder, text: keyText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                        Button("저장", action: onSaveKey)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                            .buttonStyle(.plain)
                            .disabled(keyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
    }
}

struct AuthButton: View {
    let symbol: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
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
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

                Button("저장", action: onSave)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("삭제", action: onDelete)
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

struct SettingToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(Theme.textTertiary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
                .scaleEffect(0.92, anchor: .trailing)
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
    case .codex:
        return Color(red: 0.56, green: 0.66, blue: 1.00)
    case .cursor:
        return Color(red: 0.95, green: 0.76, blue: 0.34)
    case .gemini:
        return Color(red: 0.43, green: 0.70, blue: 1.00)
    case .openAI:
        return Color(red: 0.36, green: 0.78, blue: 0.64)
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
