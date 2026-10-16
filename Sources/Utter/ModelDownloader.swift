import CryptoKit
import Foundation

enum ModelError: LocalizedError {
    case badResponse(Int)
    case corrupted

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "The download server answered \(status)"
        case .corrupted: "The downloaded model is damaged. Try again."
        }
    }
}

/// A Whisper model file: downloaded once from Hugging Face and checked before it's used.
struct ModelFile: Sendable {
    let name: String
    let size: Int64
    let sha256: String

    /// Whisper large-v3 turbo, 5-bit quantized: near full accuracy at a third of the size. Does the transcription.
    static let transcription = ModelFile(
        name: "ggml-large-v3-turbo-q5_0.bin", size: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    /// Whisper tiny: tells the language in ~35 ms, which the large model would take a second and a half for.
    static let languageDetection = ModelFile(
        name: "ggml-tiny-q5_1.bin", size: 32_152_673,
        sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7")

    static let all = [transcription, languageDetection]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utter/models", isDirectory: true)
    }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)")! }
    var path: String { Self.folder.appendingPathComponent(name).path }

    /// A complete file is only ever moved into place after its checksum matched, so the size is enough here.
    var isInstalled: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? Int64) == size
    }

    /// Downloads every missing model, reporting the progress of all of them together.
    static func downloadMissing(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let missing = all.filter { !$0.isInstalled }
        let total = Double(missing.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for model in missing {
            let before = done
            try await model.download { fraction in
                onProgress((Double(before) + fraction * Double(model.size)) / total)
            }
            done += model.size
        }
    }

    private func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let final = URL(fileURLWithPath: path)
        let partial = final.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        try await Downloader().download(url, to: partial, onProgress: onProgress)

        guard try await Self.checksum(of: partial) == sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelError.corrupted
        }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
    }

    private static func checksum(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// A download task with progress reporting.
private final class Downloader: @unchecked Sendable {
    private var observation: NSKeyValueObservation?

    func download(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
                self?.observation = nil
                if let error { return continuation.resume(throwing: error) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let location else { return continuation.resume(throwing: ModelError.badResponse(status)) }
                // The temporary file is deleted when this handler returns, so move it now.
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
            task.resume()
        }
    }
}
