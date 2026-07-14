import Foundation

// MARK: - 공식 엔드포인트 모델 (api.anthropic.com/api/oauth/usage)
// utilization 은 0~100 퍼센트. resets_at 은 ISO8601 UTC.
// 응답 스키마가 비공개라 모든 필드를 Optional 로 두어 변경에 관대하게 디코드한다.

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

struct OfficialUsage: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

func fiveHourDisplayUtilization(_ window: UsageWindow?, now: Date = Date()) -> Double {
    guard let window else { return 0 }
    guard let reset = parseDate(window.resetsAt), reset <= now else {
        return window.utilization
    }
    return 0
}

func fiveHourSessionStarted(_ window: UsageWindow?, now: Date = Date()) -> Bool {
    guard let window else { return false }
    guard window.utilization > 0 else { return false }
    guard let reset = parseDate(window.resetsAt) else { return true }
    return reset > now
}

func fiveHourDisplayReset(_ window: UsageWindow?, now: Date = Date()) -> Date? {
    guard fiveHourSessionStarted(window, now: now),
          let reset = parseDate(window?.resetsAt),
          reset > now
    else {
        return nil
    }
    return reset
}

func fiveHourWindowExpired(_ window: UsageWindow?, now: Date = Date()) -> Bool {
    guard let window, window.utilization > 0, let reset = parseDate(window.resetsAt) else { return false }
    return reset <= now
}

// MARK: - ccusage 모델 (비용·토큰·burn 상세 전용)

struct TokenCounts: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    var total: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }
}

struct BurnRate: Decodable {
    let costPerHour: Double?
    let tokensPerMinute: Double?
}

struct Projection: Decodable {
    let totalTokens: Int?
    let totalCost: Double?
    let remainingMinutes: Int?
}

struct Block: Decodable {
    let id: String
    let startTime: String
    let endTime: String
    let isActive: Bool
    let isGap: Bool?
    let entries: Int
    let tokenCounts: TokenCounts
    let totalTokens: Int
    let costUSD: Double
    let models: [String]
    let burnRate: BurnRate?
    let projection: Projection?
}

struct BlocksResponse: Decodable { let blocks: [Block] }

struct ModelBreakdown: Decodable {
    let modelName: String
    let cost: Double
}

struct DailyEntry: Decodable {
    let date: String?
    let totalCost: Double?
    let totalTokens: Int?
}

struct DailyResponse: Decodable { let daily: [DailyEntry] }

// MARK: - 공통 헬퍼

/// 분수초(.976658)와 타임존이 섞인 ISO8601 문자열을 안전하게 파싱한다.
/// 분수초 자릿수가 가변(밀리초~마이크로초)이라 먼저 제거 후 표준 파서로 처리.
func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let stripped = s.replacingOccurrences(
        of: #"\.\d+"#, with: "", options: .regularExpression
    )
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: stripped) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

func formatNum(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

/// 남은 시간을 메뉴바용으로 짧게: "2h41m" / "47m"
func compactRemaining(until date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "—" }
    let rem = max(0, date.timeIntervalSince(now))
    let h = Int(rem) / 3600
    let m = (Int(rem) % 3600) / 60
    return h > 0 ? "\(h)h\(m)m" : "\(m)m"
}

/// 드롭다운용 여유 있는 표기: "2시간 41분 후" / "1일 20시간 후"
func friendlyRemaining(until date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "—" }
    let rem = max(0, date.timeIntervalSince(now))
    let days = Int(rem) / 86400
    let h = (Int(rem) % 86400) / 3600
    let m = (Int(rem) % 3600) / 60
    if days > 0 { return "\(days)일 \(h)시간 후" }
    if h > 0 { return "\(h)시간 \(m)분 후" }
    return "\(m)분 후"
}

func formatResetClock(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.timeZone = TimeZone.current
    f.dateFormat = "M/d(E) HH:mm"
    return f.string(from: date)
}

func formatTimeOnly(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}
