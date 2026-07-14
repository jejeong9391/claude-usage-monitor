import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
func data(_ s: String) -> Data { Data(s.utf8) }

// 1) HTTP 응답 없음 + URLError → offline + urlErrorCode 포착
let netErr = URLError(.secureConnectionFailed)
let o1 = classifyOfficialResponse(data: nil, httpStatus: nil, error: netErr)
check(o1.result.telemetryName == "offline", "no-response → offline")
check(o1.diagnostics.urlErrorCode == netErr.errorCode, "urlErrorCode captured")

// 2) 401 → unauthorized
check(classifyOfficialResponse(data: nil, httpStatus: 401, error: nil).result.telemetryName == "unauthorized", "401 → unauthorized")

// 3) 429 → rateLimited
check(classifyOfficialResponse(data: nil, httpStatus: 429, error: nil).result.telemetryName == "rateLimited", "429 → rateLimited")

// 4) 200 + rate_limit 에러 객체 → rateLimited + bodyWasErrorObject
let o4 = classifyOfficialResponse(data: data(#"{"error":{"type":"rate_limit_error"}}"#), httpStatus: 200, error: nil)
check(o4.result.telemetryName == "rateLimited", "200+rate_limit body → rateLimited")
check(o4.diagnostics.bodyWasErrorObject, "bodyWasErrorObject flagged")

// 5) 200 + 기타 에러 객체 → offline
check(classifyOfficialResponse(data: data(#"{"error":{"type":"overloaded_error"}}"#), httpStatus: 200, error: nil).result.telemetryName == "offline", "200+other error → offline")

// 6) 200 + 유효 usage → ok
let o6 = classifyOfficialResponse(data: data(#"{"five_hour":{"utilization":42.0,"resets_at":"2026-07-14T20:00:00Z"}}"#), httpStatus: 200, error: nil)
check(o6.result.telemetryName == "ok", "200+valid → ok")

// 7) 200 + 디코드 불가(JSON 배열) → offline + decodeFailed
let o7 = classifyOfficialResponse(data: data("[1,2,3]"), httpStatus: 200, error: nil)
check(o7.result.telemetryName == "offline", "200+garbage → offline")
check(o7.diagnostics.decodeFailed, "decodeFailed flagged")

// 8) 500 → offline
check(classifyOfficialResponse(data: nil, httpStatus: 500, error: nil).result.telemetryName == "offline", "500 → offline")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
