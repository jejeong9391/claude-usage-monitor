import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// 전송 게이트: 전이 또는 세션최초일 때만
check(telemetryShouldEmit(previous: nil, current: "ok", firstOfSession: true) == true, "first of session emits")
check(telemetryShouldEmit(previous: "ok", current: "offline", firstOfSession: false) == true, "transition emits")
check(telemetryShouldEmit(previous: "offline", current: "offline", firstOfSession: false) == false, "same state no emit")

// installID: 최초 생성 후 고정
let d = UserDefaults(suiteName: "telemetry.test.\(UUID().uuidString)")!
let id1 = telemetryInstallID(d)
let id2 = telemetryInstallID(d)
check(id1 == id2, "installID stable")
check(UUID(uuidString: id1) != nil, "installID is uuid")

// payload: 진단 필드만, 비밀 없음
var diag = OfficialFetchDiagnostics(); diag.httpStatus = 407
let p = telemetryPayload(installID: id1,
                         outcome: OfficialFetchOutcome(result: .offline, diagnostics: diag),
                         proxy: ProxyStatus(system: false, env: true),
                         appVersion: "1.0", os: "15.5")
check(p["result"] as? String == "offline", "payload result")
check(p["httpStatus"] as? Int == 407, "payload httpStatus")
check(p["proxyEnv"] as? Bool == true, "payload proxyEnv")
check(p.keys.contains("bodyWasErrorObject"), "payload has bodyWasErrorObject key")
let flat = "\(p)".lowercased()
check(!flat.contains("bearer") && !flat.contains("token") && !flat.contains("authorization"), "payload has no secret")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
