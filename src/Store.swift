import SwiftUI

/// 두 Provider 결과를 병합해 UI 에 게시한다.
/// 공식치(%·재설정)와 ccusage 상세는 독립적으로 갱신 — 한쪽 실패가 다른 쪽을 막지 않는다.
@MainActor
final class UsageStore: ObservableObject {
    private static let primaryProviderDefaultsKey = "primaryAIProvider"
    private static let openAIOrganizationDefaultsKey = "openAIOrganizationID"
    private static let openAIProjectDefaultsKey = "openAIProjectID"
    private static let cursorTeamDefaultsKey = "cursorTeamID"
    private static let anthropicAdminWorkspaceDefaultsKey = "anthropicAdminWorkspaceID"
    private let defaults: UserDefaults

    // 공식 (진실의 원천). 성공값은 유지하고 상태만 따로 표시 → 오프라인 시 직전 값 노출.
    @Published var official: OfficialUsage?
    @Published var officialState: OfficialResult = .loading

    // ccusage (참고 상세)
    @Published var block: Block?
    @Published var weeklyCost: Double?

    @Published var lastUpdate: Date = Date()
    @Published var loading: Bool = true
    @Published var primaryProvider: AIProviderKind
    @Published var snapshots: [ProviderSnapshot]
    @Published var openAIOrganizationID: String
    @Published var openAIProjectID: String
    @Published var cursorTeamID: String
    @Published var anthropicAdminWorkspaceID: String
    @Published var hasOpenAIAdminKey: Bool
    @Published var hasCursorTeamKey: Bool
    @Published var hasAnthropicAdminKey: Bool
    @Published var claudeLocalSession: ClaudeLocalSession
    @Published var openAILocalSession: OpenAILocalSession
    @Published var codexLocalSession: CodexLocalSession
    @Published var cursorLocalSession: CursorLocalSession
    @Published var settingsMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.primaryProviderDefaultsKey),
           let provider = AIProviderKind(rawValue: saved) {
            self.primaryProvider = provider
        } else {
            self.primaryProvider = .claude
        }
        self.openAIOrganizationID = defaults.string(forKey: Self.openAIOrganizationDefaultsKey) ?? ""
        self.openAIProjectID = defaults.string(forKey: Self.openAIProjectDefaultsKey) ?? ""
        self.cursorTeamID = defaults.string(forKey: Self.cursorTeamDefaultsKey) ?? ""
        self.anthropicAdminWorkspaceID = defaults.string(forKey: Self.anthropicAdminWorkspaceDefaultsKey) ?? ""
        let openAIKeyExists = SecretStore.exists(.openAIAdminKey)
        let cursorKeyExists = SecretStore.exists(.cursorTeamKey)
        let anthropicKeyExists = SecretStore.exists(.anthropicAdminKey)
        let localSessions = LocalSessionDetector.detectAll(
            hasOpenAIAdminKey: openAIKeyExists,
            hasCursorTeamKey: cursorKeyExists,
            hasAnthropicAdminKey: anthropicKeyExists
        )
        self.hasOpenAIAdminKey = openAIKeyExists
        self.hasCursorTeamKey = cursorKeyExists
        self.hasAnthropicAdminKey = anthropicKeyExists
        self.claudeLocalSession = localSessions.claude
        self.openAILocalSession = localSessions.openAI
        self.codexLocalSession = localSessions.codex
        self.cursorLocalSession = localSessions.cursor
        self.snapshots = UsageStore.placeholderSnapshots(
            updatedAt: nil,
            openAIConfigured: openAIKeyExists,
            openAILocalSession: localSessions.openAI,
            codexLocalSession: localSessions.codex,
            cursorConfigured: cursorKeyExists,
            cursorLocalSession: localSessions.cursor
        )
    }

    func refresh() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let off = OfficialUsageProvider.fetch()
            let block = CCUsageProvider.activeBlock()
            let wCost = CCUsageProvider.weeklyCost()
            let openAIKeyExists = SecretStore.exists(.openAIAdminKey)
            let cursorKeyExists = SecretStore.exists(.cursorTeamKey)
            let anthropicKeyExists = SecretStore.exists(.anthropicAdminKey)
            let localSessions = LocalSessionDetector.detectAll(
                hasOpenAIAdminKey: openAIKeyExists,
                hasCursorTeamKey: cursorKeyExists,
                hasAnthropicAdminKey: anthropicKeyExists
            )
            await self?.apply(
                off: off,
                block: block,
                weeklyCost: wCost,
                hasOpenAIAdminKey: openAIKeyExists,
                hasCursorTeamKey: cursorKeyExists,
                hasAnthropicAdminKey: anthropicKeyExists,
                localSessions: localSessions
            )
        }
    }

    private func apply(
        off: OfficialResult,
        block: Block?,
        weeklyCost: Double?,
        hasOpenAIAdminKey: Bool,
        hasCursorTeamKey: Bool,
        hasAnthropicAdminKey: Bool,
        localSessions: LocalSessionSnapshot
    ) {
        officialState = off
        if case let .ok(usage) = off { official = usage }
        self.block = block
        self.weeklyCost = weeklyCost
        self.hasOpenAIAdminKey = hasOpenAIAdminKey
        self.hasCursorTeamKey = hasCursorTeamKey
        self.hasAnthropicAdminKey = hasAnthropicAdminKey
        self.claudeLocalSession = localSessions.claude
        self.openAILocalSession = localSessions.openAI
        self.codexLocalSession = localSessions.codex
        self.cursorLocalSession = localSessions.cursor
        lastUpdate = Date()
        loading = false
        snapshots = Self.makeSnapshots(
            official: official,
            officialState: officialState,
            block: block,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: localSessions.openAI,
            codexLocalSession: localSessions.codex,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: localSessions.cursor,
            loading: loading,
            updatedAt: lastUpdate
        )
    }

    func setPrimaryProvider(_ provider: AIProviderKind) {
        primaryProvider = provider
        defaults.set(provider.rawValue, forKey: Self.primaryProviderDefaultsKey)
    }

    var primarySnapshot: ProviderSnapshot {
        snapshot(for: primaryProvider)
        ?? snapshots.first
        ?? Self.placeholderSnapshots(
            updatedAt: lastUpdate,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: openAILocalSession,
            codexLocalSession: codexLocalSession,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: cursorLocalSession
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
        settingsMessage = ok ? "\(kind.displayName) 저장됨" : "\(kind.displayName) 저장 실패"
    }

    func deleteSecret(_ kind: ProviderSecretKind) {
        let ok = SecretStore.delete(kind)
        refreshSecretStatus()
        settingsMessage = ok ? "\(kind.displayName) 삭제됨" : "\(kind.displayName) 삭제할 항목 없음"
    }

    func refreshSecretStatus() {
        hasOpenAIAdminKey = SecretStore.exists(.openAIAdminKey)
        hasCursorTeamKey = SecretStore.exists(.cursorTeamKey)
        hasAnthropicAdminKey = SecretStore.exists(.anthropicAdminKey)
        refreshLocalSessions()
    }

    func refreshLocalSessions() {
        let localSessions = LocalSessionDetector.detectAll(
            hasOpenAIAdminKey: hasOpenAIAdminKey,
            hasCursorTeamKey: hasCursorTeamKey,
            hasAnthropicAdminKey: hasAnthropicAdminKey
        )
        claudeLocalSession = localSessions.claude
        openAILocalSession = localSessions.openAI
        codexLocalSession = localSessions.codex
        cursorLocalSession = localSessions.cursor
        rebuildSnapshots()
    }

    // 메뉴바 타이틀: "🔥 58% · 2h41m"
    var menuBarTitle: String {
        if primaryProvider != .claude {
            return snapshot(for: primaryProvider)?.menuBarTitle ?? primaryProvider.menuName
        }
        return claudeMenuBarTitle
    }

    private var claudeMenuBarTitle: String {
        switch officialState {
        case .noToken: return "🔒 로그인"
        case .rateLimited where official?.fiveHour == nil: return "⏳"  // 일시적 호출 제한
        default: break
        }
        guard let fh = official?.fiveHour else {
            return officialState.isError ? "⚠︎" : "…"  // .loading → "…"
        }
        let pct = Int(fh.utilization.rounded())
        let countdown = compactRemaining(until: parseDate(fh.resetsAt))
        return "🔥 \(pct)% · \(countdown)"
    }
}

private extension UsageStore {
    func rebuildSnapshots() {
        snapshots = Self.makeSnapshots(
            official: official,
            officialState: officialState,
            block: block,
            openAIConfigured: hasOpenAIAdminKey,
            openAILocalSession: openAILocalSession,
            codexLocalSession: codexLocalSession,
            cursorConfigured: hasCursorTeamKey,
            cursorLocalSession: cursorLocalSession,
            loading: loading,
            updatedAt: lastUpdate
        )
    }

    static func placeholderSnapshots(
        updatedAt: Date?,
        openAIConfigured: Bool,
        openAILocalSession: OpenAILocalSession,
        codexLocalSession: CodexLocalSession,
        cursorConfigured: Bool,
        cursorLocalSession: CursorLocalSession
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
            openAISnapshot(updatedAt: updatedAt, configured: openAIConfigured, localSession: openAILocalSession),
            codexSnapshot(localSession: codexLocalSession, updatedAt: updatedAt),
            cursorSnapshot(updatedAt: updatedAt, configured: cursorConfigured, localSession: cursorLocalSession)
        ]
    }

    static func makeSnapshots(
        official: OfficialUsage?,
        officialState: OfficialResult,
        block: Block?,
        openAIConfigured: Bool,
        openAILocalSession: OpenAILocalSession,
        codexLocalSession: CodexLocalSession,
        cursorConfigured: Bool,
        cursorLocalSession: CursorLocalSession,
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
            openAISnapshot(updatedAt: updatedAt, configured: openAIConfigured, localSession: openAILocalSession),
            codexSnapshot(localSession: codexLocalSession, updatedAt: updatedAt),
            cursorSnapshot(updatedAt: updatedAt, configured: cursorConfigured, localSession: cursorLocalSession)
        ]
    }

    static func claudeSnapshot(
        official: OfficialUsage?,
        officialState: OfficialResult,
        block: Block?,
        loading: Bool,
        updatedAt: Date
    ) -> ProviderSnapshot {
        let reset = parseDate(official?.fiveHour?.resetsAt)
        let primary: UsageMetric
        if let fiveHour = official?.fiveHour {
            primary = .percent(fiveHour.utilization)
        } else {
            primary = .status(claudeStatusText(for: officialState, loading: loading))
        }

        let state = claudeProviderState(official: official, officialState: officialState, loading: loading)
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
            stateMessage: claudeStateMessage(for: officialState, hasOfficial: official != nil, loading: loading),
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

    static func claudeProviderState(
        official: OfficialUsage?,
        officialState: OfficialResult,
        loading: Bool
    ) -> ProviderState {
        if loading { return .loading }
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

    static func openAISnapshot(updatedAt: Date?, configured: Bool, localSession: OpenAILocalSession) -> ProviderSnapshot {
        if configured {
            return ProviderSnapshot(
                provider: .openAI,
                title: AIProviderKind.openAI.displayName,
                sourceKind: .officialAdmin,
                confidence: .configured,
                state: .configured,
                stateMessage: "OpenAI Admin API key가 Keychain에 저장되어 있습니다. Usage/Cost API 수집기를 연결하면 공식 API 사용량을 표시합니다.",
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

    static func codexSnapshot(localSession: CodexLocalSession, updatedAt: Date?) -> ProviderSnapshot {
        switch localSession.state {
        case .loggedIn:
            return ProviderSnapshot(
                provider: .codex,
                title: AIProviderKind.codex.displayName,
                sourceKind: .localSession,
                confidence: .localDetected,
                state: .ready,
                stateMessage: "로컬 Codex 로그인을 감지했습니다. 다만 공개 공식 API로 개인 Codex/ChatGPT 사용량 quota를 안정적으로 읽는 방법은 확인되지 않아 OpenAI API 사용량과 분리합니다.",
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

    static func cursorSnapshot(updatedAt: Date?, configured: Bool, localSession: CursorLocalSession) -> ProviderSnapshot {
        if configured {
            return ProviderSnapshot(
                provider: .cursor,
                title: AIProviderKind.cursor.displayName,
                sourceKind: .officialAdmin,
                confidence: .configured,
                state: .configured,
                stateMessage: "Cursor Team API key가 Keychain에 저장되어 있습니다. Admin/Analytics 수집기를 연결하면 팀 사용량을 표시합니다.",
                period: .month,
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
        if localSession.state == .loggedOut {
            return ProviderSnapshot(
                provider: .cursor,
                title: AIProviderKind.cursor.displayName,
                sourceKind: .localSession,
                confidence: .localDetected,
                state: .setupRequired,
                stateMessage: "Cursor 로컬 설치 또는 데이터는 감지했습니다. 공식 사용량 수집은 Team API key가 필요합니다.",
                period: .month,
                primary: .status("Team key 필요"),
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
            message: "Cursor 팀 API key가 있으면 공식 Admin/Analytics API로 request, token, 비용을 집계할 수 있습니다.",
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
