import Cocoa

/// 인앱 업데이트: `git pull --ff-only`(실패 허용) → `build.sh`(현재 워킹트리 기준 재빌드+재설치)
/// → 성공 시 새 버전으로 재시작. 빌드 실패 시 현재 앱을 그대로 유지한다.
///
/// 소스 루트는 `build.sh` 가 빌드 시 Info.plist 의 `SourceRoot` 키에 기록한다.
/// 빌드 로직은 전적으로 `build.sh` 에 캡슐화되어 있고, 이 서비스는 순서·재시작만 담당한다.
@MainActor
final class UpdateService: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    /// 백그라운드 빌드 결과. Process/스레드 경계를 넘으므로 Sendable 값 타입.
    enum Outcome: Sendable {
        case ok
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// 빌드 시 주입된 소스 루트(절대경로). 없으면 업데이트 불가.
    let sourceRoot: String?
    /// 현재 실행 중인 .app 번들 경로 — 재시작 대상.
    private let installedAppPath: String

    init() {
        sourceRoot = Bundle.main.object(forInfoDictionaryKey: "SourceRoot") as? String
        installedAppPath = Bundle.main.bundlePath
    }

    /// 업데이트 가능 여부: 소스 루트와 build.sh 가 실재할 때만.
    var canUpdate: Bool {
        guard let root = sourceRoot else { return false }
        return FileManager.default.isExecutableFile(atPath: root + "/build.sh")
    }

    /// 업데이트 시작. 중복 실행을 막고, 사전조건 미충족 시 즉시 실패 표시.
    func startUpdate() {
        if case .running = state { return }
        guard let root = sourceRoot, canUpdate else {
            state = .failed("소스 경로를 찾을 수 없습니다 (SourceRoot)")
            return
        }
        state = .running
        let appPath = installedAppPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = UpdateService.performUpdate(root: root)
            await self?.finish(outcome: outcome, appPath: appPath)
        }
    }

    /// 메인 액터에서 결과 처리: 성공이면 재시작 예약 후 종료, 실패면 상태만 갱신.
    private func finish(outcome: Outcome, appPath: String) {
        switch outcome {
        case .ok:
            UpdateService.scheduleRelaunch(appPath: appPath)
            NSApp.terminate(nil)
        case .failed(let message):
            state = .failed(message)
        }
    }

    // MARK: - 백그라운드 작업 (nonisolated)

    /// git pull(실패 허용) 후 build.sh 실행. build.sh 비정상 종료만 실패로 간주한다.
    nonisolated private static func performUpdate(root: String) -> Outcome {
        // 1) 원격 최신 반영 시도. 충돌·인증·로컬 미커밋 변경 등으로 실패해도 무시하고 진행.
        _ = runProcess("/usr/bin/git", ["-C", root, "pull", "--ff-only"], cwd: root)

        // 2) 항상 현재 워킹트리 기준으로 재빌드 + ~/Applications 재설치.
        let build = runProcess("/bin/bash", [root + "/build.sh"], cwd: root)
        guard build.exitCode == 0 else {
            return .failed(buildErrorSummary(build.output))
        }
        return .ok
    }

    /// 현재 인스턴스 종료 후 새 바이너리를 띄우기 위한 분리 프로세스.
    /// 부모(앱)가 종료돼도 살아남아 1초 뒤 새 인스턴스를 연다.
    nonisolated private static func scheduleRelaunch(appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appPath)\""]
        try? process.run()
    }

    // MARK: - Process 헬퍼

    private struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

    /// 동기 실행 후 (종료코드, stdout+stderr) 반환. 출력이 작아 단순 readToEnd 로 충분.
    nonisolated private static func runProcess(_ launchPath: String,
                                               _ arguments: [String],
                                               cwd: String) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // GUI 앱에서 상속되는 최소 PATH 를 보강 (swiftc/codesign/git 등 해석용).
        var env = ProcessInfo.processInfo.environment
        let base = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["PATH"] = env["PATH"].map { "\(base):\($0)" } ?? base
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, output: "실행 실패: \(launchPath) — \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, output: output)
    }

    /// 빌드 출력에서 사용자에게 보여줄 마지막 의미 있는 줄들을 추린다.
    nonisolated private static func buildErrorSummary(_ output: String) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // 컴파일 오류 줄을 우선 노출.
        if let errorLine = lines.last(where: { $0.contains("error:") }) {
            return "빌드 실패: \(errorLine)"
        }
        if let tail = lines.last, !tail.isEmpty {
            return "빌드 실패: \(tail)"
        }
        return "빌드 실패 (원인 미상)"
    }
}
