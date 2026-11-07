import SwiftUI
import AVFoundation
import Foundation

// Request shapes follow each provider's public docs as of writing. Items marked
// "UNVERIFIED" could not be confirmed against a live account (no keys available).

// MARK: - Shared helpers

enum VoiceAPIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

private enum Net {
    static func send(_ req: URLRequest, timeout: TimeInterval = 30) async throws -> Data {
        var r = req
        r.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw VoiceAPIError.message("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceAPIError.message("HTTP \(http.statusCode): \(errorText(data))")
        }
        return data
    }

    /// Pulls the provider's message out of common error JSON shapes.
    static func errorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
            if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }
            if let d = obj["detail"] as? String { return d }
            if let m = obj["message"] as? String { return m }
            if let m = obj["err_msg"] as? String { return m }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceAPIError.message("Unexpected response: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return o
    }

    static func multipart(url: URL, headers: [String: String], fields: [String: String],
                          fileField: String, wav: Data) -> URLRequest {
        let boundary = "macpilot-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    static func jsonRequest(url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Joins a user base URL ("https://host/v1" or with trailing slash) and a path.
    static func join(_ base: String?, _ path: String, fallback: String) throws -> URL {
        var b = (base ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { b = fallback }
        while b.hasSuffix("/") { b.removeLast() }
        guard let u = URL(string: b + path) else { throw VoiceAPIError.message("Invalid base URL: \(b)") }
        return u
    }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

// MARK: - Speech-to-text

enum CloudSTTProvider: String, CaseIterable, Identifiable {
    case openai, groq, deepgram, elevenlabs, sarvam, assemblyai, customOpenAI
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq (Whisper)"
        case .deepgram: return "Deepgram"
        case .elevenlabs: return "ElevenLabs (Scribe)"
        case .sarvam: return "Sarvam (good for Hinglish)"
        case .assemblyai: return "AssemblyAI"
        case .customOpenAI: return "Custom (OpenAI-compatible)"
        }
    }
    var keyAccount: String { "stt.\(rawValue)" }
    var keyURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .sarvam: return URL(string: "https://dashboard.sarvam.ai/")!
        case .assemblyai: return URL(string: "https://www.assemblyai.com/dashboard/api-keys")!
        case .customOpenAI: return URL(string: "https://platform.openai.com/docs/api-reference/audio/createTranscription")!
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .deepgram: return "nova-3"
        case .elevenlabs: return "scribe_v1"
        case .sarvam: return "saarika:v2.5"
        case .assemblyai: return "universal"
        case .customOpenAI: return "whisper-1"
        }
    }
    var usesModel: Bool { self != .assemblyai }   // AssemblyAI: model not sent (see transcribe)
    var usesBaseURL: Bool { self == .customOpenAI }
    var baseURLPlaceholder: String { "https://your-host/v1" }

    var apiKey: String? { SecretStore.get(keyAccount) }

    /// Provider chosen in Settings ("" = none).
    static var selected: CloudSTTProvider? {
        CloudSTTProvider(rawValue: UserDefaults.standard.string(forKey: "cloudSTTProvider") ?? "")
    }

    /// Transcribes with the provider and model/base URL saved in Settings; nil when none is configured.
    static func transcribeWithSavedSettings(wav: Data, language: SpeechLanguage) async throws -> String? {
        guard let p = selected, p.apiKey != nil else { return nil }
        let d = UserDefaults.standard
        return try await transcribe(wav: wav, provider: p, language: language,
                                    model: d.string(forKey: "cloudSTTModel.\(p.rawValue)"),
                                    baseURL: d.string(forKey: "cloudBaseURL.stt.\(p.rawValue)"))
    }

    static func transcribe(wav: Data, provider: CloudSTTProvider, language: SpeechLanguage,
                           model: String?, baseURL: String?) async throws -> String {
        guard let key = provider.apiKey else { throw VoiceAPIError.message("No API key saved for \(provider.label).") }
        let model = nonEmpty(model) ?? provider.defaultModel
        let lang2: String? = language == .auto ? nil : language.rawValue   // "en" / "hi"

        switch provider {
        case .openai, .groq, .customOpenAI:
            let fallback = provider == .openai ? "https://api.openai.com/v1" : "https://api.groq.com/openai/v1"
            let url = provider == .customOpenAI
                ? try Net.join(baseURL, "/audio/transcriptions", fallback: "")
                : try Net.join(nil, "/audio/transcriptions", fallback: fallback)
            var fields = ["model": model, "response_format": "json", "temperature": "0"]
            if let l = lang2 { fields["language"] = l }
            let req = Net.multipart(url: url, headers: ["Authorization": "Bearer \(key)"], fields: fields,
                                    fileField: "file", wav: wav)
            let o = try Net.json(try await Net.send(req))
            return (o["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        case .deepgram:
            var c = URLComponents(string: "https://api.deepgram.com/v1/listen")!
            var q = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "smart_format", value: "true")]
            if let l = lang2 { q.append(URLQueryItem(name: "language", value: l)) }
            else { q.append(URLQueryItem(name: "detect_language", value: "true")) }
            c.queryItems = q
            var req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            req.httpBody = wav
            let o = try Net.json(try await Net.send(req))
            let results = o["results"] as? [String: Any]
            let ch = (results?["channels"] as? [[String: Any]])?.first
            let alt = (ch?["alternatives"] as? [[String: Any]])?.first
            return (alt?["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        case .elevenlabs:
            var fields = ["model_id": model]
            if let l = lang2 { fields["language_code"] = l }   // UNVERIFIED: ISO 639-1 accepted
            let req = Net.multipart(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
                                    headers: ["xi-api-key": key], fields: fields, fileField: "file", wav: wav)
            let o = try Net.json(try await Net.send(req))
            return (o["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        case .sarvam:
            let code: String = { switch language { case .auto: return "unknown"; case .en: return "en-IN"; case .hi: return "hi-IN" } }()
            let req = Net.multipart(url: URL(string: "https://api.sarvam.ai/speech-to-text")!,
                                    headers: ["api-subscription-key": key],
                                    fields: ["model": model, "language_code": code], fileField: "file", wav: wav)
            let o = try Net.json(try await Net.send(req))
            return (o["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        case .assemblyai:
            var up = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
            up.httpMethod = "POST"
            up.setValue(key, forHTTPHeaderField: "Authorization")
            up.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            up.httpBody = wav
            let uploaded = try Net.json(try await Net.send(up))
            guard let audioURL = uploaded["upload_url"] as? String else { throw VoiceAPIError.message("AssemblyAI upload returned no upload_url.") }
            var body: [String: Any] = ["audio_url": audioURL]
            if let l = lang2 { body["language_code"] = l } else { body["language_detection"] = true }
            // The task asked for speech_model "universal"; AssemblyAI has been renaming this field
            // (speech_model -> speech_models), so we omit it and use the account default. UNVERIFIED.
            let create = try Net.jsonRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!,
                                             headers: ["Authorization": key], body: body)
            let made = try Net.json(try await Net.send(create))
            guard let id = made["id"] as? String else { throw VoiceAPIError.message("AssemblyAI returned no transcript id.") }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 300_000_000)
                var get = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(id)")!)
                get.setValue(key, forHTTPHeaderField: "Authorization")
                let o = try Net.json(try await Net.send(get))
                switch o["status"] as? String {
                case "completed": return (o["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                case "error": throw VoiceAPIError.message("AssemblyAI: \(o["error"] as? String ?? "transcription failed")")
                default: continue
                }
            }
            throw VoiceAPIError.message("AssemblyAI timed out after 30 s.")
        }
    }

    /// One second of 16 kHz mono 16-bit silence, for the Test button.
    static func silentWAV(seconds: Double = 1) -> Data {
        let rate = 16000, n = Int(Double(rate) * seconds), dataLen = n * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + dataLen); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataLen)
        d.append(Data(count: dataLen))
        return d
    }
}

// MARK: - Text-to-speech

enum CloudTTSProvider: String, CaseIterable, Identifiable {
    case openai, elevenlabs, deepgram, cartesia, sarvam, customOpenAI
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .elevenlabs: return "ElevenLabs"
        case .deepgram: return "Deepgram (Aura)"
        case .cartesia: return "Cartesia (Sonic)"
        case .sarvam: return "Sarvam (Bulbul, Indian languages)"
        case .customOpenAI: return "Custom (OpenAI-compatible)"
        }
    }
    var keyAccount: String { "tts.\(rawValue)" }
    var keyURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        case .cartesia: return URL(string: "https://play.cartesia.ai/keys")!
        case .sarvam: return URL(string: "https://dashboard.sarvam.ai/")!
        case .customOpenAI: return URL(string: "https://platform.openai.com/docs/api-reference/audio/createSpeech")!
        }
    }
    /// ElevenLabs/Cartesia: a voice id. Deepgram: the Aura model doubles as the voice. Sarvam: speaker name.
    var defaultVoice: String {
        switch self {
        case .openai: return "nova"
        case .elevenlabs: return "21m00Tcm4TlvDq8ikWAM"            // "Rachel" stock voice
        case .deepgram: return "aura-2-thalia-en"
        case .cartesia: return "694f9389-aac1-45b6-b726-9d9369183238" // stock voice id from Cartesia docs. UNVERIFIED
        case .sarvam: return "anushka"                                // UNVERIFIED speaker name for bulbul:v2
        case .customOpenAI: return "alloy"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini-tts"
        case .elevenlabs: return "eleven_flash_v2_5"
        case .deepgram: return ""        // model comes from the voice field
        case .cartesia: return "sonic-2"
        case .sarvam: return "bulbul:v2"
        case .customOpenAI: return "tts-1"
        }
    }
    var voiceLabel: String {
        switch self {
        case .elevenlabs, .cartesia: return "Voice ID"
        case .deepgram: return "Voice (Aura model)"
        default: return "Voice"
        }
    }
    var usesModel: Bool { self != .deepgram }
    var usesBaseURL: Bool { self == .customOpenAI }
    var apiKey: String? { SecretStore.get(keyAccount) }

    static var selected: CloudTTSProvider? {
        CloudTTSProvider(rawValue: UserDefaults.standard.string(forKey: "cloudTTSProvider") ?? "")
    }

    /// Fetches the audio (mp3, or wav for Sarvam).
    static func fetchAudio(_ text: String, provider: CloudTTSProvider, voice: String?, model: String?,
                           baseURL: String?) async throws -> Data {
        guard let key = provider.apiKey else { throw VoiceAPIError.message("No API key saved for \(provider.label).") }
        let voice = nonEmpty(voice) ?? provider.defaultVoice
        let model = nonEmpty(model) ?? provider.defaultModel

        switch provider {
        case .openai, .customOpenAI:
            let url = provider == .customOpenAI
                ? try Net.join(baseURL, "/audio/speech", fallback: "")
                : URL(string: "https://api.openai.com/v1/audio/speech")!
            let req = try Net.jsonRequest(url: url, headers: ["Authorization": "Bearer \(key)"],
                                          body: ["model": model, "voice": voice, "input": text, "response_format": "mp3"])
            return try await Net.send(req, timeout: 60)

        case .elevenlabs:
            let id = voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voice
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)?output_format=mp3_44100_128")!
            let req = try Net.jsonRequest(url: url, headers: ["xi-api-key": key],
                                          body: ["text": text, "model_id": model])
            return try await Net.send(req, timeout: 60)

        case .deepgram:
            var c = URLComponents(string: "https://api.deepgram.com/v1/speak")!
            c.queryItems = [URLQueryItem(name: "model", value: voice), URLQueryItem(name: "encoding", value: "mp3")]
            let req = try Net.jsonRequest(url: c.url!, headers: ["Authorization": "Token \(key)"], body: ["text": text])
            return try await Net.send(req, timeout: 60)

        case .cartesia:
            let body: [String: Any] = [
                "model_id": model, "transcript": text,
                "voice": ["mode": "id", "id": voice],
                "output_format": ["container": "mp3", "sample_rate": 44100, "bit_rate": 128000],
            ]
            let req = try Net.jsonRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!,
                                          headers: ["X-API-Key": key, "Cartesia-Version": "2025-04-16"], body: body)
            return try await Net.send(req, timeout: 60)

        case .sarvam:
            // Devanagari text -> Hindi, otherwise Indian English.
            let hindi = text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
            let body: [String: Any] = ["text": text, "target_language_code": hindi ? "hi-IN" : "en-IN",
                                       "speaker": voice, "model": model]
            let req = try Net.jsonRequest(url: URL(string: "https://api.sarvam.ai/text-to-speech")!,
                                          headers: ["api-subscription-key": key], body: body)
            let o = try Net.json(try await Net.send(req, timeout: 60))
            guard let b64 = (o["audios"] as? [String])?.first, let d = Data(base64Encoded: b64) else {
                throw VoiceAPIError.message("Sarvam returned no audio.")
            }
            return d
        }
    }
}

// MARK: - Playback

@MainActor
final class CloudTTS: NSObject, AVAudioPlayerDelegate {
    static let shared = CloudTTS()

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var onFinished: (() -> Void)?
    private var generation = 0

    var isSpeaking: Bool { task != nil || (player?.isPlaying ?? false) }

    func speak(_ text: String, provider: CloudTTSProvider, voice: String?, model: String?, baseURL: String?,
               onFinished: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        stop()
        generation += 1
        let gen = generation
        self.onFinished = onFinished
        task = Task { [weak self] in
            do {
                let audio = try await CloudTTSProvider.fetchAudio(text, provider: provider, voice: voice,
                                                                  model: model, baseURL: baseURL)
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                let p = try AVAudioPlayer(data: audio)
                p.delegate = self
                self.player = p
                self.task = nil
                if !p.play() { throw VoiceAPIError.message("Could not start audio playback.") }
            } catch {
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                self.task = nil; self.player = nil; self.onFinished = nil
                onFailed(error.localizedDescription)
            }
        }
    }

    /// Stops fetching/playing. `onFinished` is not called.
    func stop() {
        generation += 1
        task?.cancel(); task = nil
        player?.delegate = nil
        player?.stop(); player = nil
        onFinished = nil
    }

    /// Speaks using the provider and options saved in Settings. Returns false when none is configured.
    @discardableResult
    func speakWithSavedSettings(_ text: String, onFinished: @escaping () -> Void, onFailed: @escaping (String) -> Void) -> Bool {
        guard let p = CloudTTSProvider.selected, p.apiKey != nil else { return false }
        let d = UserDefaults.standard
        speak(text, provider: p, voice: d.string(forKey: "cloudTTSVoice.\(p.rawValue)"),
              model: d.string(forKey: "cloudTTSModel.\(p.rawValue)"),
              baseURL: d.string(forKey: "cloudBaseURL.tts.\(p.rawValue)"),
              onFinished: onFinished, onFailed: onFailed)
        return true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            let cb = self.onFinished
            self.onFinished = nil
            cb?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            let cb = self.onFinished
            self.onFinished = nil
            cb?()
        }
    }
}

// MARK: - UI

struct VoiceAPIsSection: View {
    @State private var sttRaw = UserDefaults.standard.string(forKey: "cloudSTTProvider") ?? ""
    @State private var ttsRaw = UserDefaults.standard.string(forKey: "cloudTTSProvider") ?? ""
    @State private var sttKey = ""
    @State private var ttsKey = ""
    @State private var sttModel = ""
    @State private var sttBase = ""
    @State private var ttsVoice = ""
    @State private var ttsModel = ""
    @State private var ttsBase = ""
    @State private var sttResult: String?
    @State private var ttsResult: String?
    @State private var sttBusy = false
    @State private var ttsBusy = false

    private var stt: CloudSTTProvider? { CloudSTTProvider(rawValue: sttRaw) }
    private var tts: CloudTTSProvider? { CloudTTSProvider(rawValue: ttsRaw) }
    private let d = UserDefaults.standard

    var body: some View {
        Section {
            Picker("Provider", selection: $sttRaw) {
                Text("None — use local/Apple").tag("")
                ForEach(CloudSTTProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if let p = stt {
                SecureField("API key", text: $sttKey, prompt: Text("Paste your \(p.label) key"))
                if p.usesModel { TextField("Model", text: $sttModel, prompt: Text(p.defaultModel)) }
                if p.usesBaseURL { TextField("Base URL", text: $sttBase, prompt: Text(p.baseURLPlaceholder)) }
                HStack {
                    Link("Get a key", destination: p.keyURL)
                    Spacer()
                    if let r = sttResult { Text(r).font(.caption).foregroundStyle(r.hasPrefix("OK") ? .green : .red).lineLimit(2) }
                    Button(sttBusy ? "Testing…" : "Test") { testSTT(p) }.disabled(sttBusy)
                }
            }
        } header: {
            Text("Speech-to-text API")
        } footer: {
            Text("Your recorded audio is sent to the provider you choose and billed by them. Keys are stored in the macOS Keychain.")
        }
        .onChange(of: sttRaw) { _, v in d.set(v, forKey: "cloudSTTProvider"); loadSTT() }
        .onChange(of: sttKey) { _, v in if let p = stt { SecretStore.set(v, for: p.keyAccount) } }
        .onChange(of: sttModel) { _, v in if let p = stt { d.set(v, forKey: "cloudSTTModel.\(p.rawValue)") } }
        .onChange(of: sttBase) { _, v in if let p = stt { d.set(v, forKey: "cloudBaseURL.stt.\(p.rawValue)") } }

        Section {
            Picker("Provider", selection: $ttsRaw) {
                Text("None — use Kokoro/Apple").tag("")
                ForEach(CloudTTSProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if let p = tts {
                SecureField("API key", text: $ttsKey, prompt: Text("Paste your \(p.label) key"))
                TextField(p.voiceLabel, text: $ttsVoice, prompt: Text(p.defaultVoice))
                if p.usesModel { TextField("Model", text: $ttsModel, prompt: Text(p.defaultModel)) }
                if p.usesBaseURL { TextField("Base URL", text: $ttsBase, prompt: Text("https://your-host/v1")) }
                HStack {
                    Link("Get a key", destination: p.keyURL)
                    Spacer()
                    if let r = ttsResult { Text(r).font(.caption).foregroundStyle(r.hasPrefix("OK") ? .green : .red).lineLimit(2) }
                    Button(ttsBusy ? "Speaking…" : "Test") { testTTS(p) }.disabled(ttsBusy)
                }
            }
        } header: {
            Text("Text-to-speech API")
        } footer: {
            Text("The text MacPilot speaks is sent to the provider you choose and billed by them. Leave on None to stay fully on this Mac.")
        }
        .onChange(of: ttsRaw) { _, v in d.set(v, forKey: "cloudTTSProvider"); loadTTS() }
        .onChange(of: ttsKey) { _, v in if let p = tts { SecretStore.set(v, for: p.keyAccount) } }
        .onChange(of: ttsVoice) { _, v in if let p = tts { d.set(v, forKey: "cloudTTSVoice.\(p.rawValue)") } }
        .onChange(of: ttsModel) { _, v in if let p = tts { d.set(v, forKey: "cloudTTSModel.\(p.rawValue)") } }
        .onChange(of: ttsBase) { _, v in if let p = tts { d.set(v, forKey: "cloudBaseURL.tts.\(p.rawValue)") } }
        .onAppear { loadSTT(); loadTTS() }
    }

    private func loadSTT() {
        sttResult = nil
        guard let p = stt else { sttKey = ""; return }
        sttKey = p.apiKey ?? ""
        sttModel = d.string(forKey: "cloudSTTModel.\(p.rawValue)") ?? ""
        sttBase = d.string(forKey: "cloudBaseURL.stt.\(p.rawValue)") ?? ""
    }

    private func loadTTS() {
        ttsResult = nil
        guard let p = tts else { ttsKey = ""; return }
        ttsKey = p.apiKey ?? ""
        ttsVoice = d.string(forKey: "cloudTTSVoice.\(p.rawValue)") ?? ""
        ttsModel = d.string(forKey: "cloudTTSModel.\(p.rawValue)") ?? ""
        ttsBase = d.string(forKey: "cloudBaseURL.tts.\(p.rawValue)") ?? ""
    }

    private func testSTT(_ p: CloudSTTProvider) {
        sttBusy = true; sttResult = nil
        SecretStore.set(sttKey, for: p.keyAccount)
        let model = sttModel, base = sttBase
        Task {
            do {
                // Silence usually transcribes to empty text; success is "the API accepted the request".
                let t = try await CloudSTTProvider.transcribe(wav: CloudSTTProvider.silentWAV(), provider: p,
                                                              language: .auto, model: model, baseURL: base)
                sttResult = t.isEmpty ? "OK — key accepted" : "OK — \(t.prefix(40))"
            } catch { sttResult = error.localizedDescription }
            sttBusy = false
        }
    }

    private func testTTS(_ p: CloudTTSProvider) {
        ttsBusy = true; ttsResult = nil
        SecretStore.set(ttsKey, for: p.keyAccount)
        CloudTTS.shared.speak("Hi, I'm MacPilot.", provider: p, voice: ttsVoice, model: ttsModel, baseURL: ttsBase,
                              onFinished: { ttsResult = "OK"; ttsBusy = false },
                              onFailed: { ttsResult = $0; ttsBusy = false })
    }
}
