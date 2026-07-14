import Foundation

func appVersionString() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
}

func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
