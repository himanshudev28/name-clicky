import AVFoundation
import os
import Speech

let voiceLog = Logger(subsystem: "com.macpilot.app", category: "voice")

/// Push-to-talk speech recognition and spoken replies, using Apple's built-in
/// Speech framework and AVSpeechSynthesizer (free, on-device where supported).
@MainActor
final class VoiceController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    /// Live microphone loudness, 0…1, for the waveform animation.
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?
    /// True while Whisper turns the finished recording into text.
    @Published private(set) var isTranscribing = false

    private let settings = AppSettings.shared
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalHandler: ((String) -> Void)?
    private let synth = AVSpeechSynthesizer()
    /// True from the moment a reply starts until it has finished playing.
    @Published private(set) var isSpeaking = false
    private var speakToken = UUID()
    private var speakCompletion: (() -> Void)?
    private let recorder = AudioRecorder()
    private var engineChoice: SpeechEngine { settings.speechEngine }

    // MARK: Listening

    /// Identifies the current listening session so late callbacks from an
    /// earlier one are ignored.
    private var listenToken = UUID()

    func startListening() {
        guard !isListening else { return }
        // Close out a previous session that is still waiting for its final result.
        if finalHandler != nil { deliverFinal() }
        lastError = nil
        stopSpeaking()

        guard Permissions.microphone == .granted else {
            Permissions.requestMicrophone()
            lastError = "Allow microphone access, then try again."
            return
        }
        // Apple recognition is required for the Apple engine; for Whisper it only
        // provides the live preview, so it's optional.
        let appleUsable = Permissions.speech == .granted && (recognizer?.isAvailable ?? false)
        if engineChoice == .apple && !appleUsable {
            if Permissions.speech != .granted { Permissions.requestSpeech() }
            lastError = Permissions.speech == .granted ? "Speech recognition isn't available right now."
                                                       : "Allow speech recognition, then try again."
            return
        }
        if engineChoice == .whisperLocal { WhisperLocal.shared.prepare() }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No input device (or it's switching): installing a tap would crash.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "No microphone input available."
            return
        }

        let request = appleUsable ? SFSpeechAudioBufferRecognitionRequest() : nil
        request?.shouldReportPartialResults = true
        request?.addsPunctuation = true
        self.request = request
        recorder.reset(inputFormat: format)
        transcript = ""
        let token = UUID()
        listenToken = token

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request, recorder: recorder) { [weak self] lvl in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateLevel(lvl) } }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            return
        }
        isListening = true
        listenStarted = Date()
        heardSpeech = false
        lastVoiceAt = Date()
        startAutoStopTimer()

        guard let request, let recognizer else { return } // Whisper-only: no live preview
        let appleIsFinal = engineChoice == .apple
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.listenToken else { return }
                    if let text { self.transcript = text }
                    // With Whisper, Apple is only the preview: its errors don't end the session.
                    guard appleIsFinal else { return }
                    if failed && self.isListening {
                        // Recognizer gave up while the user was still talking.
                        let handler = self.onUnexpectedEnd
                        self.tearDownAudio()
                        if self.transcript.isEmpty { self.lastError = "Didn't catch that. Try again." }
                        self.finalHandler = handler
                        self.deliverFinal()
                    } else if isFinal || failed {
                        self.deliverFinal()
                    }
                }
            }
        }
    }

    // MARK: Silence detection

    /// When set (tap-to-talk), listening ends by itself: true = user finished speaking, false = nothing said.
    var onAutoStop: ((Bool) -> Void)?
    var handsFree = false
    /// Hands-free: give up after this long if nothing is said.
    var noSpeechTimeout: TimeInterval = 5
    private var listenStarted = Date()
    private var lastVoiceAt = Date()
    private(set) var heardSpeech = false
    private var autoStopTimer: Timer?
    private let speechLevel: Float = 0.3 // roughly normal talking volume on the 0…1 scale

    private func updateLevel(_ lvl: Float) {
        level = lvl
        if lvl > speechLevel { heardSpeech = true; lastVoiceAt = Date() }
    }

    private func startAutoStopTimer() {
        autoStopTimer?.invalidate()
        guard handsFree else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isListening, self.handsFree else { return }
                let now = Date()
                if self.heardSpeech, now.timeIntervalSince(self.lastVoiceAt) > 1.4 {
                    self.autoStopTimer?.invalidate(); self.onAutoStop?(true)
                } else if !self.heardSpeech, now.timeIntervalSince(self.listenStarted) > self.noSpeechTimeout {
                    self.autoStopTimer?.invalidate(); self.onAutoStop?(false)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        autoStopTimer = t
    }

    /// Ends listening without sending anything.
    func cancelListening() {
        guard isListening else { return }
        tearDownAudio()
        finalHandler = nil
        task?.cancel(); task = nil; request = nil
        listenToken = UUID()
        isTranscribing = false
        transcript = ""
    }

    /// Receives the transcript if recognition ends before the user releases the key.
    var onUnexpectedEnd: ((String) -> Void)?

    /// Stops listening; `completion` receives the final transcript (may be empty).
    func stopListening(completion: @escaping (String) -> Void) {
        guard isListening else { completion(""); return }
        finalHandler = completion
        tearDownAudio()
        let token = listenToken

        if engineChoice != .apple && recorder.duration > 0.3 {
            transcribeWithWhisper(token: token)
            return
        }
        // Don't wait long for the recognizer's final result; the live transcript is usually complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.listenToken else { return }
                self.deliverFinal()
            }
        }
    }

    /// Sends the recording to the chosen Whisper engine; falls back to Apple's text.
    private func transcribeWithWhisper(token: UUID) {
        task?.cancel()
        isTranscribing = true
        let wav = recorder.wavData()
        let engine = engineChoice
        let language = settings.speechLanguage
        Task { @MainActor [weak self] in
            var text: String?
            do {
                text = engine == .groq
                    ? try await GroqWhisper.transcribe(wav, language: language)
                    : try await WhisperLocal.shared.transcribe(wav, language: language)
            } catch {
                NSLog("MacPilot: Whisper failed (\(error)); using Apple transcript")
            }
            guard let self, token == self.listenToken else { return }
            self.isTranscribing = false
            if let text, !Self.isHallucination(text) { self.transcript = text }
            // Nothing above talking volume was recorded: treat as silence, never send noise.
            if !self.heardSpeech, Self.isHallucination(self.transcript) || self.transcript.count < 4 { self.transcript = "" }
            self.deliverFinal()
        }
    }

    /// Whisper sometimes "hears" these in silence.
    static func isHallucination(_ t: String) -> Bool {
        // Drop bracketed non-speech tags like [BLANK_AUDIO], [Music], (silence).
        let cleaned = t.replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#, with: "", options: .regularExpression)
        let s = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        if s.isEmpty || !s.contains(where: { $0.isLetter }) { return true }
        return ["thank you", "thanks for watching", "you", "bye", "thank you for watching"].contains(s)
    }

    private func tearDownAudio() {
        autoStopTimer?.invalidate()
        level = 0
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
    }

    private func deliverFinal() {
        guard let handler = finalHandler else { return }
        finalHandler = nil
        task?.cancel()
        task = nil
        request = nil
        listenToken = UUID()
        handler(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Built outside the main actor: AVFoundation calls it on a realtime audio thread.
    nonisolated private static func makeTap(_ request: SFSpeechAudioBufferRecognitionRequest?,
                                            recorder: AudioRecorder,
                                            level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request?.append(buffer)
            recorder.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
            let rms = (sum / Float(max(1, n / 4))).squareRoot()
            // Map roughly -50…-10 dB to 0…1.
            let db = 20 * log10(max(rms, 0.000_01))
            level(min(1, max(0, (db + 50) / 40)))
        }
    }

    // MARK: Speaking

    /// Speaks text; `completion` runs after it has finished playing (not if it's interrupted).
    func speak(_ markdown: String, completion: (() -> Void)? = nil) {
        let plain = markdown
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        stopSpeaking()
        let token = UUID()
        speakToken = token
        isSpeaking = true
        let finished: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.speakToken == token else { return }
                    self.isSpeaking = false
                    let c = self.speakCompletion
                    self.speakCompletion = nil
                    c?()
                }
            }
        }
        speakCompletion = completion
        let isHindi = plain.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) } // Devanagari
        // Natural Kokoro voice for English; Apple's Hindi voice for Hindi (Kokoro can't pronounce it here).
        if settings.replyVoice == .kokoro, !isHindi,
           KokoroVoice.shared.speak(plain, speed: Float(0.5 + settings.speechRate), onFinished: finished,
                                    onFailed: { [weak self] in
                                        DispatchQueue.main.async {
                                            MainActor.assumeIsolated {
                                                guard let self, self.speakToken == token else { return }
                                                self.speakWithApple(plain, hindi: false, finished: finished)
                                            }
                                        }
                                    }) {
            voiceLog.notice("speak via Kokoro: \(plain.prefix(80), privacy: .public)")
            return
        }
        speakWithApple(plain, hindi: isHindi, finished: finished)
    }

    /// Completion per utterance, so a cancelled sentence can't finish someone else's.
    private var appleCompletions: [ObjectIdentifier: @Sendable () -> Void] = [:]

    private func speakWithApple(_ plain: String, hindi: Bool, finished: @escaping @Sendable () -> Void) {
        voiceLog.notice("speak via Apple (hindi=\(hindi)): \(plain.prefix(80), privacy: .public)")
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = hindi
            ? (AVSpeechSynthesisVoice(language: "hi-IN") ?? Self.bestVoice)
            : (AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) ?? Self.bestVoice)
        utterance.rate = Float(settings.speechRate) * AVSpeechUtteranceMaximumSpeechRate
        appleCompletions[ObjectIdentifier(utterance)] = finished
        synth.delegate = self
        synth.speak(utterance)
    }

    fileprivate func appleDidEnd(_ utterance: AVSpeechUtterance, finished: Bool) {
        let c = appleCompletions.removeValue(forKey: ObjectIdentifier(utterance))
        if finished { c?() }
    }

    func stopSpeaking() {
        speakToken = UUID()
        speakCompletion = nil
        isSpeaking = false
        KokoroVoice.shared.stop()
        synth.stopSpeaking(at: .immediate) // also drops queued, not-yet-started sentences
        appleCompletions.removeAll()
    }

    /// Real voices only (no novelty voices like Zarvox or Bubbles), best quality first.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !isNovelty($0) }
            .sorted { rank($0) > rank($1) }
    }

    /// The nicest installed voice: Premium > Enhanced > Siri > others.
    static var bestVoice: AVSpeechSynthesisVoice? {
        availableVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.contains("speech.synthesis.voice") || v.identifier.contains("eloquence")
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        var r = v.quality.rawValue * 100
        if v.identifier.contains("siri") { r += 20 }
        if v.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") { r += 10 }
        if v.language == "en-US" { r += 5 }
        return r
    }
}

/// Claude marks the part worth saying out loud with <speak>…</speak>.
enum SpeakTag {
    static let pattern = #"<speak>([\s\S]*?)(</speak>|$)"#

    /// Splits a reply into what to show and what (if anything) to say.
    static func split(_ text: String) -> (display: String, spoken: String?) {
        var spoken: String?
        if let r = text.range(of: pattern, options: .regularExpression) {
            spoken = String(text[r])
                .replacingOccurrences(of: "<speak>", with: "")
                .replacingOccurrences(of: "</speak>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (strip(text), (spoken?.isEmpty ?? true) ? nil : spoken)
    }

    /// The reply without the spoken part (also hides a half-streamed tag).
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<s(p(e(a(k)?)?)?)?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.appleDidEnd(utterance, finished: true) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.appleDidEnd(utterance, finished: false) } }
    }
}
