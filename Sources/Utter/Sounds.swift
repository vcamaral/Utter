import AppKit

/// Soft start/stop cues, so you know it's listening even with the indicator off.
@MainActor
enum Sounds {
    private static let start = load("Tink")
    private static let stop = load("Pop")

    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func load(_ name: String) -> NSSound? {
        let sound = NSSound(named: name)?.copy() as? NSSound
        sound?.volume = 0.3
        return sound
    }

    private static func play(_ sound: NSSound?) {
        sound?.stop()
        sound?.play()
    }
}
