import Foundation

/// Audio that keeps growing while a dictation goes on: the microphone, or a file in tests.
protocol GrowingAudio: AnyObject {
    var sampleCount: Int { get }
    func samples(from index: Int) -> [Float]
}

/// Transcribes a dictation in parts while you're still speaking, so finishing a long one only waits
/// for its last part (about a second) instead of all of it.
///
/// Every time enough audio piles up, it cuts at the quietest moment (a pause between words) and
/// transcribes that part in the background. Each part gets the text before it as context, so
/// punctuation and capitals carry on, and reuses the language detected in the first one.
@MainActor
final class LiveTranscription {
    private static let sampleRate = 16_000
    /// Pending audio that triggers a part. Whisper handles up to 30 s in one go.
    private static let partTrigger = 24 * sampleRate
    /// The cut goes at the quietest 200 ms between these points of the pending audio.
    private static let earliestCut = 14 * sampleRate
    private static let quietWindow = sampleRate / 5
    /// Enough previous text to set the tone, short of Whisper's prompt limit.
    private static let promptCharacters = 200

    private let audio: GrowingAudio
    private let transcriber: Transcriber
    private var loop: Task<Void, Never>?
    private var parts: [String] = []
    private var transcribedUpTo = 0
    private var language: String?

    init(audio: GrowingAudio, transcriber: Transcriber) {
        self.audio = audio
        self.transcriber = transcriber
    }

    func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await transcribePartIfReady()
            }
        }
    }

    /// Transcribes what's left of `samples` (the whole recording) and returns the full text.
    func finish(with samples: [Float]) async throws -> String {
        loop?.cancel()
        await loop?.value   // lets a part already in progress land first
        let rest = transcribedUpTo < samples.count ? Array(samples[transcribedUpTo...]) : []
        let last = try await transcriber.transcribe(rest, language: language, prompt: prompt)
        if parts.count > 0 {
            logger.notice("dictation finished: \(self.parts.count, privacy: .public) parts transcribed while recording")
        }
        return (parts + [last.text]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func cancel() {
        loop?.cancel()
    }

    // MARK: - Private

    private var prompt: String? {
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : String(text.suffix(Self.promptCharacters))
    }

    private func transcribePartIfReady() async {
        guard audio.sampleCount - transcribedUpTo >= Self.partTrigger else { return }
        let pending = audio.samples(from: transcribedUpTo)
        let cut = Self.quietestPoint(in: pending)
        do {
            let part = try await transcriber.transcribe(Array(pending[..<cut]), language: language, prompt: prompt)
            if !part.text.isEmpty { parts.append(part.text) }
            language = language ?? part.language
            transcribedUpTo += cut
        } catch {
            // Leave this audio for the final pass, which reports the error if it happens again.
            logger.error("part transcription failed: \(error.localizedDescription, privacy: .public)")
            loop?.cancel()
        }
    }

    /// Middle of the quietest 200 ms between `earliestCut` and `partTrigger`: most likely a pause,
    /// so the cut doesn't split a word.
    private static func quietestPoint(in samples: [Float]) -> Int {
        let end = min(samples.count, partTrigger)
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        for start in stride(from: earliestCut, to: end - quietWindow, by: quietWindow / 2) {
            let energy = samples[start..<start + quietWindow].reduce(Float(0)) { $0 + $1 * $1 }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + quietWindow / 2
            }
        }
        return best
    }
}
