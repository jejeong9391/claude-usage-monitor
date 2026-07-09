import Foundation

enum ProviderSecretKind: String, CaseIterable, Identifiable {
    case openAIAdminKey
    case geminiAPIKey
    case cursorTeamKey
    case anthropicAdminKey

    var id: String { rawValue }

    var serviceName: String {
        switch self {
        case .openAIAdminKey:
            return "ClaudeUsageMonitor.OpenAI.AdminKey"
        case .geminiAPIKey:
            return "ClaudeUsageMonitor.Gemini.APIKey"
        case .cursorTeamKey:
            return "ClaudeUsageMonitor.Cursor.TeamKey"
        case .anthropicAdminKey:
            return "ClaudeUsageMonitor.Anthropic.AdminKey"
        }
    }

    var accountName: String { "default" }

    var displayName: String {
        switch self {
        case .openAIAdminKey: return "OpenAI Admin API key"
        case .geminiAPIKey: return "Gemini API key"
        case .cursorTeamKey: return "Cursor Team API key"
        case .anthropicAdminKey: return "Anthropic Admin API key"
        }
    }

    var provider: AIProviderKind {
        switch self {
        case .openAIAdminKey: return .openAI
        case .geminiAPIKey: return .gemini
        case .cursorTeamKey: return .cursor
        case .anthropicAdminKey: return .claude
        }
    }
}

enum SecretStore {
    private static func runSecurity(_ args: [String], timeout: TimeInterval = 5) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            return false
        }
        return task.terminationStatus == 0
    }

    static func exists(_ kind: ProviderSecretKind) -> Bool {
        runSecurity([
            "find-generic-password",
            "-s", kind.serviceName,
            "-a", kind.accountName
        ], timeout: 3)
    }

    static func read(_ kind: ProviderSecretKind) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "find-generic-password",
            "-s", kind.serviceName,
            "-a", kind.accountName,
            "-w"
        ]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func save(_ kind: ProviderSecretKind, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return runSecurity([
            "add-generic-password",
            "-s", kind.serviceName,
            "-a", kind.accountName,
            "-w", trimmed,
            "-U"
        ])
    }

    static func delete(_ kind: ProviderSecretKind) -> Bool {
        runSecurity([
            "delete-generic-password",
            "-s", kind.serviceName,
            "-a", kind.accountName
        ])
    }
}

enum LocalSessionState: Equatable {
    case loggedIn
    case loggedOut
    case unavailable

    var label: String {
        switch self {
        case .loggedIn: return "로그인됨"
        case .loggedOut: return "로그인 필요"
        case .unavailable: return "감지 불가"
        }
    }
}

struct LocalProviderSession: Equatable {
    let state: LocalSessionState
    let authMode: String?
    let accountID: String?
    let credentialLocation: String?
    let lastRefresh: Date?
    let executablePath: String?
    let statusText: String?

    var isLoggedIn: Bool { state == .loggedIn }

    var authModeLabel: String {
        guard let authMode, !authMode.isEmpty else { return "감지 불가" }
        switch authMode.lowercased() {
        case "chatgpt":
            return "ChatGPT"
        case "api", "api_key", "apikey":
            return "API key"
        default:
            return authMode
        }
    }

    var accountLabel: String {
        guard let accountID, !accountID.isEmpty else { return "계정 ID 미공개" }
        return accountID
    }

    var credentialLocationLabel: String {
        credentialLocation ?? "감지 불가"
    }

    static let unknown = LocalProviderSession(
        state: .unavailable,
        authMode: nil,
        accountID: nil,
        credentialLocation: nil,
        lastRefresh: nil,
        executablePath: nil,
        statusText: nil
    )
}

typealias ClaudeLocalSession = LocalProviderSession
typealias OpenAILocalSession = LocalProviderSession
typealias GeminiLocalSession = LocalProviderSession
typealias CodexLocalSession = LocalProviderSession
typealias CursorLocalSession = LocalProviderSession

struct LocalSessionSnapshot: Equatable {
    let claude: ClaudeLocalSession
    let openAI: OpenAILocalSession
    let gemini: GeminiLocalSession
    let codex: CodexLocalSession
    let cursor: CursorLocalSession
}

enum LocalSessionDetector {
    static func detectAll(
        hasOpenAIAdminKey: Bool,
        hasGeminiAPIKey: Bool,
        hasCursorTeamKey: Bool,
        hasAnthropicAdminKey: Bool
    ) -> LocalSessionSnapshot {
        LocalSessionSnapshot(
            claude: ClaudeLocalSessionDetector.detect(hasAnthropicAdminKey: hasAnthropicAdminKey),
            openAI: OpenAILocalSessionDetector.detect(hasAdminKey: hasOpenAIAdminKey),
            gemini: GeminiLocalSessionDetector.detect(hasAPIKey: hasGeminiAPIKey),
            codex: CodexLocalSessionDetector.detect(),
            cursor: CursorLocalSessionDetector.detect(hasTeamKey: hasCursorTeamKey)
        )
    }
}

enum ClaudeLocalSessionDetector {
    static func detect(hasAnthropicAdminKey: Bool) -> ClaudeLocalSession {
        if let oauth = detectKeychainOAuth() {
            return oauth
        }
        if hasAnthropicAdminKey {
            return ClaudeLocalSession(
                state: .loggedIn,
                authMode: "Admin API key",
                accountID: nil,
                credentialLocation: "ClaudeUsageMonitor Keychain",
                lastRefresh: nil,
                executablePath: findClaudeExecutable(),
                statusText: "앱에 저장된 Anthropic Admin key를 감지했습니다."
            )
        }
        return ClaudeLocalSession(
            state: .loggedOut,
            authMode: nil,
            accountID: nil,
            credentialLocation: findClaudeExecutable() == nil ? nil : "Claude Code Keychain",
            lastRefresh: nil,
            executablePath: findClaudeExecutable(),
            statusText: "Claude Code 로컬 OAuth 자격증명을 찾지 못했습니다."
        )
    }

    private static func detectKeychainOAuth() -> ClaudeLocalSession? {
        guard let data = runSecurity([
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w"
        ], timeout: 5) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            return nil
        }

        let accountID = firstString(in: oauth, keys: ["accountId", "accountID", "userId", "userID", "email"])
            ?? firstString(in: object, keys: ["accountId", "accountID", "userId", "userID", "email"])
        let lastRefresh = parseDate(firstString(in: oauth, keys: ["expiresAt", "expires_at", "updatedAt", "updated_at"]))
        return ClaudeLocalSession(
            state: .loggedIn,
            authMode: "Claude Code OAuth",
            accountID: accountID,
            credentialLocation: "macOS Keychain",
            lastRefresh: lastRefresh,
            executablePath: findClaudeExecutable(),
            statusText: "Claude Code Keychain OAuth 자격증명을 감지했습니다."
        )
    }

    private static func findClaudeExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum OpenAILocalSessionDetector {
    static func detect(hasAdminKey: Bool) -> OpenAILocalSession {
        if hasAdminKey {
            return OpenAILocalSession(
                state: .loggedIn,
                authMode: "Admin API key",
                accountID: nil,
                credentialLocation: "ClaudeUsageMonitor Keychain",
                lastRefresh: nil,
                executablePath: nil,
                statusText: "앱에 저장된 OpenAI Admin key를 감지했습니다."
            )
        }

        if environmentHasValue("OPENAI_ADMIN_KEY") {
            return OpenAILocalSession(
                state: .loggedIn,
                authMode: "Admin API key",
                accountID: nil,
                credentialLocation: "OPENAI_ADMIN_KEY",
                lastRefresh: nil,
                executablePath: nil,
                statusText: "프로세스 환경변수에서 OpenAI Admin key를 감지했습니다."
            )
        }

        if environmentHasValue("OPENAI_API_KEY") {
            return OpenAILocalSession(
                state: .loggedIn,
                authMode: "API key",
                accountID: nil,
                credentialLocation: "OPENAI_API_KEY",
                lastRefresh: nil,
                executablePath: nil,
                statusText: "프로세스 환경변수에서 OpenAI API key를 감지했습니다. 조직 Usage/Cost 집계는 Admin key 권한이 필요할 수 있습니다."
            )
        }

        return OpenAILocalSession(
            state: .loggedOut,
            authMode: nil,
            accountID: nil,
            credentialLocation: nil,
            lastRefresh: nil,
            executablePath: nil,
            statusText: "OpenAI API용 로컬 자격증명을 찾지 못했습니다."
        )
    }
}

enum GeminiLocalSessionDetector {
    private static var geminiHome: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini")
    }

    static func detect(hasAPIKey: Bool) -> GeminiLocalSession {
        let executable = findGeminiExecutable()
        if let oauthSession = detectOAuthSession(executablePath: executable) {
            return oauthSession
        }

        if hasAPIKey {
            return GeminiLocalSession(
                state: .loggedIn,
                authMode: "API key",
                accountID: nil,
                credentialLocation: "ClaudeUsageMonitor Keychain",
                lastRefresh: nil,
                executablePath: executable,
                statusText: "앱에 저장된 Gemini API key를 감지했습니다. CLI OAuth가 없을 때의 보조 자격증명입니다."
            )
        }

        if environmentHasValue("GEMINI_API_KEY") {
            return GeminiLocalSession(
                state: .loggedIn,
                authMode: "API key",
                accountID: nil,
                credentialLocation: "GEMINI_API_KEY",
                lastRefresh: nil,
                executablePath: executable,
                statusText: "프로세스 환경변수에서 Gemini API key를 감지했습니다. CLI OAuth가 없을 때의 보조 자격증명입니다."
            )
        }

        if environmentHasValue("GOOGLE_API_KEY") {
            return GeminiLocalSession(
                state: .loggedIn,
                authMode: "API key",
                accountID: nil,
                credentialLocation: "GOOGLE_API_KEY",
                lastRefresh: nil,
                executablePath: executable,
                statusText: "프로세스 환경변수에서 Google API key를 감지했습니다. CLI OAuth가 없을 때의 보조 자격증명입니다."
            )
        }

        if let executable {
            return GeminiLocalSession(
                state: .loggedOut,
                authMode: "Google OAuth",
                accountID: nil,
                credentialLocation: "~/.gemini/oauth_creds.json",
                lastRefresh: nil,
                executablePath: executable,
                statusText: "Gemini CLI는 감지했지만 Google OAuth 자격증명은 아직 찾지 못했습니다."
            )
        }

        return GeminiLocalSession(
            state: .unavailable,
            authMode: nil,
            accountID: nil,
            credentialLocation: nil,
            lastRefresh: nil,
            executablePath: nil,
            statusText: "Gemini CLI 또는 로컬 자격증명을 찾지 못했습니다."
        )
    }

    private static func detectOAuthSession(executablePath: String?) -> GeminiLocalSession? {
        let authURL = geminiHome.appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let hasOAuthToken = ["refresh_token", "access_token", "id_token"].contains { key in
            guard let value = object[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let accountID = detectActiveGoogleAccount()
        let lastRefresh = fileModificationDate(authURL)
        guard hasOAuthToken else {
            return GeminiLocalSession(
                state: .loggedOut,
                authMode: "Google OAuth",
                accountID: accountID,
                credentialLocation: "~/.gemini/oauth_creds.json",
                lastRefresh: lastRefresh,
                executablePath: executablePath,
                statusText: "Gemini OAuth 파일은 있지만 유효한 토큰을 찾지 못했습니다."
            )
        }

        return GeminiLocalSession(
            state: .loggedIn,
            authMode: "Google OAuth",
            accountID: accountID,
            credentialLocation: "~/.gemini/oauth_creds.json",
            lastRefresh: lastRefresh,
            executablePath: executablePath,
            statusText: "Gemini CLI Google OAuth 자격증명을 감지했습니다."
        )
    }

    private static func detectActiveGoogleAccount() -> String? {
        let accountsURL = geminiHome.appendingPathComponent("google_accounts.json")
        guard let data = try? Data(contentsOf: accountsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let active = object["active"] as? String, !active.isEmpty {
            return active
        }
        if let active = object["active"] as? [String: Any] {
            return firstString(in: active, keys: ["email", "account", "id", "name"])
        }
        return firstString(in: object, keys: ["email", "account", "accountID", "userID"])
    }

    private static func findGeminiExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum CodexLocalSessionDetector {
    private static var codexHome: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    static func detect() -> CodexLocalSession {
        let executable = findCodexExecutable()
        if let fileSession = detectFileSession(executablePath: executable) {
            return fileSession
        }
        if let cliSession = detectCLIStatus(executablePath: executable) {
            return cliSession
        }
        guard executable != nil else {
            return CodexLocalSession(
                state: .unavailable,
                authMode: nil,
                accountID: nil,
                credentialLocation: nil,
                lastRefresh: nil,
                executablePath: nil,
                statusText: "Codex CLI를 찾지 못했습니다."
            )
        }
        return CodexLocalSession(
            state: .loggedOut,
            authMode: nil,
            accountID: nil,
            credentialLocation: "Codex CLI",
            lastRefresh: nil,
            executablePath: executable,
            statusText: "Codex CLI 로그인 상태를 찾지 못했습니다."
        )
    }

    private static func detectFileSession(executablePath: String?) -> CodexLocalSession? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let authMode = object["auth_mode"] as? String
        let tokens = object["tokens"] as? [String: Any]
        let accountID = tokens?["account_id"] as? String
        let hasChatGPTToken = [
            tokens?["access_token"],
            tokens?["refresh_token"],
            tokens?["id_token"]
        ].contains { value in
            guard let value = value as? String else { return false }
            return !value.isEmpty
        }
        let hasAPIKey = containsAPIKey(in: object)
        let lastRefresh = parseDate(object["last_refresh"] as? String)

        guard hasChatGPTToken || hasAPIKey else {
            return CodexLocalSession(
                state: .loggedOut,
                authMode: authMode,
                accountID: accountID,
                credentialLocation: "~/.codex/auth.json",
                lastRefresh: lastRefresh,
                executablePath: executablePath,
                statusText: "auth.json은 있지만 유효한 로그인 정보를 찾지 못했습니다."
            )
        }

        return CodexLocalSession(
            state: .loggedIn,
            authMode: authMode ?? (hasAPIKey ? "api" : nil),
            accountID: accountID,
            credentialLocation: "~/.codex/auth.json",
            lastRefresh: lastRefresh,
            executablePath: executablePath,
            statusText: "로컬 Codex auth.json에서 로그인 상태를 감지했습니다."
        )
    }

    private static func detectCLIStatus(executablePath: String?) -> CodexLocalSession? {
        guard let executablePath else { return nil }
        let result = runCodex(executablePath: executablePath, arguments: ["login", "status"], timeout: 4)
        guard let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return nil
        }

        let normalized = output.lowercased()
        if normalized.contains("logged in") {
            let authMode: String?
            if normalized.contains("chatgpt") {
                authMode = "chatgpt"
            } else if normalized.contains("api") {
                authMode = "api"
            } else {
                authMode = nil
            }
            return CodexLocalSession(
                state: .loggedIn,
                authMode: authMode,
                accountID: nil,
                credentialLocation: "Codex credential store",
                lastRefresh: nil,
                executablePath: executablePath,
                statusText: output
            )
        }

        if normalized.contains("not logged in") || normalized.contains("log in") {
            return CodexLocalSession(
                state: .loggedOut,
                authMode: nil,
                accountID: nil,
                credentialLocation: "Codex credential store",
                lastRefresh: nil,
                executablePath: executablePath,
                statusText: output
            )
        }

        return nil
    }

    private static func findCodexExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runCodex(executablePath: String, arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, nil)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            return (-1, nil)
        }

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        let error = String(data: errorData, encoding: .utf8)
        let combined = [output, error]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
            .joined(separator: "\n")
        return (task.terminationStatus, combined.isEmpty ? nil : combined)
    }

    private static func containsAPIKey(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let lowered = key.lowercased()
                if lowered.contains("api") && lowered.contains("key"),
                   let string = nested as? String,
                   !string.isEmpty {
                    return true
                }
                if containsAPIKey(in: nested) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsAPIKey)
        }
        return false
    }
}

enum CursorLocalSessionDetector {
    static func detect(hasTeamKey: Bool) -> CursorLocalSession {
        let cliPath = findCursorCLIExecutable()
        let appPath = findCursorApp()
        let supportPath = cursorSupportPath()
        if hasTeamKey {
            return CursorLocalSession(
                state: .loggedIn,
                authMode: "Team API key",
                accountID: nil,
                credentialLocation: "ClaudeUsageMonitor Keychain",
                lastRefresh: nil,
                executablePath: cliPath ?? appPath,
                statusText: "앱에 저장된 Cursor Team API key를 감지했습니다. Cursor CLI 로그인과 별개의 팀 분석용 보조 자격증명입니다."
            )
        }

        if let cliPath {
            return CursorLocalSession(
                state: .loggedOut,
                authMode: "Cursor Agent CLI",
                accountID: nil,
                credentialLocation: "~/.cursor",
                lastRefresh: nil,
                executablePath: cliPath,
                statusText: "Cursor Agent CLI를 감지했습니다. 로그인은 설정 화면의 CLI 로그인 버튼으로 실행합니다."
            )
        }

        if supportPath != nil || appPath != nil {
            return CursorLocalSession(
                state: .loggedOut,
                authMode: "Cursor App",
                accountID: nil,
                credentialLocation: supportPath ?? appPath,
                lastRefresh: nil,
                executablePath: appPath,
                statusText: "Cursor 앱 또는 로컬 데이터는 감지했지만 Cursor Agent CLI는 찾지 못했습니다."
            )
        }

        return CursorLocalSession(
            state: .unavailable,
            authMode: nil,
            accountID: nil,
            credentialLocation: nil,
            lastRefresh: nil,
            executablePath: nil,
            statusText: "Cursor 앱 또는 로컬 설정을 찾지 못했습니다."
        )
    }

    private static func findCursorApp() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/Cursor.app",
            "\(home)/Applications/Cursor.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func cursorSupportPath() -> String? {
        let path = "\(NSHomeDirectory())/Library/Application Support/Cursor"
        return FileManager.default.fileExists(atPath: path) ? "~/Library/Application Support/Cursor" : nil
    }

    private static func findCursorCLIExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/agent",
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/agent",
            "/usr/local/bin/cursor-agent"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private func runSecurity(_ args: [String], timeout: TimeInterval) -> Data? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = args
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if task.isRunning {
        task.terminate()
        return nil
    }
    guard task.terminationStatus == 0 else { return nil }
    return outPipe.fileHandleForReading.readDataToEndOfFile()
}

private func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dictionary[key] as? String, !value.isEmpty {
            return value
        }
    }
    return nil
}

private func environmentHasValue(_ key: String) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[key] else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func fileModificationDate(_ url: URL) -> Date? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
    return values.contentModificationDate
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
