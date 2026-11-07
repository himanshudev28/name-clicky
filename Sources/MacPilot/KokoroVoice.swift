import AVFoundation
import CSherpaOnnx
import Foundation
import os

private let kokoroLog = Logger(subsystem: "com.macpilot.app", category: "kokoro")

/// Natural offline voice: Kokoro-82M (int8) running in-process through the
/// sherpa-onnx library in ~/Library/Application Support/MacPilot/TTS.
///
/// Fast path:
/// - the model is loaded once and kept in memory (no ~1 s load per reply);
/// - audio arrives sentence by sentence and starts playing immediately,
///   while the following sentences are still being generated.
final class KokoroVoice: @unchecked Sendable {
    static let shared = KokoroVoice()

    /// "af_heart", the voice the user picked.
    static let speakerId: Int32 = 3

    // MARK: Files

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/TTS", isDirectory: true)
    }

    private static func subfolder(prefix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().last { $0.hasPrefix(prefix) }.map { folder.appendingPathComponent($0) }
    }

    static var libraryPath: String? {
        subfolder(prefix: "sherpa-onnx-").map { $0.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    static var modelFolder: URL? {
        guard let dir = subfolder(prefix: "kokoro-int8-multi-lang"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path) else { return nil }
        return dir
    }

    static var isInstalled: Bool { libraryPath != nil && modelFolder != nil }

    static var statusText: String {
        isInstalled ? "Ready · Kokoro int8 · voice Heart" : "Not installed (expected in \(folder.path))"
    }

    // MARK: C functions (resolved with dlsym)

    private typealias CreateFn = @convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>?) -> OpaquePointer?
    private typealias GenerateFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Float,
                                                   SherpaOnnxGeneratedAudioCallbackWithArg?, UnsafeMutableRawPointer?)
        -> UnsafePointer<SherpaOnnxGeneratedAudio>?
    private typealias DestroyAudioFn = @convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>?) -> Void
    private typealias SampleRateFn = @convention(c) (OpaquePointer?) -> Int32

    private var generate: GenerateFn?
    private var destroyAudio: DestroyAudioFn?
    private var tts: OpaquePointer?
    private var libHandle: UnsafeMutableRawPointer?
    private var sampleRate: Double = 24_000

    // MARK: Playback

    private let queue = DispatchQueue(label: "macpilot.kokoro", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var token = 0 // bumped by stop(); generation checks it between sentences
    private var loadFailed = false

    var currentToken: Int { lock.lock(); defer { lock.unlock() }; return token }

    /// Loads the model in the background so the first reply is fast.
    func prepare() { queue.async { _ = self.loadIfNeeded() } }

    /// Speaks `text`; returns false if Kokoro isn't available (caller falls back to Apple).
    @discardableResult
    /// `onFinished` runs once playback has ended; `onFailed` runs (instead) if Kokoro couldn't
    /// produce audio, so the caller can fall back to the Apple voice. Neither runs after `stop()`.
    func speak(_ text: String, speed: Float,
               onFinished: (@Sendable () -> Void)? = nil,
               onFailed: (@Sendable () -> Void)? = nil) -> Bool {
        guard Self.isInstalled, !isLoadFailed else { return false }
        stop()
        let myToken = currentToken
        queue.async {
            guard self.loadIfNeeded(), let generate = self.generate, let destroy = self.destroyAudio else {
                if myToken == self.currentToken { onFailed?() }
                return
            }
            guard myToken == self.currentToken else { return }
            let ctx = CallbackContext(voice: self, token: myToken)
            let arg = Unmanaged.passRetained(ctx).toOpaque()
            let audio = text.withCString { generate(self.tts, $0, Self.speakerId, speed, kokoroChunkCallback, arg) }
            Unmanaged<CallbackContext>.fromOpaque(arg).release()
            destroy(audio)
            // Everything is queued: a tiny silent buffer at the end tells us when playback is over.
            let scheduled = self.scheduleLocked(token: myToken, frames: nil, count: 240) {
                guard myToken == self.currentToken else { return } // stopped early: no "finished"
                onFinished?()
            }
            if !scheduled && myToken == self.currentToken { onFinished?() }
        }
        return true
    }

    var isLoadFailed: Bool { lock.lock(); defer { lock.unlock() }; return loadFailed }

    /// Stopping and scheduling share one lock, so a sentence can't slip in after stop().
    func stop() {
        lock.lock()
        token += 1
        player.stop()
        lock.unlock()
    }

    /// Called from the generation thread with one sentence of audio at a time.
    fileprivate func play(_ samples: UnsafePointer<Float>, count: Int, token: Int) -> Bool {
        guard token == currentToken else { return false } // stopped: abort generation
        return scheduleLocked(token: token, frames: samples, count: count, completion: nil)
    }

    /// Schedules audio (or silence when `frames` is nil) if `token` is still current.
    private func scheduleLocked(token: Int, frames: UnsafePointer<Float>?, count: Int,
                                completion: (@Sendable () -> Void)?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == self.token, let format, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return false }
        buffer.frameLength = AVAudioFrameCount(count)
        if let frames { buffer.floatChannelData![0].update(from: frames, count: count) }
        else { buffer.floatChannelData![0].update(repeating: 0, count: count) }
        if !engine.isRunning {
            do { try engine.start() } catch {
                kokoroLog.error("audio engine failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        if let completion {
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        } else {
            player.scheduleBuffer(buffer)
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// True while the voice model is loaded in memory.
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
    private var loaded = false

    /// Frees the voice model's memory (it loads again on demand or with prepare()).
    func unload() {
        stop()
        queue.async {
            guard let t = self.tts, let h = self.libHandle,
                  let sym = dlsym(h, "SherpaOnnxDestroyOfflineTts") else { return }
            typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
            unsafeBitCast(sym, to: DestroyFn.self)(t)
            self.tts = nil
            self.lock.lock(); self.loaded = false; self.lock.unlock()
            self.engine.stop()
            kokoroLog.notice("unloaded")
        }
    }

    private func loadIfNeeded() -> Bool {
        if tts != nil { return true }
        if isLoadFailed { return false }
        guard let libPath = Self.libraryPath, let dir = Self.modelFolder,
              let handle = libHandle ?? dlopen(libPath, RTLD_NOW | RTLD_LOCAL),
              let createSym = dlsym(handle, "SherpaOnnxCreateOfflineTts"),
              let genSym = dlsym(handle, "SherpaOnnxOfflineTtsGenerateWithCallbackWithArg"),
              let destroySym = dlsym(handle, "SherpaOnnxDestroyOfflineTtsGeneratedAudio"),
              let rateSym = dlsym(handle, "SherpaOnnxOfflineTtsSampleRate") else {
            lock.lock(); loadFailed = true; lock.unlock()
            kokoroLog.error("library unavailable: \(String(cString: dlerror()), privacy: .public)")
            return false
        }
        libHandle = handle
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        generate = unsafeBitCast(genSym, to: GenerateFn.self)
        destroyAudio = unsafeBitCast(destroySym, to: DestroyAudioFn.self)

        // C strings must outlive the create call.
        let strings = ["model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt"]
            .map { strdup(dir.appendingPathComponent($0).path) }
        let cpu = strdup("cpu"), lang = strdup("en"), empty = strdup("")
        defer { (strings + [cpu, lang, empty]).forEach { free($0) } }

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(strings[0])
        config.model.kokoro.voices = UnsafePointer(strings[1])
        config.model.kokoro.tokens = UnsafePointer(strings[2])
        config.model.kokoro.lexicon = UnsafePointer(strings[3])
        config.model.kokoro.lang = UnsafePointer(lang)
        config.model.kokoro.data_dir = UnsafePointer(empty)
        config.model.kokoro.dict_dir = UnsafePointer(empty)
        config.model.kokoro.length_scale = 1.0
        config.model.num_threads = 4 // the M1's four performance cores
        config.model.provider = UnsafePointer(cpu)
        config.max_num_sentences = 1 // one sentence per callback → speech starts sooner
        config.silence_scale = 0.2

        guard let t = withUnsafePointer(to: &config, { create($0) }) else {
            lock.lock(); loadFailed = true; lock.unlock()
            kokoroLog.error("model failed to load")
            return false
        }
        tts = t
        lock.lock(); loaded = true; lock.unlock()
        sampleRate = Double(unsafeBitCast(rateSym, to: SampleRateFn.self)(t))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        lock.lock(); format = fmt; lock.unlock()
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        kokoroLog.notice("loaded, sample rate \(self.sampleRate)")
        return true
    }
}

private final class CallbackContext {
    let voice: KokoroVoice
    let token: Int
    init(voice: KokoroVoice, token: Int) { self.voice = voice; self.token = token }
}

/// C callback: returns 1 to keep generating, 0 to stop.
private let kokoroChunkCallback: SherpaOnnxGeneratedAudioCallbackWithArg = { samples, n, arg in
    guard let samples, let arg else { return 0 }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(arg).takeUnretainedValue()
    return ctx.voice.play(samples, count: Int(n), token: ctx.token) ? 1 : 0
}
