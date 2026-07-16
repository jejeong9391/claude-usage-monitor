import Foundation

// MARK: - Keychain 토큰 조달
// Keychain Security API 대신 `security` CLI 를 Process 로 호출한다.
// ccusage 를 Process 로 부르는 방식과 동일하게 맞춰 코드를 단순화.
// 최초 1회 Keychain 접근 허용 프롬프트가 뜰 수 있다.

enum KeychainToken {
    private static func runSecurity() -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        // keychain 접근 프롬프트(재서명된 바이너리 등)로 무한 블록되는 것을 방지.
        // 5초 안에 끝나지 않으면 강제 종료하고 실패 처리 → 앱이 영구 스피너에 갇히지 않는다.
        let deadline = Date().addingTimeInterval(5)
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

    /// credentials JSON 의 claudeAiOauth.accessToken 반환.
    static func read() -> String? {
        guard let data = runSecurity() else { return nil }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = obj["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }
}

// MARK: - 공식 사용량 Provider

enum OfficialResult {
    case ok(OfficialUsage)
    case loading        // 최초 fetch 완료 전 (에러 아님 — 스피너만 표시)
    case noToken        // Keychain 에 자격증명 없음 → Claude Code 로그인 필요
    case unauthorized   // 401 → 토큰 만료
    case rateLimited    // 429 또는 200+{error:rate_limit_error} → 일시적, 자동 복구
    case offline        // 네트워크/기타 실패
}

extension OfficialResult {
    /// 텔레메트리/로그/전이감지용 안정 문자열 (associated value 제외).
    var telemetryName: String {
        switch self {
        case .ok: return "ok"
        case .loading: return "loading"
        case .noToken: return "noToken"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rateLimited"
        case .offline: return "offline"
        }
    }
}

struct OfficialFetchDiagnostics {
    var httpStatus: Int?
    var urlErrorCode: Int?
    var urlErrorDesc: String?
    var decodeFailed: Bool = false
    var bodyWasErrorObject: Bool = false
}

struct OfficialFetchOutcome {
    let result: OfficialResult
    let diagnostics: OfficialFetchDiagnostics
}

/// 순수 분류: 응답을 OfficialResult + 진단정보로 변환. 네트워크 호출 없음(테스트 가능).
func classifyOfficialResponse(data: Data?, httpStatus: Int?, error: Error?) -> OfficialFetchOutcome {
    var d = OfficialFetchDiagnostics()
    d.httpStatus = httpStatus

    guard let status = httpStatus else {
        if let urlErr = error as? URLError {
            d.urlErrorCode = urlErr.errorCode
            d.urlErrorDesc = urlErr.localizedDescription
        }
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    if status == 401 { return OfficialFetchOutcome(result: .unauthorized, diagnostics: d) }
    if status == 429 { return OfficialFetchOutcome(result: .rateLimited, diagnostics: d) }
    guard (200..<300).contains(status), let data = data else {
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    // HTTP 200 이어도 본문이 에러 객체일 수 있다. 모든 OfficialUsage 필드가 Optional 이라
    // 빈/에러 본문을 그대로 디코드하면 빈 .ok 로 오인되므로, decode 전에 먼저 거른다.
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let err = obj["error"] as? [String: Any] {
        d.bodyWasErrorObject = true
        let isRate = (err["type"] as? String) == "rate_limit_error"
        return OfficialFetchOutcome(result: isRate ? .rateLimited : .offline, diagnostics: d)
    }
    guard let usage = try? JSONDecoder().decode(OfficialUsage.self, from: data) else {
        d.decodeFailed = true
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    return OfficialFetchOutcome(result: .ok(usage), diagnostics: d)
}

enum OfficialUsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 동기 호출 (refresh 의 Task.detached 내부에서 사용).
    static func fetch() -> OfficialFetchOutcome {
        guard let token = KeychainToken.read() else {
            return OfficialFetchOutcome(result: .noToken, diagnostics: OfficialFetchDiagnostics())
        }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var outcome = OfficialFetchOutcome(result: .offline, diagnostics: OfficialFetchDiagnostics())
        let dataTask = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode
            outcome = classifyOfficialResponse(data: data, httpStatus: status, error: error)
        }
        dataTask.resume()
        sem.wait()
        return outcome
    }
}

// MARK: - ccusage Provider (상세 전용)

enum CCUsageProvider {
    private static func run(_ args: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ccusage")
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/node/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = env
        let outPipe = Pipe()
        let outHandle = outPipe.fileHandleForReading
        task.standardOutput = outPipe
        task.standardError = Pipe()

        // ccusage 는 모델 가격표(공개 LiteLLM 데이터)를 온라인에서 받아 정확한 비용을 계산한다.
        // 네트워크 지연에 대비해: 출력을 백그라운드로 드레인(파이프 버퍼 데드락 방지)하고,
        // 15초 안에 끝나지 않으면 강제 종료하고 실패 처리한다 → refresh 사이클이 멈추지 않는다.
        var collected = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected = outHandle.readDataToEndOfFile()
            done.signal()
        }
        do {
            try task.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + 15) == .timedOut {
            task.terminate()
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return collected
    }

    /// 현재 활성 5h 블록 (비용·토큰·burn·모델).
    static func activeBlock() -> Block? {
        guard let d = run(["blocks", "--active", "--json"]),
              let parsed = try? JSONDecoder().decode(BlocksResponse.self, from: d)
        else { return nil }
        return parsed.blocks.first(where: { $0.isActive })
    }

    /// 주간(수 11:00 KST 시작 ~ 오늘) 비용 합계.
    static func weeklyCost() -> Double? {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let today = df.string(from: Date())
        let start = df.string(from: weekStart(from: Date()))
        guard let d = run(["daily", "--json", "-s", start, "-u", today]),
              let parsed = try? JSONDecoder().decode(DailyResponse.self, from: d)
        else { return nil }
        return parsed.daily.reduce(0) { $0 + ($1.totalCost ?? 0) }
    }
}

/// Anthropic Max 5x 주간 윈도우 시작: 매주 수요일 11:00 KST.
func weekStart(from now: Date) -> Date {
    let kst = TimeZone(identifier: "Asia/Seoul") ?? TimeZone.current
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = kst
    let comp = cal.dateComponents([.hour, .weekday], from: now)
    let weekday = comp.weekday ?? 1   // 일=1 ... 수=4
    let daysBack: Int
    if weekday == 4 && (comp.hour ?? 0) < 11 {
        daysBack = 7
    } else {
        daysBack = (weekday - 4 + 7) % 7
    }
    let base = cal.date(byAdding: .day, value: -daysBack, to: now) ?? now
    var bc = cal.dateComponents([.year, .month, .day], from: base)
    bc.hour = 11; bc.minute = 0; bc.second = 0
    return cal.date(from: bc) ?? base
}
