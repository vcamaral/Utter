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
    private lazy var pushToTalk = PushToTalk(settings: settings)
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let setupItem = NSMenuItem(title: "Finish Setup…", action: #selector(showSetup), keyEquivalent: "")
    private let triggerItem = NSMenuItem(title: "", action: #selector(changeTrigger), keyEquivalent: "")
    private let fnHintItem = NSMenuItem(title: "Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings", action: nil, keyEquivalent: "")
    private let pauseMediaItem = NSMenuItem(title: "Pause Media While Dictating", action: #selector(togglePauseMedia), keyEquivalent: "")
    private let soundsItem = NSMenuItem(title: "Play Sounds", action: #selector(toggleSounds), keyEquivalent: "")
    private let indicatorItem = NSMenuItem(title: "Show Recording Indicator", action: #selector(toggleIndicator), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private var permissionTimer: Timer?
    /// Whether System Settings was already open when we sent you there, so we only close it if we opened it.
    private var settingsWasOpen = true
    private var isModelLoaded = false
    private var isModelLoading = false

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
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        triggerItem.title = "Dictation Key: \(settings.trigger.name)…"
        fnHintItem.isHidden = settings.trigger.keyCode != 63
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

        triggerItem.target = self
        menu.addItem(triggerItem)
        fnHintItem.isEnabled = false
        menu.addItem(fnHintItem)
        for item in [pauseMediaItem, soundsItem, indicatorItem, loginItem] {
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

    /// The key went down. Recording starts right away so no word is lost; all feedback waits for `commitRecording`.
    private func startRecording() {
        // A failed dictation shouldn't block the next one, only a missing model should.
        switch state {
        case .ready, .failed: guard isModelLoaded else { return }
        default: return
        }
        guard AudioRecorder.isAuthorized else {
            state = .failed("Allow Microphone access in System Settings → Privacy & Security")
            return
        }
        do {
            try recorder.start()
            state = .recording(handsFree: false)
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func commitRecording() {
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
        overlay.showLocked()
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        let samples = recorder.stop()
        mediaPause.recordingEnded()
        if settings.playSounds { Sounds.playStop() }
        state = .transcribing
        overlay.showTranscribing()
        Task {
            do {
                let text = try await transcriber.transcribe(samples)
                if !text.isEmpty, TextInjector.insert(text) == .copied {
                    overlay.flash("Copied — press ⌘V to paste")
                } else {
                    overlay.hide()
                }
                state = .ready
            } catch {
                overlay.hide()
                state = .failed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRecording() {
        guard case .recording = state else { return }
        _ = recorder.stop()
        mediaPause.recordingEnded()
        overlay.hide()
        state = .ready
    }

    // MARK: - Menu actions

    @objc private func showSetup() {
        setup.model.triggerName = settings.trigger.name
        setup.show()
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
        let (symbol, text): (String, String) = switch state {
        case .failed(let message): ("exclamationmark.triangle", message)
        case _ where !hasAccessibility: ("lock", "Allow Utter in System Settings → Privacy & Security → \(TextInjector.permissionName)")
        case .loading(let message): ("arrow.down.circle", message)
        case .ready: ("waveform", "Ready — hold \(trigger) to dictate, double-tap for hands-free")
        case .recording(handsFree: false): ("waveform", "Listening…")
        case .recording(handsFree: true): ("waveform", "Hands-free — tap \(trigger) to finish, Esc to cancel")
        case .transcribing: ("ellipsis", "Transcribing…")
        }
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Utter")
        button.contentTintColor = if case .recording = state { .systemRed } else { nil }
        statusLine.title = text
    }
}
