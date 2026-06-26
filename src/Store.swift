import SwiftUI

/// 두 Provider 결과를 병합해 UI 에 게시한다.
/// 공식치(%·재설정)와 ccusage 상세는 독립적으로 갱신 — 한쪽 실패가 다른 쪽을 막지 않는다.
@MainActor
final class UsageStore: ObservableObject {
    // 공식 (진실의 원천). 성공값은 유지하고 상태만 따로 표시 → 오프라인 시 직전 값 노출.
    @Published var official: OfficialUsage?
    @Published var officialState: OfficialResult = .loading

    // ccusage (참고 상세)
    @Published var block: Block?
    @Published var weeklyCost: Double?

    @Published var lastUpdate: Date = Date()
    @Published var loading: Bool = true

    func refresh() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let off = OfficialUsageProvider.fetch()
            let block = CCUsageProvider.activeBlock()
            let wCost = CCUsageProvider.weeklyCost()
            await self?.apply(off: off, block: block, weeklyCost: wCost)
        }
    }

    private func apply(off: OfficialResult, block: Block?, weeklyCost: Double?) {
        officialState = off
        if case let .ok(usage) = off { official = usage }
        self.block = block
        self.weeklyCost = weeklyCost
        lastUpdate = Date()
        loading = false
    }

    // 메뉴바 타이틀: "🔥 58% · 2h41m"
    var menuBarTitle: String {
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

extension OfficialResult {
    /// 사용자에게 '문제' 로 노출할 상태인가. 로딩과 정상은 에러가 아니다.
    var isError: Bool {
        switch self {
        case .ok, .loading: return false
        case .noToken, .unauthorized, .rateLimited, .offline: return true
        }
    }
}
