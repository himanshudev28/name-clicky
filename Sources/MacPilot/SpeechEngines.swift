import AVFoundation
import Foundation
import Security

/// Which engine produces the final transcript. Apple always shows live words while you talk.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case apple, whisperLocal, groq
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple (built-in)"
        case .whisperLocal: return "Whisper on this Mac (whisper.cpp, offline)"
        case .groq: return "Groq Whisper (cloud, needs API key)"
        }
    }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case auto, en, hi
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .hi: return "Hindi"
        }
    }
}

/// Words that help Whisper spell app and setting names correctly.
private let vocabularyPrompt = "MacPilot, Mac, Finder, Safari, Chrome, YouTube, Bluetooth, Wi-Fi, AirDrop, System Settings, Spotlight, Dock, Do Not Disturb."

// MARK: - Recording

/// Collects microphone audio as 16 kHz mono samples (what Whisper expects).
/// Fed from the realtime audio thread, so it uses a lock instead of an actor.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func reset(inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        converter = AVAudioConverter(from: inputFormat, to: outFormat)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock(); samples += chunk; lock.unlock()
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16_000
    }

    /// 16-bit PCM WAV file data.
    func wavData() -> Data {
        lock.lock(); let s = samples; lock.unlock()
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(s.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        data.reserveCapacity(data.count + s.count * 2)
        for v in s {
            let i = Int16(max(-1, min(1, v)) * Float(Int16.max))
            withUnsafeBytes(of: i.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - Local whisper.cpp

/// Keeps a `whisper-server` (Homebrew whisper-cpp) running with the model loaded,
/// so each command transcribes in under a second.
@MainActor
final class WhisperLocal {
    static let shared = WhisperLocal()
    private var process: Process?
    private var port = 18733
    private var loadedModel = ""

    nonisolated static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/Models", isDirectory: true)
    }

    nonisolated static var serverBinary: String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Largest-quality model present wins: large > medium > small > base > tiny.
    nonisolated static var modelPath: String? {
        // The model picked in Settings › Voice › Voice models, if it's downloaded.
        if let chosen = VoiceModelStore.selectedWhisperModelPath { return chosen }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsFolder.path)) ?? []
        let models = files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
        let order = ["large", "medium", "small", "base", "tiny"]
        let best = models.min { a, b in
            (order.firstIndex { a.contains($0) } ?? 99) < (order.firstIndex { b.contains($0) } ?? 99)
        }
        return best.map { modelsFolder.appendingPathComponent($0).path }
    }

    nonisolated static var statusText: String {
        guard serverBinary != nil else { return "whisper.cpp not installed. In Terminal: brew install whisper-cpp" }
        guard let m = modelPath else { return "No model in \(modelsFolder.path)" }
        return "Ready · \((m as NSString).lastPathComponent)"
    }

    /// Starts the server in the background (no-op if already running with this model).
    func prepare() {
        guard let bin = Self.serverBinary, let model = Self.modelPath else { return }
        if let p = process, p.isRunning, loadedModel == model { return }
        stop()
        // A server left over from an earlier MacPilot run (e.g. after a crash) holds our port: end it.
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        old.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? old.run(); old.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port),
                       "-nt", "-t", "4", "--prompt", vocabularyPrompt]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p
        loadedModel = model
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }
    var pid: Int32? { isRunning ? process?.processIdentifier : nil }

    func transcribe(_ wav: Data, language: SpeechLanguage) async throws -> String {
        prepare()
        let url = URL(string: "http://127.0.0.1:\(port)/inference")!
        var lastError: Error = URLError(.cannotConnectToHost)
        // The server may still be loading the model right after launch: retry briefly.
        for attempt in 0..<12 {
            do {
                let fields = ["response_format": "json", "language": language.rawValue, "temperature": "0"]
                let text = try await postMultipart(url: url, wav: wav, fields: fields, auth: nil, timeout: 15)
                return text
            } catch {
                lastError = error
                if attempt < 11 { try await Task.sleep(nanoseconds: 250_000_000) }
            }
        }
        throw lastError
    }
}

// MARK: - Groq

enum GroqWhisper {
    static func transcribe(_ wav: Data, language: SpeechLanguage) async throws -> String {
        guard let key = Keychain.groqKey, !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var fields = ["model": "whisper-large-v3-turbo", "response_format": "json",
                      "temperature": "0", "prompt": vocabularyPrompt]
        if language != .auto { fields["language"] = language.rawValue }
        return try await postMultipart(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
                                       wav: wav, fields: fields, auth: "Bearer \(key)", timeout: 15)
    }
}

/// POSTs a WAV as multipart/form-data and returns the "text" field of the JSON reply.
private func postMultipart(url: URL, wav: Data, fields: [String: String], auth: String?, timeout: TimeInterval) async throws -> String {
    let boundary = "MacPilot-\(UUID().uuidString)"
    var body = Data()
    func add(_ s: String) { body.append(Data(s.utf8)) }
    for (k, v) in fields {
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
    }
    add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
    body.append(wav)
    add("\r\n--\(boundary)--\r\n")

    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
    req.httpBody = body

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Keychain (for the Groq API key)

enum Keychain {
    private static let service = "com.macpilot.app.groq"

    static var groqKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
