import Foundation

// MARK: - 순수 로직 (테스트 대상)

func telemetryShouldEmit(previous: String?, current: String, firstOfSession: Bool) -> Bool {
    firstOfSession || previous != current
}

func telemetryInstallID(_ defaults: UserDefaults) -> String {
    let key = "telemetryInstallID"
    if let existing = defaults.string(forKey: key) { return existing }
    let id = UUID().uuidString          // 익명. 계정/기기 식별정보 아님.
    defaults.set(id, forKey: key)
    return id
}

func telemetryPayload(installID: String, outcome: OfficialFetchOutcome,
                      proxy: ProxyStatus, appVersion: String, os: String) -> [String: Any] {
    let d = outcome.diagnostics
    var p: [String: Any] = [
        "installID": installID,
        "result": outcome.result.telemetryName,
        "proxySystem": proxy.system,
        "proxyEnv": proxy.env,
        "decodeFailed": d.decodeFailed,
        "appVersion": appVersion,
        "os": os,
    ]
    if let s = d.httpStatus { p["httpStatus"] = s }
    if let c = d.urlErrorCode { p["urlErrorCode"] = c }
    return p
}

// MARK: - 전송 (부수효과)

enum Telemetry {
    static let defaultsKey = "telemetryEnabled"

    // 제공자 계정 생성 후 발급받는 값. Step 3 노트 참조.
    // 실제 ingest 엔드포인트/스키마는 계정 생성 후 context7/공식 문서로 확정한다.
    static let ingestEndpoint = URL(string: "https://REPLACE-WITH-INGEST-HOST/v0/event")!
    static let appID = "REPLACE-WITH-APP-ID"

    static var isEnabled: Bool {
        // 키가 없으면 기본 on(opt-out).
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? true : UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func trackOfficialResult(outcome: OfficialFetchOutcome, proxy: ProxyStatus,
                                    previous: String?, firstOfSession: Bool) {
        guard isEnabled else { return }
        guard telemetryShouldEmit(previous: previous,
                                  current: outcome.result.telemetryName,
                                  firstOfSession: firstOfSession) else { return }
        let payload = telemetryPayload(
            installID: telemetryInstallID(.standard),
            outcome: outcome, proxy: proxy,
            appVersion: appVersionString(), os: osVersionString())
        send(payload)
    }

    private static func send(_ payload: [String: Any]) {
        // 제공자 스키마에 맞춰 body 구성. 아래는 자체 엔드포인트/일반 REST ingest 기준 예시.
        var body = payload
        body["appID"] = appID
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: ingestEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        // fire-and-forget. 실패는 무시(앱 무영향).
        URLSession.shared.dataTask(with: req).resume()
    }
}
