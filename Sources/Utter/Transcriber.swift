import CWhisper
import Foundation

enum TranscriberError: LocalizedError {
    case notReady
    case loadFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .notReady: "The model is not loaded yet"
        case .loadFailed: "The model couldn't be loaded"
        case .transcriptionFailed: "Whisper couldn't transcribe the audio"
        }
    }
}

/// Runs Whisper locally through whisper.cpp, on the GPU (Metal).
/// whisper.cpp calls block for a while, so they run on a dedicated queue, one at a time.
final class Transcriber: @unchecked Sendable {
    private static let sampleRate = 16_000
    private static let minimumDuration = 0.3   // seconds
    /// Loudness (RMS) the loudest 100 ms must reach to count as speech, about -46 dBFS.
    private static let silenceRMS: Float = 0.005

    /// Whisper's own rule for "this segment is not speech": likely silence and low confidence.
    private static let noSpeechProbability: Float = 0.6
    private static let lowConfidenceLogprob: Float = -1.0

    /// Subtitle credits Whisper learned from its training data and sometimes writes over noise.
    /// Only phrases nobody would dictate; anything ordinary is left to the confidence check above.
    private static let subtitleCredits = ["amara.org", "legendas pela comunidade", "thanks for watching", "obrigado por assistir"]

    /// Above this, the tiny model's language guess is trusted as is.
    private static let confidentLanguage: Float = 0.8
    /// When unsure, a language you dictated in before still wins if it's at least this likely.
    private static let plausibleLanguage: Float = 0.2
    private static let knownLanguagesKey = "knownLanguages"

    private let queue = DispatchQueue(label: "utter.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private var detector: OpaquePointer?

    /// Downloads the models if needed (~600 MB, once), then loads them, which takes a second or two.
    func prepare(onDownloadProgress: @escaping @Sendable (Double) -> Void,
                 onLoading: @escaping @Sendable () -> Void) async throws {
        try await ModelFile.downloadMissing(onProgress: onDownloadProgress)
        onLoading()
        try await run {
            whisper_log_set({ _, _, _ in }, nil)   // whisper.cpp logs a lot to stderr
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let context = whisper_init_from_file_with_params(ModelFile.transcription.path, params),
                  let detector = whisper_init_from_file_with_params(ModelFile.languageDetection.path, params)
            else { throw TranscriberError.loadFailed }
            self.context = context
            self.detector = detector
            // One pass over a second of silence sets up the GPU pipelines, so the first real dictation is quick.
            _ = try? self.decode([Float](repeating: 0, count: Self.sampleRate), language: "en", with: context)
        }
    }

    /// Frees the models. whisper.cpp aborts if the process exits while they're still loaded on the GPU.
    func shutdown() {
        queue.sync {
            if let context { whisper_free(context) }
            if let detector { whisper_free(detector) }
            context = nil
            detector = nil
        }
    }

    /// Returns the transcribed text, or an empty string when there is nothing worth pasting.
    /// The language is detected on every dictation, so you can switch freely between them.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard Double(samples.count) / Double(Self.sampleRate) >= Self.minimumDuration,
              Self.loudestWindowRMS(samples) >= Self.silenceRMS
        else { return "" }

        return try await run {
            guard let context = self.context, let detector = self.detector else { throw TranscriberError.notReady }
            return try self.decode(samples, language: self.detectLanguage(samples, with: detector), with: context)
        }
    }

    // MARK: - Private

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Guesses the language with the tiny model, so the large one encodes the audio once instead of twice.
    /// Returns `nil` when the guess is too shaky; the large model then detects it itself.
    /// Runs on `queue`.
    private func detectLanguage(_ samples: [Float], with detector: OpaquePointer) -> String? {
        let threads = Int32(4)
        guard whisper_pcm_to_mel(detector, samples, Int32(samples.count), threads) == 0 else { return nil }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(detector, 0, threads, &probabilities) >= 0 else { return nil }
        let ranked = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
            .map { (code: String(cString: whisper_lang_str(Int32($0))), probability: probabilities[$0]) }

        var known = Set(UserDefaults.standard.stringArray(forKey: Self.knownLanguagesKey) ?? [])
        if let best = ranked.first, best.probability >= Self.confidentLanguage {
            if known.insert(best.code).inserted {
                UserDefaults.standard.set(Array(known), forKey: Self.knownLanguagesKey)
            }
            return best.code
        }
        // Unsure, typical of short phrases: prefer a language you're known to dictate in.
        return ranked.first { known.contains($0.code) && $0.probability >= Self.plausibleLanguage }?.code
    }

    // Runs on `queue`.
    private func decode(_ samples: [Float], language: String?, with context: OpaquePointer) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.no_context = true
        params.no_timestamps = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false

        let status = (language ?? "auto").withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw TranscriberError.transcriptionFailed }

        let endOfText = whisper_token_eot(context)
        var kept: [String] = []
        for segment in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, segment))
            let noSpeech = whisper_full_get_segment_no_speech_prob(context, segment)
            let logprobs = (0..<whisper_full_n_tokens(context, segment))
                .filter { whisper_full_get_token_id(context, segment, $0) < endOfText }   // skip special tokens
                .map { log(max(whisper_full_get_token_p(context, segment, $0), 1e-6)) }
            let averageLogprob = logprobs.isEmpty ? -10 : logprobs.reduce(0, +) / Float(logprobs.count)

            let isSilence = noSpeech > Self.noSpeechProbability && averageLogprob < Self.lowConfidenceLogprob
            let isCredits = Self.subtitleCredits.contains { text.lowercased().contains($0) }
            if !isSilence, !isCredits { kept.append(text) }
        }
        return kept.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// RMS of the loudest 100 ms. The whole recording's RMS would call a long hands-free dictation
    /// with a single short sentence "silence".
    private static func loudestWindowRMS(_ samples: [Float]) -> Float {
        let window = sampleRate / 10
        return stride(from: 0, to: samples.count, by: window).map { start in
            let chunk = samples[start..<min(start + window, samples.count)]
            return (chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }.max() ?? 0
    }
}
