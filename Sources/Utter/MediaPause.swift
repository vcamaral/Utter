import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// Pauses whatever is playing while you dictate, and resumes it afterwards.
///
/// macOS has no public API for this, so it combines two pieces:
/// - MediaRemote's `MRMediaRemoteSendCommand` (private framework) sends explicit pause/play.
///   Explicit, never the play/pause toggle: a toggle sent with nothing playing would start music.
/// - CoreAudio's per-process `kAudioProcessPropertyIsRunningOutput` (public, macOS 14.2+) tells which
///   apps are putting out sound. MediaRemote's own "is playing" check is locked for third-party apps.
///
/// Pause goes to the Now Playing app, which may not be the app making sound: a Slack notification
/// with Spotify already paused. Pausing then is harmless, but resuming would start Spotify. So only
/// apps that have been putting out sound for a while count as paused; short sounds are notifications.
@MainActor
final class MediaPause {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()
    private static let play: UInt32 = 0    // kMRPlay
    private static let pause: UInt32 = 1   // kMRPause

    /// Players release the audio output a while after pausing (Spotify takes ~2.3 s).
    private static let quietTimeout: Duration = .seconds(4)
    /// Apps keep their output running for a while after a notification sound (Slack, ~10 s).
    private static let notificationLength: TimeInterval = 15

    /// Apps that were playing when this paused them; empty when nothing is paused.
    private var pausedApps: Set<pid_t> = []
    /// Bumped on every start/end, so a resume overtaken by a new recording gives up.
    private var generation = 0

    func recordingStarted() {
        generation += 1
        guard pausedApps.isEmpty else { return }   // still paused from the previous dictation
        let playing = Self.appsPlayingAudio()
        guard !playing.isEmpty, Self.sendCommand?(Self.pause, nil) == true else { return }
        let started = Self.outputStartDates()
        let settled = Date.now.addingTimeInterval(-Self.notificationLength)
        // No start date (macOS stopped reporting it): count the app, so resuming still works.
        pausedApps = playing.filter { (started[$0] ?? .distantPast) <= settled }
    }

    func recordingEnded() {
        generation += 1
        guard !pausedApps.isEmpty else { return }
        let current = generation
        Task {
            // Resume only once a paused app went quiet. If none did, the pause never reached them
            // (e.g. a call keeps its audio going), and play would start something nobody was hearing.
            let deadline = ContinuousClock.now + Self.quietTimeout
            while ContinuousClock.now < deadline {
                guard current == generation else { return }
                if !pausedApps.isSubset(of: Self.appsPlayingAudio()) {
                    _ = Self.sendCommand?(Self.play, nil)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            pausedApps = []
        }
    }

    // MARK: - CoreAudio

    private static func appsPlayingAudio() -> Set<pid_t> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        var playing = Set<pid_t>()
        for process in processes where read(kAudioProcessPropertyIsRunningOutput, of: process) == 1 {
            if let pid = read(kAudioProcessPropertyPID, of: process), pid_t(pid) != getpid() {
                playing.insert(pid_t(pid))
            }
        }
        return playing
    }

    /// Since when each app has been putting out sound. CoreAudio holds a power assertion on behalf
    /// of every app whose output is running, and IOKit says when it was taken.
    private static func outputStartDates() -> [pid_t: Date] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let assertions = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [:] }
        var started: [pid_t: Date] = [:]
        for assertion in assertions.values.joined() {
            guard let resources = assertion["ResourcesUsed"] as? [String], resources.contains("audio-out"),
                  let pid = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                  let date = assertion["AssertStartWhen"] as? Date
            else { continue }
            started[pid] = min(date, started[pid] ?? date)
        }
        return started
    }

    private static func read(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
