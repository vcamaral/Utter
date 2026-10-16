import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case loading(String)
        case ready
        case recording(handsFree: Bool)
        case transcribing
        case failed(String)
    }

    private let settings = AppSettings()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = RecordingOverlay()
    private let mediaPause = MediaPause()
    private let triggerCapture = TriggerCapturePanel()
    private let setup = SetupWindow()
    private let updater = Updater()
    private lazy var pushToTalk = PushToTalk(settings: settings)
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let setupItem = NSMenuItem(title: "Finish Setup…", action: #selector(showSetup), keyEquivalent: "")
    private let triggerItem = NSMenuItem(title: "", action: #selector(changeTrigger), keyEquivalent: "")
    private let pauseMediaItem = NSMenuItem(title: "Pause Media While Dictating", action: #selector(togglePauseMedia), keyEquivalent: "")
    private let soundsItem = NSMenuItem(title: "Play Sounds", action: #selector(toggleSounds), keyEquivalent: "")
    private let indicatorItem = NSMenuItem(title: "Show Recording Indicator", action: #selector(toggleIndicator), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let howToItem = NSMenuItem(title: "How to Use…", action: #selector(showSetup), keyEquivalent: "")
    private let aboutItem = NSMenuItem(title: "About Utter", action: #selector(showAbout), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private var permissionTimer: Timer?
    /// Whether System Settings was already open when we sent you there, so we only close it if we opened it.
    private var settingsWasOpen = true
    private var isModelLoaded = false
    private var isModelLoading = false
    private var live: LiveTranscription?
    /// Why the current press can't record, shown once the press is confirmed.
    private var startProblem: String?
    private var handsFreeWatchdog: Timer?
    private var lastVoiceAt = Date()
    /// Last time you dictated; updates only restart the app after a while without dictating.
    private var lastDictationAt = Date()
    private static let idleBeforeUpdate: TimeInterval = 10 * 60

    private var state: State = .loading("Starting…") { didSet { render() } }
    private var hasAccessibility = TextInjector.isTrusted { didSet { render() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        setUpPushToTalk()
        setUpSetupWindow()
        if hasAccessibility { pushToTalk.install() }
        recorder.warmUp()
        if !setup.model.hasPermissions { startPermissionPolling() }
        loadModel()
        if !settings.setupCompleted || !setup.model.hasPermissions { showSetup() }
        setUpUpdater()
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        triggerItem.title = "Dictation Key: \(settings.trigger.name)…"
        pauseMediaItem.state = settings.pauseMedia ? .on : .off
        soundsItem.state = settings.playSounds ? .on : .off
        indicatorItem.state = settings.showIndicator ? .on : .off
        loginItem.state = settings.launchAtLogin ? .on : .off
        setupItem.isHidden = setup.model.isComplete
    }

    // MARK: - Setup

    /// Menu bar apps have no visible main menu, but text fields still need one for ⌘C, ⌘V, ⌘A and ⌘Z.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        mainMenu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Dictation"))
        for item in [triggerItem, pauseMediaItem, soundsItem, indicatorItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "General"))
        updateItem.isHidden = !updater.isAvailable
        for item in [loginItem, howToItem, updateItem, aboutItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setUpPushToTalk() {
        pushToTalk.onStart = { [weak self] in self?.startRecording() }
        pushToTalk.onCommit = { [weak self] in self?.commitRecording() }
        pushToTalk.onLock = { [weak self] in self?.lockRecording() }
        pushToTalk.onStop = { [weak self] in self?.finishRecording() }
        pushToTalk.onCancel = { [weak self] in self?.cancelRecording() }

        triggerCapture.onCapture = { [weak self] trigger in
            self?.settings.trigger = trigger
            self?.setup.model.triggerName = trigger.name
            self?.render()
        }
        triggerCapture.onClose = { [weak self] in self?.pushToTalk.isPaused = false }
    }

    private func setUpUpdater() {
        updater.isIdle = { [weak self] in
            guard let self, case .ready = state else { return false }
            return Date().timeIntervalSince(lastDictationAt) >= Self.idleBeforeUpdate
        }
        updater.start()
        // The previous instance set this right before restarting into the new version.
        if UserDefaults.standard.string(forKey: Updater.updatedFromKey) != nil {
            UserDefaults.standard.removeObject(forKey: Updater.updatedFromKey)
            overlay.flash("Utter updated to version \(Updater.currentCommit)")
        }
    }

    private func setUpSetupWindow() {
        let model = setup.model
        model.triggerName = settings.trigger.name
        model.onAllowMicrophone = { [weak self] in
            if AudioRecorder.authorizationStatus == .notDetermined {
                Task {
                    _ = await AudioRecorder.requestPermission()
                    self?.refreshPermissions()
                    // The permission prompt belongs to macOS and keeps the focus when it closes;
                    // a menu bar app isn't brought back on its own, so the setup would end up behind other windows.
                    self?.setup.show()
                }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
        model.onAllowAccessibility = { [weak self] in
            self?.settingsWasOpen = Self.isSystemSettingsOpen
            TextInjector.requestPermission()
        }
        model.onChangeKey = { [weak self] in self?.changeTrigger() }
        model.onRetry = { [weak self] in self?.loadModel() }
        model.onDone = { [weak self] in
            guard let self else { return }
            if setup.model.isComplete {
                settings.setupCompleted = true
                if settings.launchAtLogin != setup.model.launchAtLogin {
                    settings.launchAtLogin = setup.model.launchAtLogin
                }
            }
            setup.close()
        }
    }

    /// Permissions are granted in System Settings, which doesn't tell the app, so check every second.
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        let model = setup.model
        var granted = false
        let microphone = AudioRecorder.authorizationStatus
        if microphone != model.microphone {
            model.microphone = microphone
            recorder.warmUp()
            granted = microphone == .authorized
        }
        if TextInjector.isTrusted, !hasAccessibility {
            hasAccessibility = true
            model.accessibility = true
            // Key monitors only receive events once the app is trusted.
            pushToTalk.install()
            granted = true
            closeSystemSettingsIfWeOpenedIt()
        }
        // Granted in System Settings: bring the setup back to the front, where the next step is.
        if granted, setup.isVisible { setup.show() }
        if model.hasPermissions {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private static let systemSettingsID = "com.apple.systempreferences"

    private static var isSystemSettingsOpen: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsID).isEmpty
    }

    /// Once the permission is granted, System Settings has done its job: close it, unless you had it open already.
    private func closeSystemSettingsIfWeOpenedIt() {
        guard !settingsWasOpen else { return }
        settingsWasOpen = true
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsID).forEach { $0.terminate() }
    }

    private func loadModel() {
        guard !isModelLoaded, !isModelLoading else { return }
        isModelLoading = true
        Task {
            defer { isModelLoading = false }
            do {
                try await transcriber.prepare(
                    onDownloadProgress: { progress in
                        Task { @MainActor in
                            self.setup.model.model = .downloading(progress)
                            self.state = .loading("Downloading model… \(Int(progress * 100))%")
                        }
                    },
                    onLoading: {
                        Task { @MainActor in
                            self.setup.model.model = .preparing
                            self.state = .loading("Loading model…")
                        }
                    }
                )
                isModelLoaded = true
                setup.model.model = .ready
                state = .ready
            } catch {
                let message = "Couldn't get the model: \(error.localizedDescription)"
                setup.model.model = .failed(message)
                state = .failed(message)
            }
        }
    }

    // MARK: - Dictation

    /// Hands-free stops by itself after this long without speech, or this long in total.
    private static let handsFreeSilenceLimit: TimeInterval = 60
    private static let handsFreeMaxDuration: TimeInterval = 15 * 60
    /// Microphone loudness (RMS) that counts as someone speaking, about -40 dBFS.
    private static let voiceRMS: Float = 0.01

    /// The key went down. Recording starts right away so no word is lost; all feedback waits for `commitRecording`.
    private func startRecording() {
        lastDictationAt = Date()
        // A failed dictation shouldn't block the next one.
        switch state {
        case .ready, .failed, .loading: break
        default: return
        }
        // Problems are only reported once the press is confirmed, so ⌘-shortcuts don't trigger error popups.
        guard isModelLoaded else {
            startProblem = isModelLoading ? "Voice recognition is still getting ready" : "Voice recognition isn't ready. Open Utter's menu to retry."
            return
        }
        guard AudioRecorder.isAuthorized else {
            startProblem = "Utter can't use the microphone. Allow it in System Settings → Privacy & Security."
            return
        }
        transcriber.preload()   // no-op unless the models were unloaded while idle
        do {
            try recorder.start()
            state = .recording(handsFree: false)
            live = LiveTranscription(audio: recorder, transcriber: transcriber)
            live?.start()
        } catch {
            logger.error("recording failed to start: \(error.localizedDescription, privacy: .public)")
            startProblem = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func commitRecording() {
        if let startProblem {
            overlay.flash(startProblem, isError: true)
            return
        }
        guard case .recording = state else { return }
        if settings.pauseMedia { mediaPause.recordingStarted() }
        if settings.playSounds { Sounds.playStart() }
        if settings.showIndicator {
            overlay.show { [recorder] in recorder.level }
        }
    }

    private func lockRecording() {
        guard case .recording = state else { return }
        state = .recording(handsFree: true)
        overlay.showLocked(hint: "tap \(settings.trigger.name) to finish · esc to cancel")
        startHandsFreeWatchdog()
    }

    /// - Parameter notice: Shown after pasting, e.g. why hands-free stopped by itself.
    private func finishRecording(notice: String? = nil) {
        startProblem = nil
        guard case .recording(let handsFree) = state else { return }
        stopHandsFreeWatchdog()
        let samples = recorder.stop()
        mediaPause.recordingEnded()
        if settings.playSounds { Sounds.playStop() }
        state = .transcribing
        overlay.showTranscribing()
        let live = self.live
        self.live = nil
        let clock = ContinuousClock()
        let start = clock.now
        Task {
            do {
                let text = try await live?.finish(with: samples) ?? ""
                let outcome = text.isEmpty ? nil : TextInjector.insert(text)
                logger.notice("dictation of \(Double(samples.count) / 16_000, format: .fixed(precision: 1))s\(handsFree ? " (hands-free)" : "", privacy: .public): \(outcome.map { "\($0)" } ?? "nothing to paste", privacy: .public), \(String(describing: clock.now - start), privacy: .public) after release")
                if outcome == .copied {
                    overlay.flash("Copied — press ⌘V to paste")
                } else if text.isEmpty {
                    // Silence or noise: say so, or it looks like Utter didn't react.
                    overlay.flash(notice ?? "Didn't catch that")
                } else if let notice {
                    overlay.flash(notice)
                } else {
                    overlay.hide()
                }
                state = .ready
            } catch {
                logger.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                overlay.flash("Couldn't transcribe: \(error.localizedDescription)", isError: true)
                state = .failed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRecording() {
        startProblem = nil
        guard case .recording = state else { return }
        stopHandsFreeWatchdog()
        live?.cancel()
        live = nil
        _ = recorder.stop()
        mediaPause.recordingEnded()
        overlay.hide()
        state = .ready
    }

    /// A forgotten hands-free dictation would keep the microphone on forever: stop it after a minute
    /// without speech, or after a long while in any case.
    private func startHandsFreeWatchdog() {
        let startedAt = Date()
        lastVoiceAt = startedAt
        handsFreeWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.recorder.level >= Self.voiceRMS { self.lastVoiceAt = Date() }
                let silent = Date().timeIntervalSince(self.lastVoiceAt) >= Self.handsFreeSilenceLimit
                let tooLong = Date().timeIntervalSince(startedAt) >= Self.handsFreeMaxDuration
                guard silent || tooLong else { return }
                logger.notice("hands-free stopped by itself: \(silent ? "silence" : "maximum duration", privacy: .public)")
                self.pushToTalk.reset()
                self.finishRecording(notice: silent ? "Stopped after a minute of silence" : "Stopped after 15 minutes")
            }
        }
    }

    private func stopHandsFreeWatchdog() {
        handsFreeWatchdog?.invalidate()
        handsFreeWatchdog = nil
    }

    // MARK: - Menu actions

    @objc private func showSetup() {
        setup.model.triggerName = settings.trigger.name
        setup.show()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Local voice dictation. Powered by Whisper and whisper.cpp; your voice never leaves this Mac.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func changeTrigger() {
        pushToTalk.isPaused = true
        triggerCapture.show(current: settings.trigger)
    }

    @objc private func togglePauseMedia() {
        settings.pauseMedia.toggle()
    }

    @objc private func toggleSounds() {
        settings.playSounds.toggle()
    }

    @objc private func toggleIndicator() {
        settings.showIndicator.toggle()
    }

    @objc private func toggleLoginItem() {
        settings.launchAtLogin.toggle()
    }

    // MARK: - Rendering

    private func render() {
        let trigger = settings.trigger.name
        let (symbol, text): (NSImage?, String) = switch state {
        case .failed(let message): (systemIcon("exclamationmark.triangle"), message)
        case _ where !hasAccessibility: (systemIcon("lock"), "Allow Utter in System Settings → Privacy & Security → \(TextInjector.permissionName)")
        case .loading(let message): (systemIcon("arrow.down.circle"), message)
        case .ready: (MenuBarIcon.normal, "Ready · hold \(trigger) to dictate")
        case .recording(handsFree: false): (MenuBarIcon.normal, "Listening…")
        case .recording(handsFree: true): (MenuBarIcon.normal, "Hands-free · tap \(trigger) to finish")
        case .transcribing: (MenuBarIcon.dimmed, "Transcribing…")
        }
        guard let button = statusItem?.button else { return }
        button.image = symbol
        button.contentTintColor = if case .recording = state { .systemRed } else { nil }
        statusLine.title = text
    }

    private func systemIcon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Utter")
    }
}
