import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum ModelPhase: Equatable {
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    @Published var microphone = AudioRecorder.authorizationStatus
    @Published var accessibility = TextInjector.isTrusted
    @Published var model = ModelPhase.downloading(0)
    @Published var triggerName = ""
    /// Applied when you press Done.
    @Published var launchAtLogin = true

    var onAllowMicrophone: () -> Void = {}
    var onAllowAccessibility: () -> Void = {}
    var onChangeKey: () -> Void = {}
    var onRetry: () -> Void = {}
    var onDone: () -> Void = {}

    var isComplete: Bool { microphone == .authorized && accessibility && model == .ready }
    var hasPermissions: Bool { microphone == .authorized && accessibility }
}

/// First-run window: how to dictate, the two permissions and the model download with live progress,
/// then a box to try it.
@MainActor
final class SetupWindow {
    let model = SetupModel()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Utter"
            // No visible title: the content already says "Welcome to Utter".
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State private var tryText = ""
    @State private var triedIt = false

    private static let downloadMB = Int(ModelFile.all.reduce(0) { $0 + $1.size } / 1_000_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            howTo

            VStack(spacing: 16) {
                StepRow(title: "Microphone", isDone: model.microphone == .authorized) {
                    Text("To hear you while you dictate.")
                } accessory: {
                    Button(model.microphone == .notDetermined ? "Allow" : "Open Settings", action: model.onAllowMicrophone)
                        .prominent(nextStep == .microphone)
                }
                StepRow(title: "Keyboard & paste", isDone: model.accessibility) {
                    Text("Only to notice the dictation key and paste your text. Utter never reads your screen.")
                    if !model.accessibility {
                        Text("In System Settings: “\(TextInjector.permissionName)”.")
                            .foregroundStyle(.tertiary)
                    }
                } accessory: {
                    Button("Allow", action: model.onAllowAccessibility)
                        .prominent(nextStep == .accessibility)
                }
                StepRow(title: "Voice recognition", isDone: model.model == .ready) {
                    Text(modelDetail)
                } accessory: {
                    modelAccessory
                }
            }

            if model.isComplete { tryItBox }
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)   // clears the transparent title bar
        .padding(.bottom, 24)
        .frame(width: 500)
        .animation(.easeOut(duration: 0.2), value: model.isComplete)
        .animation(.easeOut(duration: 0.2), value: triedIt)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Utter").font(.title2.weight(.semibold))
                Text("Dictate anywhere on your Mac. Everything runs on this computer: your voice never leaves it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one thing to learn, up front, with the chance to pick another key before using it.
    private var howTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Hold")
                Keycap(model.triggerName)
                Text("and speak, release to paste.")
                Spacer()
                Button("Change key…", action: model.onChangeKey)
                    .buttonStyle(.link)
            }
            Text("Double-tap it to dictate hands-free; tap again to finish.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private var tryItBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Try it: click the box below, then hold \(model.triggerName) and speak.")
                Spacer()
                if triedIt {
                    Label("It works!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .font(.callout)
            TextField("Your words appear here", text: $tryText, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .onChange(of: tryText) { _, text in
                    if !text.isEmpty { triedIt = true }
                }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let footerText {
                // Menu bar apps have no Dock icon: say where Utter lives, or closing this window looks like quitting.
                Label(footerText, systemImage: "menubar.arrow.up.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isComplete {
                    Toggle("Open Utter when you log in", isOn: $model.launchAtLogin)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button(model.isComplete ? "Done" : "Close", action: model.onDone)
                    .keyboardShortcut(model.isComplete ? .defaultAction : .cancelAction)
            }
        }
    }

    // MARK: - State

    private enum Step { case microphone, accessibility }

    /// The first pending permission: its button is the prominent one.
    private var nextStep: Step? {
        if model.microphone != .authorized { return .microphone }
        if !model.accessibility { return .accessibility }
        return nil
    }

    private var footerText: String? {
        if model.isComplete { return "Utter lives in your menu bar, at the top of the screen." }
        switch model.model {
        case .downloading, .preparing: return "You can close this window: the download keeps going."
        case .ready, .failed: return nil
        }
    }

    private var modelDetail: String {
        switch model.model {
        case .downloading(let progress): "\(Int(progress * Double(Self.downloadMB))) of \(Self.downloadMB) MB · one-time download"
        case .preparing: "Loading…"
        case .ready: "Ready. Works offline from now on."
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private var modelAccessory: some View {
        switch model.model {
        case .downloading(let progress):
            GradientProgress(value: progress).frame(width: 100)
        case .preparing:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Retry", action: model.onRetry)
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Components

private struct StepRow<Detail: View, Accessory: View>: View {
    let title: String
    let isDone: Bool
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isDone ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                VStack(alignment: .leading, spacing: 2, content: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isDone { accessory() }
        }
    }
}

private struct Keycap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.tertiary))
    }
}

/// Progress bar in the app icon's colors.
private struct GradientProgress: View {
    let value: Double

    private static let gradient = LinearGradient(
        colors: [Color(red: 1.00, green: 0.62, blue: 0.36),
                 Color(red: 0.98, green: 0.30, blue: 0.56),
                 Color(red: 0.62, green: 0.36, blue: 1.00)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Self.gradient)
                    .frame(width: max(6, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: value)
    }
}

private extension View {
    @ViewBuilder
    func prominent(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
