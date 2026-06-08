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
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return outPipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
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
    case noToken        // Keychain 에 자격증명 없음 → Claude Code 로그인 필요
    case unauthorized   // 401 → 토큰 만료
    case offline        // 네트워크/기타 실패
}

enum OfficialUsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 동기 호출 (refresh 의 Task.detached 내부에서 사용).
    static func fetch() -> OfficialResult {
        guard let token = KeychainToken.read() else { return .noToken }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var result: OfficialResult = .offline
        let dataTask = URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                result = .unauthorized
                return
            }
            guard
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let data = data,
                let usage = try? JSONDecoder().decode(OfficialUsage.self, from: data)
            else {
                result = .offline
                return
            }
            result = .ok(usage)
        }
        dataTask.resume()
        sem.wait()
        return result
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
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return outPipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    /// 현재 활성 5h 블록 (비용·토큰·burn·모델).
    static func activeBlock() -> Block? {
        guard let d = run(["blocks", "--active", "--json", "--offline"]),
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
        guard let d = run(["daily", "--json", "--offline", "-s", start, "-u", today]),
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
