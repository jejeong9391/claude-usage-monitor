import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

check(diagnosticShouldRotate(currentBytes: 262_144, cap: 262_144) == true, "rotate at cap")
check(diagnosticShouldRotate(currentBytes: 262_145, cap: 262_144) == true, "rotate over cap")
check(diagnosticShouldRotate(currentBytes: 1000, cap: 262_144) == false, "no rotate under cap")

// 고정 날짜로 라인 포맷 검증 (2026-07-14T14:54:09Z 부근)
let d = Date(timeIntervalSince1970: 1_784_045_649)
var diag = OfficialFetchDiagnostics()
diag.urlErrorCode = -1200
let outcome = OfficialFetchOutcome(result: .offline, diagnostics: diag)
let line = diagnosticLogLine(date: d, outcome: outcome,
                             proxy: ProxyStatus(system: false, env: true),
                             appVersion: "1.0", os: "15.5")
check(line.contains("result=offline"), "line has result")
check(line.contains("urlerr=-1200"), "line has urlErrorCode")
check(line.contains("proxySystem=false"), "line has proxySystem")
check(line.contains("proxyEnv=true"), "line has proxyEnv")
check(!line.lowercased().contains("bearer") && !line.contains("token"), "line has no secret")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
