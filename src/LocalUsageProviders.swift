import Foundation

struct LocalUsageSummary: Equatable {
    let sourceKind: UsageSourceKind
    let confidence: UsageConfidence
    let period: UsagePeriod
    let primary: UsageMetric
    let primaryResetAt: Date?
    let secondaryPeriod: UsagePeriod?
    let secondary: UsageMetric?
    let secondaryResetAt: Date?
    let costUSD: Double?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningTokens: Int?
    let requestCount: Int?
    let modelSummary: String?
    let stateMessage: String
    let updatedAt: Date?
}

private struct SQLiteAggregateRow: Decodable {
    let threads: Int?
    let composers: Int?
    let messages: Int?
    let tokens: Int?
    let bytes: Int?
    let lastUpdated: Int64?
}

enum CodexUsageProvider {
    static func today() -> LocalUsageSummary? {
        let home = codexHome()
        let sessions = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return nil
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        var todayUsage = CodexTokenUsageAccumulator()
        var latestQuota: CodexQuotaSnapshot?
        var latestContextWindow: Int?
        var latestEventDate: Date?

        for url in sessionFiles(in: sessions) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: \.isNewline) where line.contains("\"token_count\"") {
                guard let data = String(line).data(using: .utf8),
                      let event = try? JSONDecoder().decode(CodexSessionEvent.self, from: data),
                      event.payload?.type == "token_count"
                else { continue }

                let eventDate = parseDate(event.timestamp) ?? fileModificationDate(url)
                if let eventDate, latestEventDate == nil || eventDate > latestEventDate! {
                    latestEventDate = eventDate
                }
                if let quota = event.payload?.rateLimits?.snapshot(eventDate: eventDate),
                   latestQuota == nil || quota.updatedAt > latestQuota!.updatedAt {
                    latestQuota = quota
                }
                if let contextWindow = event.payload?.info?.modelContextWindow {
                    latestContextWindow = contextWindow
                }
                if let eventDate, eventDate >= startOfToday, let usage = event.payload?.info?.lastTokenUsage {
                    todayUsage.add(usage)
                }
            }
        }

        guard latestQuota != nil || todayUsage.eventCount > 0 else { return nil }

        let primaryMetric: UsageMetric
        let period: UsagePeriod
        let resetAt: Date?
        if let primary = latestQuota?.primary {
            primaryMetric = .percent(primary.usedPercent)
            period = usagePeriod(for: primary.windowMinutes)
            resetAt = primary.resetsAt
        } else {
            primaryMetric = .tokens(todayUsage.totalTokens)
            period = .today
            resetAt = nil
        }

        let secondary = latestQuota?.secondary
        let modelSummary = codexModelSummary(home: home, since: startOfToday) ?? contextSummary(planType: latestQuota?.planType, contextWindow: latestContextWindow)
        return LocalUsageSummary(
            sourceKind: .localSession,
            confidence: .localDetected,
            period: period,
            primary: primaryMetric,
            primaryResetAt: resetAt,
            secondaryPeriod: secondary.map { usagePeriod(for: $0.windowMinutes) },
            secondary: secondary.map { .percent($0.usedPercent) },
            secondaryResetAt: secondary?.resetsAt,
            costUSD: nil,
            totalTokens: todayUsage.totalTokens,
            inputTokens: todayUsage.inputTokens,
            outputTokens: todayUsage.outputTokens,
            cachedInputTokens: todayUsage.cachedInputTokens,
            reasoningTokens: todayUsage.reasoningTokens,
            requestCount: todayUsage.eventCount,
            modelSummary: modelSummary,
            stateMessage: "Codex 로컬 session JSONL의 token_count.rate_limits 기준입니다. Codex TUI /status, /usage가 표시하는 한도 스냅샷과 같은 로컬 로그 이벤트를 읽습니다.",
            updatedAt: latestQuota?.updatedAt ?? latestEventDate
        )
    }

    private static func codexModelSummary(home: URL, since startOfToday: Date) -> String? {
        let dbPath = home.appendingPathComponent("state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        let startMs = Int64(startOfToday.timeIntervalSince1970 * 1000)
        let query = """
        select coalesce(model, source, 'unknown') as model, count(*) as threads, coalesce(sum(tokens_used),0) as tokens
        from threads
        where model_provider='openai'
          and updated_at_ms >= \(startMs)
        group by coalesce(model, source, 'unknown')
        order by tokens desc
        limit 2;
        """
        struct Row: Decodable {
            let model: String?
        }
        let labels = SQLiteJSON.run(dbPath: dbPath, query: query, as: [Row].self)?
            .compactMap { $0.model?.isEmpty == false ? $0.model : nil }
        guard let labels, !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    private static func contextSummary(planType: String?, contextWindow: Int?) -> String? {
        var parts: [String] = []
        if let planType, !planType.isEmpty {
            parts.append(planType)
        }
        if let contextWindow {
            parts.append("ctx \(formatNum(contextWindow))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func codexHome() -> URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    private static func sessionFiles(in sessions: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func usagePeriod(for minutes: Int?) -> UsagePeriod {
        guard let minutes else { return .none }
        if minutes <= 360 { return .fiveHour }
        if minutes >= 10_000 - 60 && minutes <= 10_080 + 60 { return .sevenDay }
        return .none
    }
}

enum CursorUsageProvider {
    static func today() -> LocalUsageSummary? {
        let dbPath = "\(NSHomeDirectory())/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let startMs = startOfTodayMilliseconds()
        let timestamp = "coalesce(json_extract(cast(value as text),'$.lastUpdatedAt'), json_extract(cast(value as text),'$.createdAt'))"
        let query = """
        select
          count(*) as composers,
          coalesce(sum(coalesce(json_array_length(json_extract(cast(value as text),'$.fullConversationHeadersOnly')),0)),0) as messages,
          coalesce(sum(length(value)),0) as bytes,
          max(\(timestamp)) as lastUpdated
        from cursorDiskKV
        where key like 'composerData:%'
          and json_valid(cast(value as text))=1
          and \(timestamp) >= \(startMs);
        """
        guard let row = SQLiteJSON.run(dbPath: dbPath, query: query, as: [SQLiteAggregateRow].self)?.first else {
            return nil
        }

        let composers = row.composers ?? 0
        let messages = row.messages ?? 0
        let bytes = row.bytes ?? 0
        let lastUpdated = row.lastUpdated.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        guard composers > 0 || messages > 0 else {
            return nil
        }
        return LocalUsageSummary(
            sourceKind: .localEstimate,
            confidence: .estimated,
            period: .today,
            primary: .requests(messages > 0 ? messages : composers),
            primaryResetAt: nil,
            secondaryPeriod: nil,
            secondary: nil,
            secondaryResetAt: nil,
            costUSD: nil,
            totalTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            cachedInputTokens: nil,
            reasoningTokens: nil,
            requestCount: messages > 0 ? messages : composers,
            modelSummary: bytes > 0 ? "\(formatNum(bytes)) local bytes" : nil,
            stateMessage: "Cursor 로컬 composer DB 기준 오늘 갱신된 대화 header 수입니다. 공식 Team Analytics가 아니므로 token/cost는 Team API 연결 전까지 표시하지 않습니다.",
            updatedAt: lastUpdated
        )
    }
}

enum SQLiteJSON {
    static func run<T: Decodable>(dbPath: String, query: String, as type: T.Type) -> T? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", "-json", "-cmd", ".timeout 1000", dbPath, query]
        task.standardError = Pipe()
        let outPipe = Pipe()
        task.standardOutput = outPipe
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}

private func startOfTodayMilliseconds(now: Date = Date()) -> Int64 {
    let start = Calendar.current.startOfDay(for: now)
    return Int64(start.timeIntervalSince1970 * 1000)
}

private struct CodexSessionEvent: Decodable {
    let timestamp: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case info
        case rateLimits = "rate_limits"
    }
}

private struct CodexTokenInfo: Decodable {
    let lastTokenUsage: CodexTokenUsage?
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct CodexTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct CodexTokenUsageAccumulator {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var eventCount = 0

    mutating func add(_ usage: CodexTokenUsage) {
        inputTokens += usage.inputTokens ?? 0
        cachedInputTokens += usage.cachedInputTokens ?? 0
        outputTokens += usage.outputTokens ?? 0
        reasoningTokens += usage.reasoningOutputTokens ?? 0
        totalTokens += usage.totalTokens ?? ((usage.inputTokens ?? 0) + (usage.outputTokens ?? 0))
        eventCount += 1
    }
}

private struct CodexRateLimits: Decodable {
    let primary: CodexLimitWindow?
    let secondary: CodexLimitWindow?
    let planType: String?
    let primaryUsedPercent: Double?
    let secondaryUsedPercent: Double?
    let primaryWindowMinutes: Int?
    let secondaryWindowMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case primaryWindowMinutes = "primary_window_minutes"
        case secondaryWindowMinutes = "secondary_window_minutes"
    }

    func snapshot(eventDate: Date?) -> CodexQuotaSnapshot? {
        let primaryWindow = primary ?? CodexLimitWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: primaryWindowMinutes,
            resetsAtEpochSeconds: nil
        )
        let secondaryWindow = secondary ?? CodexLimitWindow(
            usedPercent: secondaryUsedPercent,
            windowMinutes: secondaryWindowMinutes,
            resetsAtEpochSeconds: nil
        )
        guard primaryWindow.usedPercent != nil || secondaryWindow.usedPercent != nil else {
            return nil
        }
        return CodexQuotaSnapshot(
            primary: primaryWindow.normalized,
            secondary: secondaryWindow.normalized,
            planType: planType,
            updatedAt: eventDate ?? Date.distantPast
        )
    }
}

private struct CodexLimitWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAtEpochSeconds: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAtEpochSeconds = "resets_at"
    }

    var normalized: CodexQuotaWindow? {
        guard let usedPercent else { return nil }
        return CodexQuotaWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAtEpochSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct CodexQuotaSnapshot {
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?
    let planType: String?
    let updatedAt: Date
}

private struct CodexQuotaWindow {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
}
