import AppKit

/// Keeps Utter up to date from the git clone it was built from (build.sh stores the clone's path in
/// Info.plist), with no questions asked: when origin has new commits, it pulls and builds in the
/// background, then swaps the app only while you're idle, so a dictation is never cut off.
@MainActor
final class Updater {
    private static let checkInterval: TimeInterval = 2 * 60 * 60
    private static let firstCheckDelay: TimeInterval = 60
    /// While a built update waits for an idle moment, check this often.
    private static let idlePollInterval: TimeInterval = 60
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Utter-update.log")
    /// Set right before the swap, read by the new instance to say it was updated.
    static let updatedFromKey = "updatedFromCommit"

    /// Whether now is a good moment to restart the app. Set by the app delegate.
    var isIdle: () -> Bool = { false }

    private let sourceDir = Bundle.main.object(forInfoDictionaryKey: "UtterSourceDir") as? String
    private var checkTimer: Timer?
    private var idleTimer: Timer?
    private var isBusy = false
    /// The swap is under way: this instance is about to be replaced, so no more checks.
    private var isInstalling = false
    /// A remote commit whose update failed: not retried until something newer lands.
    private var failedCommit: String?

    /// False for builds that don't come from a git clone.
    var isAvailable: Bool { sourceDir != nil }

    static var currentCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    func start() {
        guard isAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            Task { await self?.checkAndUpdate(userInitiated: false) }
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAndUpdate(userInitiated: false) }
        }
    }

    /// From the menu: checks now and, if there's an update, installs it right away.
    func checkNow() {
        Task { await checkAndUpdate(userInitiated: true) }
    }

    // MARK: - Private

    private func checkAndUpdate(userInitiated: Bool) async {
        guard let sourceDir, !isBusy, !isInstalling else { return }
        isBusy = true
        defer { isBusy = false }

        let fetch = await Self.shell("git fetch --quiet origin", in: sourceDir)
        guard fetch.status == 0 else {
            logger.error("update check failed: \(fetch.output, privacy: .public)")
            if userInitiated { showAlert("Couldn't check for updates.", details: fetch.output) }
            return
        }
        let remote = await Self.shell("git rev-parse --short @{u}", in: sourceDir).output
        guard remote != Self.currentCommit,
              await Self.shell("git merge-base --is-ancestor \(Self.currentCommit) @{u}", in: sourceDir).status == 0
        else {
            if userInitiated { showAlert("Utter is up to date.", details: "Version \(Self.currentCommit)") }
            return
        }
        guard userInitiated || remote != failedCommit else { return }
        // Uncommitted changes mean someone is working in this clone: don't build their half-done code.
        guard await Self.shell("git status --porcelain --untracked-files=no", in: sourceDir).output.isEmpty else {
            logger.notice("update to \(remote, privacy: .public) skipped: the clone has uncommitted changes")
            if userInitiated { showAlert("Utter can't update right now.", details: "\(sourceDir) has uncommitted changes.") }
            return
        }

        // Phase 1, while Utter keeps working: pull and do the slow build.
        logger.notice("updating from \(Self.currentCommit, privacy: .public) to \(remote, privacy: .public)")
        let build = await Self.shell("git pull --ff-only --quiet && ./build.sh > '\(Self.logURL.path)' 2>&1", in: sourceDir)
        guard build.status == 0 else {
            failedCommit = remote
            logger.error("update build failed, see \(Self.logURL.path, privacy: .public)")
            if userInitiated { showAlert("Utter couldn't be updated.", details: Self.logTail(or: build.output)) }
            return
        }

        // Phase 2: swap the app, which restarts it, only at a quiet moment (now, if you asked for it).
        if userInitiated || isIdle() {
            install(in: sourceDir)
        } else {
            waitForIdle(in: sourceDir)
        }
    }

    private func waitForIdle(in dir: String) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idlePollInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isIdle() else { return }
                timer.invalidate()
                self.install(in: dir)
            }
        }
    }

    /// `build.sh install` reuses the build from phase 1 (a few seconds), quits this app and opens the new one.
    /// If this app is still running when it ends, the swap failed.
    private func install(in dir: String) {
        isInstalling = true
        idleTimer?.invalidate()
        UserDefaults.standard.set(Self.currentCommit, forKey: Self.updatedFromKey)
        let process = Self.makeProcess("./build.sh install >> '\(Self.logURL.path)' 2>&1", in: dir)
        process.terminationHandler = { process in
            // On success the script quits this app before it ends, so getting here means it failed.
            Task { @MainActor in self.installFailed("exit status \(process.terminationStatus)") }
        }
        do { try process.run() } catch { installFailed(error.localizedDescription) }
    }

    private func installFailed(_ reason: String) {
        isInstalling = false
        UserDefaults.standard.removeObject(forKey: Self.updatedFromKey)
        logger.error("update install failed (\(reason, privacy: .public)), see \(Self.logURL.path, privacy: .public)")
    }

    private func showAlert(_ message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func logTail(or fallback: String) -> String {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return log.isEmpty ? fallback : String(log.suffix(600))
    }

    /// A login shell gives git the same PATH and credential helpers as your terminal (and cmake from Homebrew).
    private static func makeProcess(_ command: String, in dir: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"   // never hang waiting for a password
        environment.removeValue(forKey: "GGML_METAL_NO_RESIDENCY")
        process.environment = environment
        return process
    }

    private static func shell(_ command: String, in dir: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = makeProcess(command, in: dir)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus, output))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
