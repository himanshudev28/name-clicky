import AVFoundation
import Speech

/// Always-on wake word ("Clicky" by default), like "Hey Siri".
/// Uses Apple's on-device speech recognition, so audio never leaves the Mac.
/// Paused while MacPilot itself is listening or speaking.
@MainActor
final class WakeWordListener {
    var onWake: (() -> Void)?

    private let settings = AppSettings.shared
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = UUID()
    private(set) var isRunning = false
    private var paused = false
    private var restartWork: DispatchWorkItem?

    /// Extra spellings the recognizer tends to produce for "Clicky".
    private let clickyVariants = ["clicky", "clickie", "clicki", "klicky", "kliki", "clickey", "click e", "quickie", "clicky's"]

    private var wakeWords: [String] {
        let w = settings.wakeWord.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return [] }
        return w == "clicky" ? clickyVariants : [w]
    }

    /// Starts listening if the setting is on and nothing else is using the mic.
    func resume() {
        paused = false
        start()
    }

    /// Stops while MacPilot listens to a command or speaks.
    func pause() {
        paused = true
        stop()
    }

    func refresh() {
        if settings.wakeWordEnabled && !paused { start() } else { stop() }
    }

    private func start() {
        guard settings.wakeWordEnabled, !paused, !isRunning,
              Permissions.microphone == .granted, Permissions.speech == .granted else { return }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return }
        self.recognizer = recognizer

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on the Mac when possible.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = [settings.wakeWord]
        request.taskHint = .search
        self.request = request

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(request))
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        isRunning = true

        let myToken = UUID()
        token = myToken
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString.lowercased() ?? ""
            let ended = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, myToken == self.token else { return }
                    if self.wakeWords.contains(where: { text.contains($0) }) {
                        voiceLog.notice("wake word heard")
                        self.stop()
                        self.onWake?()
                    } else if ended {
                        // Recognition sessions end on their own after a while: start a fresh one.
                        self.stop()
                        self.scheduleRestart()
                    }
                }
            }
        }
        // Long sessions get slow and eventually time out; recycle every 50 s.
        scheduleRestart(after: 50, onlyIfRunning: true)
    }

    private func scheduleRestart(after seconds: Double = 0.3, onlyIfRunning: Bool = false) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused else { return }
                if onlyIfRunning { guard self.isRunning else { return }; self.stop() }
                self.start()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func stop() {
        restartWork?.cancel()
        token = UUID()
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    nonisolated private static func makeTap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }
}
