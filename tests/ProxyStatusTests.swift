import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// env 감지
check(proxyEnvPresent(["HTTPS_PROXY": "http://p:8080"]) == true, "env HTTPS_PROXY set")
check(proxyEnvPresent(["all_proxy": "socks://p:1080"]) == true, "env all_proxy set")
check(proxyEnvPresent(["HTTPS_PROXY": ""]) == false, "env empty string ignored")
check(proxyEnvPresent([:]) == false, "env none")

// system 감지 (CFNetwork 설정 딕셔너리 형태 모사)
check(proxySystemEnabled(["HTTPSEnable": 1]) == true, "system HTTPS on")
check(proxySystemEnabled(["SOCKSEnable": 1]) == true, "system SOCKS on")
check(proxySystemEnabled(["ProxyAutoConfigEnable": 1]) == true, "system PAC on")
check(proxySystemEnabled(["HTTPEnable": 0, "HTTPSEnable": 0]) == false, "system all off")
check(proxySystemEnabled([:]) == false, "system none")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
