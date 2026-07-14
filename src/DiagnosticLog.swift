import Foundation

// MARK: - 순수 로직 (테스트 대상)

func diagnosticShouldRotate(currentBytes: Int, cap: Int) -> Bool {
    currentBytes >= cap
}

func diagnosticLogLine(date: Date, outcome: OfficialFetchOutcome,
                       proxy: ProxyStatus, appVersion: String, os: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone.current
    iso.formatOptions = [.withInternetDateTime]
    let d = outcome.diagnostics
    let http = d.httpStatus.map(String.init) ?? "nil"
    let urlerr = d.urlErrorCode.map(String.init) ?? "nil"
    return "\(iso.string(from: date)) result=\(outcome.result.telemetryName) "
        + "http=\(http) urlerr=\(urlerr) "
        + "proxySystem=\(proxy.system) proxyEnv=\(proxy.env) "
        + "decodeFailed=\(d.decodeFailed) v=\(appVersion) os=\(os)"
}

// MARK: - 파일 로거 (부수효과, try? 로 조용히 실패)

enum DiagnosticLog {
    static let defaultsKey = "diagnosticLoggingEnabled"
    static let cap = 262_144   // 256KB
    private static let queue = DispatchQueue(label: "com.jeongjieun.ClaudeUsageMonitor.diaglog")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/ClaudeUsageMonitor", isDirectory: true)
    }
    private static var fileURL: URL { directoryURL.appendingPathComponent("monitor.log") }
    private static var rotatedURL: URL { directoryURL.appendingPathComponent("monitor.log.1") }

    static func log(outcome: OfficialFetchOutcome, proxy: ProxyStatus) {
        guard isEnabled else { return }   // off면 파일 접근조차 안 함
        let line = diagnosticLogLine(
            date: Date(), outcome: outcome, proxy: proxy,
            appVersion: appVersionString(), os: osVersionString()) + "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)   // 파일이 없으면 새로 생성
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard let bytes = size, diagnosticShouldRotate(currentBytes: bytes, cap: cap) else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }
}
