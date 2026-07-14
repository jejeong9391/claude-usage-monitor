import SwiftUI

/// 두 Provider 결과를 병합해 UI 에 게시한다.
/// 공식치(%·재설정)와 ccusage 상세는 독립적으로 갱신 — 한쪽 실패가 다른 쪽을 막지 않는다.
@MainActor
final class UsageStore: ObservableObject {
    private static let primaryProviderDefaultsKey = "primaryAIProvider"
    private static let providerOrderDefaultsKey = "providerTabOrder"
    private static let openAIOrganizationDefaultsKey = "openAIOrganizationID"
    private static let openAIProjectDefaultsKey = "openAIProjectID"
    private static let cursorTeamDefaultsKey = "cursorTeamID"
    private static let anthropicAdminWorkspaceDefaultsKey = "anthropicAdminWorkspaceID"
    private static let officialMinimumInterval: TimeInterval = 120
    private static let officialInitialBackoff: TimeInterval = 120
    private static let officialMaxBackoff: TimeInterval = 900
    private let defaults: UserDefaults
    private var refreshInFlight = false
    private var officialCooldownUntil: Date?
    private var officialBackoffSeconds = UsageStore.officialInitialBackoff
    private var didEmitSessionTelemetry = false
    @Published var officialRetryAt: Date?

    // 공식 (진실의 원천). 성공값은 유지하고 상태만 따로 표시 → 오프라인 시 직전 값 노출.
    @Published var official: OfficialUsage?
    @Published var officialState: OfficialResult = .loading

    // ccusage (참고 상세)
    @Published var block: Block?
    @Published var weeklyCost: Double?

    @Published var lastUpdate: Date = Date()
    @Published var loading: Bool = true
    @Published var primaryProvider: AIProviderKind
    @Published var providerOrder: [AIProviderKind]
    @Published var snapshots: [ProviderSnapshot]
    @Published var openAIOrganizationID: String
    @Published var openAIProjectID: String
    @Published var cursorTeamID: String
    @Published var anthropicAdminWorkspaceID: String
    @Published var hasOpenAIAdminKey: Bool
    @Published var hasGeminiAPIKey: Bool
    @Published var hasCursorTeamKey: Bool
    @Published var hasAnthropicAdminKey: Bool
    @Published var claudeLocalSession: ClaudeLocalSession
    @Published var openAILocalSession: OpenAILocalSession
    @Published var geminiLocalSession: GeminiLocalSession
    @Published var codexLocalSession: CodexLocalSession
    @Published var cursorLocalSession: CursorLocalSession
    @Published var openAIUsage: LocalUsageSummary?
    @Published var codexUsage: LocalUsageSummary?
    @Published var cursorUsage: LocalUsageSummary?
    @Published var settingsMessage: String?
    @Published var settingsMessageProvider: AIProviderKind?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.primaryProviderDefaultsKey),
           let provider = AIProviderKind(rawValue: saved) {
            self.primaryProvider = provider
        } else {
            self.primaryProvider = .claude
        }
        self.providerOrder = Self.loadProviderOrder(defaults)
        self.openAIOrganizationID = defaults.string(forKey: Self.openAIOrganizationDefaultsKey) ?? ""
        self.openAIProjectID = defaults.string(forKey: Self.openAIProjectDefaultsKey) ?? ""
        self.cursorTeamID = defaults.string(forKey: Self.cursorTeamDefaultsKey) ?? ""
        self.anthropicAdminWorkspaceID = defaults.string(forKey: Self.anthropicAdminWorkspaceDefaultsKey) ?? ""
        let openAIKeyExists = SecretStore.exists(.openAIAdminKey)
        let geminiKeyExists = SecretStore.exists(.geminiAPIKey)
        let cursorKeyExists = SecretStore.exists(.cursorTeamKey)
        let anthropicKeyExists = SecretStore.exists(.anthropicAdminKey)
        let localSessions = LocalSessionDetector.detectAll(
            hasOpenAIAdminKey: openAIKeyExists,
            hasGeminiAPIKey: geminiKeyExists,
            hasCursorTeamKey: cursorKeyExists,
            hasAnthropicAdminKey: anthropicKeyExists
        )
        let openAIUsage: LocalUsageSummary? = nil
        let codexUsage: LocalUsageSummary? = nil
        let cursorUsage: LocalUsageSummary? = nil
        self.hasOpenAIAdminKey = openAIKeyExists
        self.hasGeminiAPIKey = geminiKeyExists
        self.hasCursorTeamKey = cursorKeyExists
        self.hasAnthropicAdminKey = anthropicKeyExists
        self.claudeLocalSession = localSessions.claude
        self.openAILocalSession = localSessions.openAI
        self.geminiLocalSession = localSessions.gemini
        self.codexLocalSession = localSessions.codex
        self.cursorLocalSession = localSessions.cursor
        self.openAIUsage = openAIUsage
        self.codexUsage = codexUsage
        self.cursorUsage = cursorUsage
        self.snapshots = UsageStore.placeholderSnapshots(
            updatedAt: nil,
            openAIConfigured: openAIKeyExists,
            openAILocalSession: localSessions.openAI,
            openAIUsage: openAIUsage,
            geminiConfigured: geminiKeyExists,
            geminiLocalSession: localSessions.gemini,
            codexLocalSession: localSessions.codex,
            codexUsage: codexUsage,
            cursorConfigured: cursorKeyExists,
            cursorLocalSession: localSessions.cursor,
            cursorUsage: cursorUsage
        )
    }

    func refresh(forceOfficial: Bool = false) {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let organizationID = openAIOrganizationID
        let projectID = openAIProjectID
        let teamID = cursorTeamID
        let now = Date()
        let shouldFetchOfficial = forceOfficial || officialCooldownUntil.map { now >= $0 } ?? true
        let currentOfficialState = officialState
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: OfficialFetchOutcome? = shouldFetchOfficial ? OfficialUsageProvider.fetch() : nil
            let off = outcome?.result ?? currentOfficialState
            let proxy: ProxyStatus? = shouldFetchOfficial ? currentProxyStatus() : nil
            let block = CCUsageProvider.activeBlock()
            let wCost = CCUsageProvider.weeklyCost()
            let openAIKeyExists = SecretStore.exists(.openAIAdminKey)
            let geminiKeyExists = SecretStore.exists(.geminiAPIKey)
            let cursorKeyExists = SecretStore.exists(.cursorTeamKey)
            let anthropicKeyExists = SecretStore.exists(.anthropicAdminKey)
            let localSessions = LocalSessionDetector.detectAll(
                hasOpenAIAdminKey: openAIKeyExists,
                hasGeminiAPIKey: geminiKeyExists,
                hasCursorTeamKey: cursorKeyExists,
                hasAnthropicAdminKey: anthropicKeyExists
            )
            let openAIUsage = OpenAIUsageProvider.today(organizationID: organizationID, projectID: projectID)
            let codexUsage = CodexUsageProvider.today()
            let cursorUsage = CursorTeamUsageProvider.today(teamID: teamID)
            await self?.apply(
                off: off,
                outcome: outcome,
                proxy: proxy,
                block: block,
                weeklyCost: wCost,
                hasOpenAIAdminKey: openAIKeyExists,
                hasGeminiAPIKey: geminiKeyExists,
                hasCursorTeamKey: cursorKeyExists,
                hasAnthropicAdminKey: anthropicKeyExists,
                localSessions: localSessions,
                openAIUsage: openAIUsage,
                codexUsage: codexUsage,
                cursorUsage: cursorUsage,
                fetchedOfficial: shouldFetchOfficial
            )
        }
    }

    private func apply(
        off: OfficialResult,
        outcome: OfficialFetchOutcome?,
        proxy: ProxyStatus?,
        block: Block?,
        weeklyCost: Double?,
        hasOpenAIAdminKey: Bool,
        hasGeminiAPIKey: Bool,
        hasCursorTeamKey: Bool,
        hasAnthropicAdminKey: Bool,
        localSessions: LocalSessionSnapshot,
        openAIUsage: LocalUsageSummary?,
        codexUsage: LocalUsageSummary?,
        cursorUsage: LocalUsageSummary?,
        fetchedOfficial: Bool
    ) {
        refreshInFlight = false
        if fetchedOfficial {
            updateOfficialCooldown(after: off)
        }
        if fetchedOfficial, let outcome, let proxy {
            let previousName = officialState.telemetryName   // still previous — before officialState = off below
            DiagnosticLog.log(outcome: outcome, proxy: proxy)
            Telemetry.trackOfficialResult(
                outcome: outcome, proxy: proxy,
                previous: previousName,
                firstOfSession: !didEmitSessionTelemetry)
            didEmitSessionTelemetry = true
        }
        officialState = off
        if case let .ok(usage) = off { official = usage }
        self.block = block
        self.weeklyCost = weeklyCost
        self.hasOpenAIAdminKey = hasOpenAIAdminKey
        self.hasGeminiAPIKey = hasGeminiAPIKey
        self.hasCursorTeamKey = hasCursorTeamKey
        self.hasAnthropicAdminKey = hasAnthropicAdminKey
        self.claudeLocalSession = localSessions.claude
        self.openAILocalSession = localSessions.openAI
        self.geminiLocalSession = localSessions.gemini
        self.codexLocalSession = localSessions.codex
        self.cursorLocalSession = localSessions.cursor
        self.openAIUsage = openAIUsage
        self.codexUsage = codexUsage
        self.cursorUsage = cursorUsage
        lastUpdate = Date()
        loading = false
        snapshots = Self.makeSnapshots(
            official: official,
            officialState: officialState,
            block: block,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: localSessions.openAI,
            openAIUsage: openAIUsage,
            geminiConfigured: hasGeminiAPIKey,
            geminiLocalSession: localSessions.gemini,
            codexLocalSession: localSessions.codex,
            codexUsage: codexUsage,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: localSessions.cursor,
            cursorUsage: cursorUsage,
            loading: loading,
            updatedAt: lastUpdate
        )
    }

    private func updateOfficialCooldown(after result: OfficialResult) {
        let now = Date()
        switch result {
        case .ok(let usage):
            let nextRegularRefresh = now.addingTimeInterval(Self.officialMinimumInterval)
            if let reset = parseDate(usage.fiveHour?.resetsAt), reset > now {
                officialCooldownUntil = min(nextRegularRefresh, reset.addingTimeInterval(3))
            } else {
                officialCooldownUntil = now.addingTimeInterval(30)
            }
            officialBackoffSeconds = Self.officialInitialBackoff
            officialRetryAt = nil
        case .rateLimited:
            let interval = official == nil ? min(officialBackoffSeconds, 60) : officialBackoffSeconds
            let retryAt = now.addingTimeInterval(interval)
            officialCooldownUntil = retryAt
            officialRetryAt = retryAt
            officialBackoffSeconds = min(officialBackoffSeconds * 2, Self.officialMaxBackoff)
        case .offline:
            officialCooldownUntil = now.addingTimeInterval(60)
            officialRetryAt = nil
        case .noToken, .unauthorized, .loading:
            officialCooldownUntil = nil
            officialRetryAt = nil
        }
    }

    func setPrimaryProvider(_ provider: AIProviderKind) {
        primaryProvider = provider
        defaults.set(provider.rawValue, forKey: Self.primaryProviderDefaultsKey)
    }

    func moveProviderTab(_ source: AIProviderKind, to target: AIProviderKind) {
        guard source != target,
              let from = providerOrder.firstIndex(of: source),
              let to = providerOrder.firstIndex(of: target)
        else {
            return
        }

        var order = providerOrder
        let item = order.remove(at: from)
        let insertionIndex = min(to, order.count)
        order.insert(item, at: insertionIndex)
        providerOrder = Self.normalizedProviderOrder(order)
        defaults.set(providerOrder.map(\.rawValue), forKey: Self.providerOrderDefaultsKey)
    }

    var primarySnapshot: ProviderSnapshot {
        snapshot(for: primaryProvider)
        ?? snapshots.first
        ?? Self.placeholderSnapshots(
            updatedAt: lastUpdate,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: openAILocalSession,
            openAIUsage: openAIUsage,
            geminiConfigured: hasGeminiAPIKey,
            geminiLocalSession: geminiLocalSession,
            codexLocalSession: codexLocalSession,
            codexUsage: codexUsage,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: cursorLocalSession,
            cursorUsage: cursorUsage
        )[0]
    }

    func snapshot(for provider: AIProviderKind) -> ProviderSnapshot? {
        snapshots.first(where: { $0.provider == provider })
    }

    func setOpenAIOrganizationID(_ value: String) {
        openAIOrganizationID = value
        defaults.set(value, forKey: Self.openAIOrganizationDefaultsKey)
    }

    func setOpenAIProjectID(_ value: String) {
        openAIProjectID = value
        defaults.set(value, forKey: Self.openAIProjectDefaultsKey)
    }

    func setCursorTeamID(_ value: String) {
        cursorTeamID = value
        defaults.set(value, forKey: Self.cursorTeamDefaultsKey)
    }

    func setAnthropicAdminWorkspaceID(_ value: String) {
        anthropicAdminWorkspaceID = value
        defaults.set(value, forKey: Self.anthropicAdminWorkspaceDefaultsKey)
    }

    func saveSecret(_ kind: ProviderSecretKind, value: String) {
        let ok = SecretStore.save(kind, value: value)
        refreshSecretStatus()
        setSettingsMessage(ok ? "\(kind.displayName) 저장됨" : "\(kind.displayName) 저장 실패", provider: kind.provider)
        if ok { refresh() }
    }

    func deleteSecret(_ kind: ProviderSecretKind) {
        let ok = SecretStore.delete(kind)
        refreshSecretStatus()
        setSettingsMessage(ok ? "\(kind.displayName) 삭제됨" : "\(kind.displayName) 삭제할 항목 없음", provider: kind.provider)
        if ok { refresh() }
    }

    func setSettingsMessage(_ message: String, provider: AIProviderKind? = nil) {
        settingsMessage = message
        settingsMessageProvider = provider
    }

    func clearSettingsMessage() {
        settingsMessage = nil
        settingsMessageProvider = nil
    }

    func refreshSecretStatus() {
        hasOpenAIAdminKey = SecretStore.exists(.openAIAdminKey)
        hasGeminiAPIKey = SecretStore.exists(.geminiAPIKey)
        hasCursorTeamKey = SecretStore.exists(.cursorTeamKey)
        hasAnthropicAdminKey = SecretStore.exists(.anthropicAdminKey)
        refreshLocalSessions()
    }

    func refreshLocalSessions() {
        let localSessions = LocalSessionDetector.detectAll(
            hasOpenAIAdminKey: hasOpenAIAdminKey,
            hasGeminiAPIKey: hasGeminiAPIKey,
            hasCursorTeamKey: hasCursorTeamKey,
            hasAnthropicAdminKey: hasAnthropicAdminKey
        )
        claudeLocalSession = localSessions.claude
        openAILocalSession = localSessions.openAI
        geminiLocalSession = localSessions.gemini
        codexLocalSession = localSessions.codex
        cursorLocalSession = localSessions.cursor
        openAIUsage = nil
        codexUsage = CodexUsageProvider.today()
        cursorUsage = CursorUsageProvider.today()
        rebuildSnapshots()
    }

    // 메뉴바 타이틀은 설정된 기본 AI의 snapshot 포맷을 그대로 따른다.
    var menuBarTitle: String {
        if primaryProvider == .claude,
           let fiveHour = official?.fiveHour {
            let pct = Int(fiveHourDisplayUtilization(fiveHour).rounded())
            if let reset = fiveHourDisplayReset(fiveHour) {
                return "🔥 \(pct)% · \(compactRemaining(until: reset))"
            }
            return "🔥 \(pct)% · 시작 전"
        }
        return primarySnapshot.menuBarTitle
    }
}

private extension UsageStore {
    static func loadProviderOrder(_ defaults: UserDefaults) -> [AIProviderKind] {
        normalizedProviderOrder(
            defaults.stringArray(forKey: providerOrderDefaultsKey)?
                .compactMap(AIProviderKind.init(rawValue:)) ?? []
        )
    }

    static func normalizedProviderOrder(_ candidates: [AIProviderKind]) -> [AIProviderKind] {
        let defaultOrder: [AIProviderKind] = [.claude, .codex, .cursor, .gemini, .openAI]
        var seen = Set<AIProviderKind>()
        var result: [AIProviderKind] = []
        for provider in candidates + defaultOrder where provider != .openAI && !seen.contains(provider) {
            seen.insert(provider)
            result.append(provider)
        }
        result.append(.openAI)
        return result
    }

    func rebuildSnapshots() {
        snapshots = Self.makeSnapshots(
            official: official,
            officialState: officialState,
            block: block,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: openAILocalSession,
            openAIUsage: openAIUsage,
            geminiConfigured: hasGeminiAPIKey,
            geminiLocalSession: geminiLocalSession,
            codexLocalSession: codexLocalSession,
            codexUsage: codexUsage,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: cursorLocalSession,
            cursorUsage: cursorUsage,
            loading: loading,
            updatedAt: lastUpdate
        )
    }

    static func placeholderSnapshots(
        updatedAt: Date?,
        openAIConfigured: Bool,
        openAILocalSession: OpenAILocalSession,
        openAIUsage: LocalUsageSummary?,
        geminiConfigured: Bool,
        geminiLocalSession: GeminiLocalSession,
        codexLocalSession: CodexLocalSession,
        codexUsage: LocalUsageSummary?,
        cursorConfigured: Bool,
        cursorLocalSession: CursorLocalSession,
        cursorUsage: LocalUsageSummary?
    ) -> [ProviderSnapshot] {
        [
            ProviderSnapshot(
                provider: .claude,
                title: AIProviderKind.claude.displayName,
                sourceKind: .officialPersonal,
                confidence: .unavailable,
                state: .loading,
                stateMessage: "Claude Code 공식 사용량을 불러오는 중입니다.",
                period: .fiveHour,
                primary: .status("로딩"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: nil,
                updatedAt: updatedAt
            ),
            codexSnapshot(localSession: codexLocalSession, localUsage: codexUsage, updatedAt: updatedAt),
            cursorSnapshot(updatedAt: updatedAt, configured: cursorConfigured, localSession: cursorLocalSession, localUsage: cursorUsage),
            geminiSnapshot(updatedAt: updatedAt, configured: geminiConfigured, localSession: geminiLocalSession),
            openAISnapshot(updatedAt: updatedAt, configured: openAIConfigured, localSession: openAILocalSession, localUsage: openAIUsage)
        ]
    }

    static func makeSnapshots(
        official: OfficialUsage?,
        officialState: OfficialResult,
        block: Block?,
        openAIConfigured: Bool,
        openAILocalSession: OpenAILocalSession,
        openAIUsage: LocalUsageSummary?,
        geminiConfigured: Bool,
        geminiLocalSession: GeminiLocalSession,
        codexLocalSession: CodexLocalSession,
        codexUsage: LocalUsageSummary?,
        cursorConfigured: Bool,
        cursorLocalSession: CursorLocalSession,
        cursorUsage: LocalUsageSummary?,
        loading: Bool,
        updatedAt: Date
    ) -> [ProviderSnapshot] {
        [
            claudeSnapshot(
                official: official,
                officialState: officialState,
                block: block,
                loading: loading,
                updatedAt: updatedAt
            ),
            codexSnapshot(localSession: codexLocalSession, localUsage: codexUsage, updatedAt: updatedAt),
            cursorSnapshot(updatedAt: updatedAt, configured: cursorConfigured, localSession: cursorLocalSession, localUsage: cursorUsage),
            geminiSnapshot(updatedAt: updatedAt, configured: geminiConfigured, localSession: geminiLocalSession),
            openAISnapshot(updatedAt: updatedAt, configured: openAIConfigured, localSession: openAILocalSession, localUsage: openAIUsage)
        ]
    }

    static func claudeSnapshot(
        official: OfficialUsage?,
        officialState: OfficialResult,
        block: Block?,
        loading: Bool,
        updatedAt: Date
    ) -> ProviderSnapshot {
        let reset = fiveHourDisplayReset(official?.fiveHour)
        let sessionStarted = fiveHourSessionStarted(official?.fiveHour)
        let isExpiredFiveHour = fiveHourWindowExpired(official?.fiveHour)
        let primary: UsageMetric
        if let fiveHour = official?.fiveHour {
            primary = .percent(fiveHourDisplayUtilization(fiveHour))
        } else {
            primary = .status(claudeStatusText(for: officialState, loading: loading))
        }

        let state = claudeProviderState(official: official, officialState: officialState, loading: loading, expiredFiveHour: isExpiredFiveHour)
        let sourceKind: UsageSourceKind = state == .setupRequired ? .setupRequired : .officialPersonal
        let confidence: UsageConfidence
        switch state {
        case .ready:
            confidence = .official
        case .stale:
            confidence = .stale
        case .setupRequired:
            confidence = .setupRequired
        default:
            confidence = .unavailable
        }

        let modelSummary: String?
        if let models = block?.models, !models.isEmpty {
            modelSummary = models.map { $0.replacingOccurrences(of: "claude-", with: "") }.joined(separator: ", ")
        } else {
            modelSummary = nil
        }

        return ProviderSnapshot(
            provider: .claude,
            title: AIProviderKind.claude.displayName,
            sourceKind: sourceKind,
            confidence: confidence,
            state: state,
            stateMessage: claudeSnapshotMessage(
                officialState: officialState,
                hasOfficial: official != nil,
                loading: loading,
                expiredFiveHour: isExpiredFiveHour,
                sessionStarted: sessionStarted
            ),
            period: .fiveHour,
            primary: primary,
            resetAt: reset,
            costUSD: block?.costUSD,
            inputTokens: block?.tokenCounts.inputTokens,
            outputTokens: block?.tokenCounts.outputTokens,
            totalTokens: block?.tokenCounts.total,
            requestCount: block?.entries,
            modelSummary: modelSummary,
            updatedAt: updatedAt
        )
    }

    static func claudeSnapshotMessage(
        officialState: OfficialResult,
        hasOfficial: Bool,
        loading: Bool,
        expiredFiveHour: Bool,
        sessionStarted: Bool
    ) -> String {
        if expiredFiveHour {
            return "직전 5시간 공식 창이 종료되었습니다. 새 메시지를 보내면 다음 세션 reset 시간이 표시됩니다."
        }
        if hasOfficial, !sessionStarted {
            return "아직 현재 5시간 세션이 시작되지 않았습니다. Claude Code에서 메시지를 보내면 reset 시간이 표시됩니다."
        }
        return claudeStateMessage(for: officialState, hasOfficial: hasOfficial, loading: loading)
    }

    static func claudeProviderState(
        official: OfficialUsage?,
        officialState: OfficialResult,
        loading: Bool,
        expiredFiveHour: Bool = false
    ) -> ProviderState {
        if loading { return .loading }
        if expiredFiveHour, official != nil { return .stale }
        switch officialState {
        case .ok:
            return .ready
        case .loading:
            return .loading
        case .noToken:
            return .setupRequired
        case .unauthorized:
            return official == nil ? .unauthorized : .stale
        case .rateLimited:
            return official == nil ? .rateLimited : .stale
        case .offline:
            return official == nil ? .offline : .stale
        }
    }

    static func claudeStatusText(for state: OfficialResult, loading: Bool) -> String {
        if loading { return "로딩" }
        switch state {
        case .ok: return "대기"
        case .loading: return "로딩"
        case .noToken: return "로그인 필요"
        case .unauthorized: return "재인증 필요"
        case .rateLimited: return "호출 제한"
        case .offline: return "오프라인"
        }
    }

    static func claudeStateMessage(for state: OfficialResult, hasOfficial: Bool, loading: Bool) -> String {
        if loading { return "Claude Code 공식 사용량을 불러오는 중입니다." }
        switch state {
        case .ok:
            return "Anthropic 공식 사용량을 기준으로 표시합니다. 비용과 토큰은 ccusage 로컬 추정치입니다."
        case .loading:
            return "Claude Code 공식 사용량을 불러오는 중입니다."
        case .noToken:
            return "Keychain에서 Claude Code 자격증명을 찾지 못했습니다. Claude Code 로그인 후 다시 시도하세요."
        case .unauthorized:
            return hasOfficial ? "인증 갱신에 실패해 직전 공식 값을 표시 중입니다." : "Claude Code 토큰이 만료되었습니다. Claude Code를 다시 사용해 재인증하세요."
        case .rateLimited:
            return hasOfficial ? "Anthropic 사용량 API가 제한되어 직전 공식 값을 표시 중입니다." : "Anthropic 사용량 API 요청이 일시적으로 제한되었습니다."
        case .offline:
            return hasOfficial ? "네트워크 오류로 직전 공식 값을 표시 중입니다." : "네트워크 연결 또는 Anthropic 사용량 API 응답을 확인하세요."
        }
    }

    static func geminiSnapshot(updatedAt: Date?, configured: Bool, localSession: GeminiLocalSession) -> ProviderSnapshot {
        if localSession.isLoggedIn {
            let isCLI = localSession.authModeLabel == "Google OAuth"
            return ProviderSnapshot(
                provider: .gemini,
                title: AIProviderKind.gemini.displayName,
                sourceKind: .localSession,
                confidence: isCLI ? .localDetected : .configured,
                state: isCLI ? .ready : .configured,
                stateMessage: isCLI
                    ? "Gemini CLI Google OAuth 로그인을 감지했습니다. 세션 사용량은 Gemini CLI 로컬 로그와 /stats 기준으로 연결합니다."
                    : "Gemini API key를 감지했습니다. CLI OAuth가 없을 때의 보조 자격증명이며, 직접 호출하지 않은 Gemini CLI 과거 사용량을 대체하지 않습니다.",
                period: .today,
                primary: .status(isCLI ? "로그인됨" : "키 저장됨"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: localSession.authModeLabel,
                updatedAt: updatedAt
            )
        }
        switch localSession.state {
        case .loggedOut:
            return ProviderSnapshot.setupRequired(
                provider: .gemini,
                period: .today,
                message: "Gemini CLI는 감지했지만 Google OAuth 로그인이 없습니다. 터미널에서 gemini를 실행한 뒤 Sign in with Google 또는 /auth로 로그인하세요.",
                updatedAt: updatedAt
            )
        case .unavailable:
            return ProviderSnapshot.unavailable(
                provider: .gemini,
                message: "Gemini CLI 또는 로컬 OAuth 자격증명을 감지하지 못했습니다.",
                updatedAt: updatedAt
            )
        case .loggedIn:
            return ProviderSnapshot.setupRequired(
                provider: .gemini,
                period: .today,
                message: "Gemini CLI 로그인 상태를 다시 확인하세요.",
                updatedAt: updatedAt
            )
        }
    }

    static func openAISnapshot(updatedAt: Date?, configured: Bool, localSession: OpenAILocalSession, localUsage: LocalUsageSummary?) -> ProviderSnapshot {
        if let localUsage {
            return ProviderSnapshot(
                provider: .openAI,
                title: AIProviderKind.openAI.displayName,
                sourceKind: localUsage.sourceKind,
                confidence: localUsage.confidence,
                state: .ready,
                stateMessage: localUsage.stateMessage,
                period: localUsage.period,
                primary: localUsage.primary,
                resetAt: localUsage.primaryResetAt,
                costUSD: localUsage.costUSD,
                inputTokens: localUsage.inputTokens,
                outputTokens: localUsage.outputTokens,
                totalTokens: localUsage.totalTokens,
                requestCount: localUsage.requestCount,
                modelSummary: localUsage.modelSummary,
                updatedAt: localUsage.updatedAt ?? updatedAt
            )
        }
        if configured {
            return ProviderSnapshot(
                provider: .openAI,
                title: AIProviderKind.openAI.displayName,
                sourceKind: .officialAdmin,
                confidence: .configured,
                state: .configured,
                stateMessage: "OpenAI Admin API key가 Keychain에 저장되어 있지만 이번 갱신에서 Usage/Cost API 응답을 받지 못했습니다.",
                period: .today,
                primary: .status("설정됨"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: nil,
                updatedAt: updatedAt
            )
        }
        if localSession.isLoggedIn {
            return ProviderSnapshot(
                provider: .openAI,
                title: AIProviderKind.openAI.displayName,
                sourceKind: .localSession,
                confidence: .localDetected,
                state: .setupRequired,
                stateMessage: "로컬 OpenAI 자격증명을 감지했습니다. 조직 Usage/Cost API 수집은 Admin key 권한을 확인한 뒤 연결합니다.",
                period: .today,
                primary: .status("권한 확인 필요"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: localSession.authModeLabel,
                updatedAt: updatedAt
            )
        }
        return ProviderSnapshot.setupRequired(
            provider: .openAI,
            period: .today,
            message: "OpenAI Admin API key를 Keychain에 저장하면 공식 Usage/Cost API로 API 사용량을 집계할 수 있습니다.",
            updatedAt: updatedAt
        )
    }

    static func codexSnapshot(localSession: CodexLocalSession, localUsage: LocalUsageSummary?, updatedAt: Date?) -> ProviderSnapshot {
        switch localSession.state {
        case .loggedIn:
            if let localUsage {
                return ProviderSnapshot(
                    provider: .codex,
                    title: AIProviderKind.codex.displayName,
                    sourceKind: localUsage.sourceKind,
                    confidence: localUsage.confidence,
                    state: .ready,
                    stateMessage: localUsage.stateMessage,
                    period: localUsage.period,
                    primary: localUsage.primary,
                    resetAt: localUsage.primaryResetAt,
                    costUSD: localUsage.costUSD,
                    inputTokens: localUsage.inputTokens,
                    outputTokens: localUsage.outputTokens,
                    totalTokens: localUsage.totalTokens,
                    requestCount: localUsage.requestCount,
                    modelSummary: localUsage.modelSummary,
                    updatedAt: localUsage.updatedAt ?? updatedAt
                )
            }
            return ProviderSnapshot(
                provider: .codex,
                title: AIProviderKind.codex.displayName,
                sourceKind: .localSession,
                confidence: .localDetected,
                state: .ready,
                stateMessage: "로컬 Codex 로그인을 감지했습니다. 아직 로컬 session 로그 사용량을 찾지 못했습니다.",
                period: .none,
                primary: .status("로그인됨"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: localSession.authModeLabel,
                updatedAt: updatedAt
            )
        case .loggedOut:
            return ProviderSnapshot.setupRequired(
                provider: .codex,
                period: .none,
                message: "Codex CLI 로그인 상태를 감지하지 못했습니다. 터미널에서 codex login을 실행한 뒤 다시 확인하세요.",
                updatedAt: updatedAt
            )
        case .unavailable:
            return ProviderSnapshot.unavailable(
                provider: .codex,
                message: "Codex CLI 또는 로컬 자격증명 저장소를 감지하지 못했습니다.",
                updatedAt: updatedAt
            )
        }
    }

    static func cursorSnapshot(updatedAt: Date?, configured: Bool, localSession: CursorLocalSession, localUsage: LocalUsageSummary?) -> ProviderSnapshot {
        if let localUsage {
            return ProviderSnapshot(
                provider: .cursor,
                title: AIProviderKind.cursor.displayName,
                sourceKind: localUsage.sourceKind,
                confidence: localUsage.confidence,
                state: .ready,
                stateMessage: localUsage.stateMessage,
                period: localUsage.period,
                primary: localUsage.primary,
                resetAt: localUsage.primaryResetAt,
                costUSD: localUsage.costUSD,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: localUsage.totalTokens,
                requestCount: localUsage.requestCount,
                modelSummary: localUsage.modelSummary,
                updatedAt: localUsage.updatedAt ?? updatedAt
            )
        }
        if configured {
            return ProviderSnapshot(
                provider: .cursor,
                title: AIProviderKind.cursor.displayName,
                sourceKind: .officialAdmin,
                confidence: .configured,
                state: .configured,
                stateMessage: "Cursor Team API key가 Keychain에 저장되어 있습니다. CLI 로그인과는 별개인 팀 분석용 보조 자격증명입니다.",
                period: .month,
                primary: .status("키 저장됨"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: nil,
                updatedAt: updatedAt
            )
        }
        if localSession.state == .loggedOut {
            return ProviderSnapshot(
                provider: .cursor,
                title: AIProviderKind.cursor.displayName,
                sourceKind: .localSession,
                confidence: .localDetected,
                state: .setupRequired,
                stateMessage: localSession.executablePath == nil
                    ? "Cursor 로컬 데이터는 감지했지만 Cursor Agent CLI는 찾지 못했습니다. Cursor CLI 설치 후 로그인하세요."
                    : "Cursor Agent CLI는 감지했습니다. 설정에서 CLI 로그인 버튼을 눌러 agent login 또는 cursor-agent login을 실행하세요.",
                period: .month,
                primary: .status("CLI 로그인"),
                resetAt: nil,
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                requestCount: nil,
                modelSummary: nil,
                updatedAt: updatedAt
            )
        }
        return ProviderSnapshot.setupRequired(
            provider: .cursor,
            period: .month,
            message: "Cursor Agent CLI 또는 Cursor 로컬 데이터를 감지하지 못했습니다. Cursor CLI 설치와 로그인을 먼저 진행하세요.",
            updatedAt: updatedAt
        )
    }
}

extension OfficialResult {
    /// 사용자에게 '문제' 로 노출할 상태인가. 로딩과 정상은 에러가 아니다.
    var isError: Bool {
        switch self {
        case .ok, .loading: return false
        case .noToken, .unauthorized, .rateLimited, .offline: return true
        }
    }
}
