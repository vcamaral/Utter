import AVFoundation

enum RecorderError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "No microphone available" }
}

/// Captures the microphone as 16 kHz mono samples, the format Whisper expects.
/// The engine only runs while recording, so the mic indicator is off the rest of the time.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevel: Float = 0
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var isAuthorized: Bool { authorizationStatus == .authorized }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// RMS of the most recent audio buffer, for the waveform.
    var level: Float { lock.withLock { lastLevel } }

    /// Sets up the input unit ahead of time, the slow part of the first start, so the microphone
    /// switches on sooner when the key is pressed. Doesn't switch the microphone on by itself.
    func warmUp() {
        guard Self.isAuthorized else { return }
        _ = engine.inputNode
        engine.prepare()
    }

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            lastLevel = 0
        }

        // Read the format on every start: the input device may have changed (AirPods, external mic).
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { throw RecorderError.noMicrophone }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.prepare()   // ready for the next dictation
        return lock.withLock { samples }
    }

    // Runs on the audio thread.
    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow   // keep the resampler state for the next buffer
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return }

        let chunk = UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
        let rms = chunk.isEmpty ? 0 : (chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        lock.withLock {
            samples.append(contentsOf: chunk)
            lastLevel = rms
        }
    }
}
