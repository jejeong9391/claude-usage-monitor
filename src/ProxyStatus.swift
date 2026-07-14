import Foundation

struct ProxyStatus {
    let system: Bool   // System Settings 프록시 활성 여부 — URLSession이 따르는 것
    let env: Bool      // HTTPS_PROXY 등 환경변수 존재 — CLI가 따르는 것
}

func proxyEnvPresent(_ env: [String: String]) -> Bool {
    ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"].contains { env[$0]?.isEmpty == false }
}

func proxySystemEnabled(_ settings: [String: Any]) -> Bool {
    func on(_ key: String) -> Bool { (settings[key] as? Int) == 1 }
    return on("HTTPEnable") || on("HTTPSEnable") || on("SOCKSEnable") || on("ProxyAutoConfigEnable")
}

func currentProxyStatus() -> ProxyStatus {
    let system = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
        .map(proxySystemEnabled) ?? false
    return ProxyStatus(system: system, env: proxyEnvPresent(ProcessInfo.processInfo.environment))
}
