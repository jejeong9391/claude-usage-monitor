import Foundation

enum OpenAIUsageProvider {
    static func today(organizationID: String?, projectID: String?) -> LocalUsageSummary? {
        guard let apiKey = openAIAdminKey() else { return nil }
        let range = UsageDateRange.today()
        let usage = fetchCompletionsUsage(apiKey: apiKey, organizationID: organizationID, projectID: projectID, range: range)
        let costUSD = fetchCosts(apiKey: apiKey, organizationID: organizationID, projectID: projectID, range: range)
        guard usage != nil || costUSD != nil else { return nil }

        let aggregate = usage ?? OpenAITokenAggregate()
        let primary: UsageMetric
        if let costUSD {
            primary = .costUSD(costUSD)
        } else if aggregate.requestCount > 0 {
            primary = .requests(aggregate.requestCount)
        } else {
            primary = .tokens(aggregate.totalTokens)
        }

        return LocalUsageSummary(
            sourceKind: .officialAdmin,
            confidence: .official,
            period: .today,
            primary: primary,
            primaryResetAt: range.resetAt,
            secondaryPeriod: nil,
            secondary: nil,
            secondaryResetAt: nil,
            costUSD: costUSD,
            totalTokens: aggregate.totalTokens,
            inputTokens: aggregate.inputTokens,
            outputTokens: aggregate.outputTokens,
            cachedInputTokens: aggregate.cachedInputTokens,
            reasoningTokens: nil,
            requestCount: aggregate.requestCount,
            modelSummary: aggregate.modelSummary,
            stateMessage: "OpenAI 공식 Organization Usage API와 Cost API 기준입니다. ChatGPT/Codex 구독 사용량이 아니라 OpenAI API 조직 사용량입니다.",
            updatedAt: Date()
        )
    }

    private static func openAIAdminKey() -> String? {
        SecretStore.read(.openAIAdminKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"]?.trimmedNilIfEmpty
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmedNilIfEmpty
    }

    private static func fetchCompletionsUsage(
        apiKey: String,
        organizationID: String?,
        projectID: String?,
        range: UsageDateRange
    ) -> OpenAITokenAggregate? {
        var aggregate = OpenAITokenAggregate()
        var page: String?
        var didSucceed = false

        for _ in 0..<4 {
            var items = [
                URLQueryItem(name: "start_time", value: "\(range.startUnixSeconds)"),
                URLQueryItem(name: "end_time", value: "\(range.endUnixSeconds)"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by[]", value: "model")
            ]
            if let projectID = projectID?.trimmedNilIfEmpty {
                items.append(URLQueryItem(name: "project_ids[]", value: projectID))
            }
            if let page {
                items.append(URLQueryItem(name: "page", value: page))
            }

            guard let url = HTTPJSON.url("https://api.openai.com/v1/organization/usage/completions", queryItems: items),
                  let data = HTTPJSON.get(url: url, headers: openAIHeaders(apiKey: apiKey, organizationID: organizationID)),
                  let response = try? JSONDecoder().decode(OpenAIUsagePage.self, from: data)
            else {
                break
            }

            didSucceed = true
            response.data.forEach { bucket in
                bucket.results.forEach { result in
                    aggregate.inputTokens += result.inputTokens ?? 0
                    aggregate.outputTokens += result.outputTokens ?? 0
                    aggregate.cachedInputTokens += result.inputCachedTokens ?? 0
                    aggregate.requestCount += result.numModelRequests ?? 0
                    if let model = result.model?.trimmedNilIfEmpty {
                        aggregate.models[model, default: 0] += result.numModelRequests ?? 0
                    }
                }
            }

            guard response.hasMore == true, let nextPage = response.nextPage?.trimmedNilIfEmpty else { break }
            page = nextPage
        }

        return didSucceed ? aggregate : nil
    }

    private static func fetchCosts(
        apiKey: String,
        organizationID: String?,
        projectID: String?,
        range: UsageDateRange
    ) -> Double? {
        var total = 0.0
        var page: String?
        var didSucceed = false

        for _ in 0..<4 {
            var items = [
                URLQueryItem(name: "start_time", value: "\(range.startUnixSeconds)"),
                URLQueryItem(name: "end_time", value: "\(range.endUnixSeconds)"),
                URLQueryItem(name: "bucket_width", value: "1d")
            ]
            if let projectID = projectID?.trimmedNilIfEmpty {
                items.append(URLQueryItem(name: "project_ids[]", value: projectID))
            }
            if let page {
                items.append(URLQueryItem(name: "page", value: page))
            }

            guard let url = HTTPJSON.url("https://api.openai.com/v1/organization/costs", queryItems: items),
                  let data = HTTPJSON.get(url: url, headers: openAIHeaders(apiKey: apiKey, organizationID: organizationID)),
                  let response = try? JSONDecoder().decode(OpenAICostPage.self, from: data)
            else {
                break
            }

            didSucceed = true
            response.data.forEach { bucket in
                bucket.results.forEach { result in
                    total += result.amount?.value ?? 0
                }
            }

            guard response.hasMore == true, let nextPage = response.nextPage?.trimmedNilIfEmpty else { break }
            page = nextPage
        }

        return didSucceed ? total : nil
    }

    private static func openAIHeaders(apiKey: String, organizationID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(apiKey)"
        ]
        if let organizationID = organizationID?.trimmedNilIfEmpty {
            headers["OpenAI-Organization"] = organizationID
        }
        return headers
    }
}

enum CursorTeamUsageProvider {
    static func today(teamID: String?) -> LocalUsageSummary? {
        guard let apiKey = SecretStore.read(.cursorTeamKey) else {
            return CursorUsageProvider.today()
        }

        let range = UsageDateRange.today()
        let daily = fetchDailyUsage(apiKey: apiKey, teamID: teamID, range: range)
        let events = fetchUsageEvents(apiKey: apiKey, teamID: teamID, range: range)
        guard daily != nil || events != nil else {
            return CursorUsageProvider.today()
        }

        let requestCount = daily?.requestCount ?? events?.eventCount
        let costUSD = events?.costUSD
        let primary: UsageMetric
        if let costUSD {
            primary = .costUSD(costUSD)
        } else if let requestCount {
            primary = .requests(requestCount)
        } else {
            primary = .tokens(events?.totalTokens ?? 0)
        }

        return LocalUsageSummary(
            sourceKind: .officialAdmin,
            confidence: .official,
            period: .today,
            primary: primary,
            primaryResetAt: range.resetAt,
            secondaryPeriod: nil,
            secondary: nil,
            secondaryResetAt: nil,
            costUSD: costUSD,
            totalTokens: events?.totalTokens,
            inputTokens: events?.inputTokens,
            outputTokens: events?.outputTokens,
            cachedInputTokens: events?.cachedTokens,
            reasoningTokens: nil,
            requestCount: requestCount,
            modelSummary: events?.modelSummary ?? daily?.modelSummary,
            stateMessage: "Cursor 공식 Team Analytics/Admin API 기준입니다. 팀 API key 권한으로 오늘 요청, 토큰, 비용을 집계합니다.",
            updatedAt: Date()
        )
    }

    private static func fetchDailyUsage(apiKey: String, teamID: String?, range: UsageDateRange) -> CursorDailyAggregate? {
        guard let data = HTTPJSON.post(
            urlString: "https://api.cursor.com/teams/daily-usage-data",
            headers: cursorHeaders(apiKey: apiKey),
            body: cursorBody(teamID: teamID, range: range)
        ),
        let response = try? JSONDecoder().decode(CursorDailyUsageResponse.self, from: data)
        else {
            return nil
        }

        var aggregate = CursorDailyAggregate()
        response.data.forEach { row in
            aggregate.requestCount += row.totalRequests
            if let model = row.mostUsedModel?.trimmedNilIfEmpty {
                aggregate.models[model, default: 0] += row.totalRequests
            }
        }
        return aggregate
    }

    private static func fetchUsageEvents(apiKey: String, teamID: String?, range: UsageDateRange) -> CursorEventAggregate? {
        guard let data = HTTPJSON.post(
            urlString: "https://api.cursor.com/teams/filtered-usage-events",
            headers: cursorHeaders(apiKey: apiKey),
            body: cursorBody(teamID: teamID, range: range).merging(["page": 1, "pageSize": 500]) { _, new in new }
        ),
        let response = try? JSONDecoder().decode(CursorUsageEventsResponse.self, from: data)
        else {
            return nil
        }

        var aggregate = CursorEventAggregate()
        response.events.forEach { event in
            aggregate.eventCount += 1
            aggregate.inputTokens += event.tokenUsage?.inputTokens ?? 0
            aggregate.outputTokens += event.tokenUsage?.outputTokens ?? 0
            aggregate.cachedTokens += (event.tokenUsage?.cacheReadTokens ?? 0) + (event.tokenUsage?.cacheWriteTokens ?? 0)
            aggregate.costCents += event.chargedCents ?? event.tokenUsage?.totalCents ?? event.cursorTokenFee ?? 0
            if let model = event.model?.trimmedNilIfEmpty {
                aggregate.models[model, default: 0] += 1
            }
        }
        return aggregate
    }

    private static func cursorHeaders(apiKey: String) -> [String: String] {
        let credential = Data("\(apiKey):".utf8).base64EncodedString()
        return ["Authorization": "Basic \(credential)"]
    }

    private static func cursorBody(teamID: String?, range: UsageDateRange) -> [String: Any] {
        var body: [String: Any] = [
            "startDate": range.startMilliseconds,
            "endDate": range.endMilliseconds
        ]
        if let teamID = teamID?.trimmedNilIfEmpty {
            body["teamId"] = teamID
        }
        return body
    }
}

private struct UsageDateRange {
    let start: Date
    let queryEnd: Date
    let resetAt: Date

    var startUnixSeconds: Int { Int(start.timeIntervalSince1970) }
    var endUnixSeconds: Int { Int(queryEnd.timeIntervalSince1970) }
    var startMilliseconds: Int64 { Int64(start.timeIntervalSince1970 * 1000) }
    var endMilliseconds: Int64 { Int64(queryEnd.timeIntervalSince1970 * 1000) }

    static func today(now: Date = Date()) -> UsageDateRange {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let resetAt = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return UsageDateRange(start: start, queryEnd: now, resetAt: resetAt)
    }
}

private enum HTTPJSON {
    static func url(_ string: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        components.queryItems = queryItems
        return components.url
    }

    static func get(url: URL, headers: [String: String]) -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return perform(request)
    }

    static func post(urlString: String, headers: [String: String], body: [String: Any]) -> Data? {
        guard let url = URL(string: urlString),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return perform(request)
    }

    private static func perform(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  let data
            else {
                return
            }
            result = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 18)
        return result
    }
}

private struct OpenAITokenAggregate {
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var requestCount = 0
    var models: [String: Int] = [:]

    var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens
    }

    var modelSummary: String? {
        topModels(models)
    }
}

private struct CursorDailyAggregate {
    var requestCount = 0
    var models: [String: Int] = [:]

    var modelSummary: String? {
        topModels(models)
    }
}

private struct CursorEventAggregate {
    var eventCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var costCents = 0.0
    var models: [String: Int] = [:]

    var totalTokens: Int {
        inputTokens + outputTokens + cachedTokens
    }

    var costUSD: Double {
        costCents / 100
    }

    var modelSummary: String? {
        topModels(models)
    }
}

private struct OpenAIUsagePage: Decodable {
    let data: [OpenAIUsageBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAIUsageBucket: Decodable {
    let results: [OpenAIUsageResult]
}

private struct OpenAIUsageResult: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let inputCachedTokens: Int?
    let numModelRequests: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case numModelRequests = "num_model_requests"
        case model
    }
}

private struct OpenAICostPage: Decodable {
    let data: [OpenAICostBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAICostBucket: Decodable {
    let results: [OpenAICostResult]
}

private struct OpenAICostResult: Decodable {
    let amount: OpenAICostAmount?
}

private struct OpenAICostAmount: Decodable {
    let value: Double?
}

private struct CursorDailyUsageResponse: Decodable {
    let data: [CursorDailyUsageRow]

    enum CodingKeys: String, CodingKey {
        case data
        case rows
        case dailyUsageData
        case usageData
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decode([CursorDailyUsageRow].self, forKey: .data))
            ?? (try? container.decode([CursorDailyUsageRow].self, forKey: .rows))
            ?? (try? container.decode([CursorDailyUsageRow].self, forKey: .dailyUsageData))
            ?? (try? container.decode([CursorDailyUsageRow].self, forKey: .usageData))
            ?? (try? container.decode([CursorDailyUsageRow].self, forKey: .items))
            ?? []
    }
}

private struct CursorDailyUsageRow: Decodable {
    let composerRequests: Int
    let chatRequests: Int
    let agentRequests: Int
    let cmdkUsages: Int
    let mostUsedModel: String?

    var totalRequests: Int {
        composerRequests + chatRequests + agentRequests + cmdkUsages
    }

    enum CodingKeys: String, CodingKey {
        case composerRequests
        case chatRequests
        case agentRequests
        case cmdkUsages
        case totalComposerRequests
        case totalChatRequests
        case totalAgentRequests
        case mostUsedModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        composerRequests = container.flexibleInt(.composerRequests) ?? container.flexibleInt(.totalComposerRequests) ?? 0
        chatRequests = container.flexibleInt(.chatRequests) ?? container.flexibleInt(.totalChatRequests) ?? 0
        agentRequests = container.flexibleInt(.agentRequests) ?? container.flexibleInt(.totalAgentRequests) ?? 0
        cmdkUsages = container.flexibleInt(.cmdkUsages) ?? 0
        mostUsedModel = container.flexibleString(.mostUsedModel)
    }
}

private struct CursorUsageEventsResponse: Decodable {
    let events: [CursorUsageEvent]

    enum CodingKeys: String, CodingKey {
        case usageEvents
        case events
        case data
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? container.decode([CursorUsageEvent].self, forKey: .usageEvents))
            ?? (try? container.decode([CursorUsageEvent].self, forKey: .events))
            ?? (try? container.decode([CursorUsageEvent].self, forKey: .data))
            ?? (try? container.decode([CursorUsageEvent].self, forKey: .items))
            ?? []
    }
}

private struct CursorUsageEvent: Decodable {
    let model: String?
    let chargedCents: Double?
    let cursorTokenFee: Double?
    let tokenUsage: CursorTokenUsage?

    enum CodingKeys: String, CodingKey {
        case model
        case chargedCents
        case cursorTokenFee
        case tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.flexibleString(.model)
        chargedCents = container.flexibleDouble(.chargedCents)
        cursorTokenFee = container.flexibleDouble(.cursorTokenFee)
        tokenUsage = try? container.decode(CursorTokenUsage.self, forKey: .tokenUsage)
    }
}

private struct CursorTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let totalCents: Double?

    enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheWriteTokens
        case cacheReadTokens
        case totalCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = container.flexibleInt(.inputTokens) ?? 0
        outputTokens = container.flexibleInt(.outputTokens) ?? 0
        cacheWriteTokens = container.flexibleInt(.cacheWriteTokens) ?? 0
        cacheReadTokens = container.flexibleInt(.cacheReadTokens) ?? 0
        totalCents = container.flexibleDouble(.totalCents)
    }
}

private func topModels(_ counts: [String: Int]) -> String? {
    let labels = counts
        .filter { !$0.key.isEmpty }
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        .prefix(2)
        .map(\.key)
    return labels.isEmpty ? nil : labels.joined(separator: ", ")
}

private extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexibleString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value.trimmedNilIfEmpty }
        if let value = try? decode(Int.self, forKey: key) { return "\(value)" }
        if let value = try? decode(Double.self, forKey: key) { return "\(value)" }
        return nil
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
