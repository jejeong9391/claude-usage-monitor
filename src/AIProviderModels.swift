import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case openAI
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI API"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var menuName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "flame.fill"
        case .openAI: return "sparkles"
        case .codex: return "terminal.fill"
        case .cursor: return "cursorarrow.click.2"
        }
    }
}

enum UsageSourceKind: Equatable {
    case officialPersonal
    case officialAdmin
    case localSession
    case localEstimate
    case setupRequired
    case unavailable

    var label: String {
        switch self {
        case .officialPersonal: return "Official"
        case .officialAdmin: return "Admin"
        case .localSession: return "Local Session"
        case .localEstimate: return "Local"
        case .setupRequired: return "Setup"
        case .unavailable: return "No Usage API"
        }
    }
}

enum UsageConfidence: Equatable {
    case official
    case estimated
    case stale
    case localDetected
    case configured
    case setupRequired
    case unavailable

    var label: String {
        switch self {
        case .official: return "공식"
        case .estimated: return "추정"
        case .stale: return "직전 값"
        case .localDetected: return "로컬 감지"
        case .configured: return "키 저장됨"
        case .setupRequired: return "연결 필요"
        case .unavailable: return "수집 미지원"
        }
    }
}

enum ProviderState: Equatable {
    case loading
    case ready
    case stale
    case configured
    case setupRequired
    case unauthorized
    case rateLimited
    case offline
    case unavailable

    var label: String {
        switch self {
        case .loading: return "로딩"
        case .ready: return "정상"
        case .stale: return "직전 값"
        case .configured: return "설정됨"
        case .setupRequired: return "연결 필요"
        case .unauthorized: return "재인증"
        case .rateLimited: return "제한"
        case .offline: return "오프라인"
        case .unavailable: return "수집 미지원"
        }
    }
}

enum UsagePeriod: Equatable {
    case fiveHour
    case sevenDay
    case today
    case month
    case none

    var label: String {
        switch self {
        case .fiveHour: return "5시간"
        case .sevenDay: return "7일"
        case .today: return "오늘"
        case .month: return "이번 달"
        case .none: return "기간 없음"
        }
    }
}

enum UsageMetric: Equatable {
    case percent(Double)
    case costUSD(Double)
    case tokens(Int)
    case requests(Int)
    case status(String)
    case unavailable(String)

    var valueText: String {
        switch self {
        case .percent(let value):
            return "\(Int(value.rounded()))%"
        case .costUSD(let value):
            return String(format: "$%.2f", value)
        case .tokens(let value):
            return formatNum(value)
        case .requests(let value):
            return "\(formatNum(value)) req"
        case .status(let value), .unavailable(let value):
            return value
        }
    }

    var menuText: String {
        switch self {
        case .percent(let value):
            return "\(Int(value.rounded()))%"
        case .costUSD(let value):
            return String(format: "$%.2f", value)
        case .tokens(let value):
            return formatNum(value)
        case .requests(let value):
            return "\(formatNum(value)) req"
        case .status(let value), .unavailable(let value):
            return value
        }
    }

    var percentValue: Double? {
        if case .percent(let value) = self { return value }
        return nil
    }
}

struct ProviderSnapshot: Identifiable, Equatable {
    let provider: AIProviderKind
    let title: String
    let sourceKind: UsageSourceKind
    let confidence: UsageConfidence
    let state: ProviderState
    let stateMessage: String
    let period: UsagePeriod
    let primary: UsageMetric
    let resetAt: Date?
    let costUSD: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let requestCount: Int?
    let modelSummary: String?
    let updatedAt: Date?

    var id: AIProviderKind { provider }

    var menuBarTitle: String {
        switch state {
        case .setupRequired:
            return "\(provider.menuName) 연결"
        case .unauthorized:
            return "\(provider.menuName) 인증"
        case .rateLimited:
            return "\(provider.menuName) 제한"
        case .offline:
            return "\(provider.menuName) 오류"
        case .unavailable:
            return "\(provider.menuName) 수집불가"
        case .loading:
            return "\(provider.menuName) …"
        case .configured:
            return "\(provider.menuName) 설정됨"
        case .ready, .stale:
            return "\(provider.menuName) \(primary.menuText)"
        }
    }

    var secondaryLine: String {
        var parts = [period.label, sourceKind.label, confidence.label]
        if let resetAt {
            parts.append("reset \(compactRemaining(until: resetAt))")
        }
        return parts.joined(separator: " · ")
    }
}

extension ProviderSnapshot {
    static func setupRequired(
        provider: AIProviderKind,
        period: UsagePeriod,
        message: String,
        updatedAt: Date?
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            title: provider.displayName,
            sourceKind: .setupRequired,
            confidence: .setupRequired,
            state: .setupRequired,
            stateMessage: message,
            period: period,
            primary: .status("연결 필요"),
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

    static func unavailable(
        provider: AIProviderKind,
        message: String,
        updatedAt: Date?
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            title: provider.displayName,
            sourceKind: .unavailable,
            confidence: .unavailable,
            state: .unavailable,
            stateMessage: message,
            period: .none,
            primary: .unavailable("공식 사용량 API 없음"),
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
}
