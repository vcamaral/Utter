# Utter

Local voice dictation for macOS. Hold **Right ⌘**, speak, release, and the text is pasted where your cursor is.

Transcription runs on your Mac with Whisper large-v3 turbo (via [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
on the GPU). No account, no API key, no cost. The only network access is the one-time model download
from Hugging Face (~600 MB). The language is detected on every dictation.

## Install

```bash
cd ~/Code/utter
./build.sh install
```

On first launch a setup window walks you through the **Microphone** and **Accessibility** permissions (Accessibility
is needed to see the dictation key in other apps and to paste) while the model downloads. Once downloaded, it loads in
a couple of seconds.

Requires macOS 14+, Apple Silicon, Apple's Command Line Tools and `cmake` (`brew install cmake`). Xcode is not needed.
The first build compiles whisper.cpp into `vendor/` (about 15 seconds); it's linked statically, so the app doesn't
depend on Homebrew.

## Usage

- Hold **Right ⌘** to record, release to transcribe and paste.
- Double-tap the key to dictate hands-free; tap it again to finish, or press Esc to cancel.
- Taps shorter than 0.3 s are ignored, and pressing another key while holding the dictation key cancels (so ⌘ shortcuts still work).
- Your clipboard is restored after pasting.
- If there is nowhere to paste, the text is left on the clipboard and Utter tells you to press ⌘V.

## Layout

| File | Role |
|---|---|
| `PushToTalk.swift` | Global hold/double-tap detection of the dictation key |
| `AudioRecorder.swift` | Microphone capture, resampled to 16 kHz mono |
| `Transcriber.swift` | Language detection and Whisper transcription (whisper.cpp) |
| `ModelDownloader.swift` | One-time model download, checked against its SHA-256 |
| `TextInjector.swift` | Paste into the frontmost app, restore the clipboard |
| `MediaPause.swift` | Pause music while dictating, resume after |
| `RecordingOverlay.swift` | Floating waveform while recording |
| `SetupWindow.swift` | First-run permissions and download |
| `AppDelegate.swift` | Menu bar UI and wiring |

Models live in `~/Library/Application Support/Utter`.
