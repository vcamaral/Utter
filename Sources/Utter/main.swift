import AppKit
import Foundation

// whisper.cpp's Metal backend otherwise keeps a thread waking every 5 ms, forever, to hold GPU memory
// resident: ~50 wakeups a second while Utter just waits for a key. Without it, the first dictation after
// a long idle may page the model back in, which costs far less than the constant drain.
setenv("GGML_METAL_NO_RESIDENCY", "1", 1)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
