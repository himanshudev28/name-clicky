import SwiftUI
import Foundation

// MARK: - Whisper model choices

enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case tiny, base, small, medium, largeTurbo
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiny: return "Tiny · fastest, basic accuracy"
        case .base: return "Base · fast, okay accuracy"
        case .small: return "Small · balanced (recommended)"
        case .medium: return "Medium · slower, high accuracy"
        case .largeTurbo: return "Large v3 Turbo · best accuracy, heavy"
        }
    }

    /// Quantized ggml file on https://huggingface.co/ggerganov/whisper.cpp (all verified to exist).
    var fileName: String {
        switch self {
        case .tiny: return "ggml-tiny-q5_1.bin"
        case .base: return "ggml-base-q5_1.bin"
        case .small: return "ggml-small-q5_1.bin"
        case .medium: return "ggml-medium-q5_0.bin"
        case .largeTurbo: return "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    var approxMB: Int {
        switch self {
        case .tiny: return 31
        case .base: return 57
        case .small: return 181
        case .medium: return 514
        case .largeTurbo: return 548
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var shortName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Large v3 Turbo"
        }
    }

    var localURL: URL { VoiceModelStore.modelsFolder.appendingPathComponent(fileName) }
}

// MARK: - Components

enum VoiceComponent: Hashable {
    case whisperEngine
    case whisperModel(WhisperModelChoice)
    case kokoro

    static var all: [VoiceComponent] {
        [.whisperEngine] + WhisperModelChoice.allCases.map { .whisperModel($0) } + [.kokoro]
    }

    var title: String {
        switch self {
        case .whisperEngine: return "Whisper engine (whisper.cpp)"
        case .whisperModel(let m): return "Whisper model: \(m.shortName)"
        case .kokoro: return "Kokoro voice (Kokoro-82M int8)"
        }
    }

    var detail: String {
        switch self {
        case .whisperEngine: return "Installed with Homebrew (brew install whisper-cpp)."
        case .whisperModel(let m): return m.label
        case .kokoro: return "Natural offline voice. Runtime + model, about 260 MB on disk."
        }
    }

    /// Approximate download size shown before downloading.
    var approxMB: Int {
        switch self {
        case .whisperEngine: return 20
        case .whisperModel(let m): return m.approxMB
        case .kokoro: return 330
        }
    }
}

enum ComponentState: Equatable {
    case notInstalled
    case working(progress: Double?, note: String)
    case installed(bytes: Int64)
    case needsHomebrew
    case failed(String)
}

// MARK: - Store

@MainActor
final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()

    @Published private(set) var states: [VoiceComponent: ComponentState] = [:]
    @Published var selectedWhisperModel: WhisperModelChoice {
        didSet { UserDefaults.standard.set(selectedWhisperModel.rawValue, forKey: "whisperModel") }
    }

    private var tasks: [VoiceComponent: Task<Void, Never>] = [:]
    private var downloaders: [VoiceComponent: Downloader] = [:]
    private var processes: [VoiceComponent: Process] = [:]

    static let sherpaURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared.tar.bz2")!
    static let kokoroURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2")!
    static let sherpaFolderName = "sherpa-onnx-v2.0.1-osx-arm64-shared"
    static let kokoroFolderName = "kokoro-int8-multi-lang-v1_0"

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot", isDirectory: true)
    }
    nonisolated static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/Models", isDirectory: true)
    }
    nonisolated static var ttsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/TTS", isDirectory: true)
    }

    nonisolated static var selectedWhisperModelPath: String? {
        let raw = UserDefaults.standard.string(forKey: "whisperModel") ?? ""
        let choice = WhisperModelChoice(rawValue: raw) ?? .small
        let p = choice.localURL.path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    nonisolated static var whisperServerPath: String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "whisperModel") ?? ""
        selectedWhisperModel = WhisperModelChoice(rawValue: raw) ?? .small
        refresh()
    }

    func state(_ c: VoiceComponent) -> ComponentState { states[c] ?? .notInstalled }

    /// Total bytes used on disk by installed local voice models (excludes the Homebrew engine).
    var totalBytes: Int64 {
        states.reduce(0) { acc, kv in
            if case .whisperEngine = kv.key { return acc }
            if case .installed(let b) = kv.value { return acc + b }
            return acc
        }
    }

    // MARK: Detection

    func refresh() {
        for c in VoiceComponent.all {
            if case .working = state(c) { continue }
            states[c] = Self.detect(c)
        }
    }

    private static func detect(_ c: VoiceComponent) -> ComponentState {
        let fm = FileManager.default
        switch c {
        case .whisperEngine:
            if let p = whisperServerPath {
                let real: URL? = URL(fileURLWithPath: p).resolvingSymlinksInPath()
                let root = real?.deletingLastPathComponent().deletingLastPathComponent()
                let size = root.map { folderSize($0) } ?? 0
                return .installed(bytes: size)
            }
            return brewPath == nil ? .needsHomebrew : .notInstalled
        case .whisperModel(let m):
            if let attrs = try? fm.attributesOfItem(atPath: m.localURL.path), let n = attrs[.size] as? NSNumber {
                return .installed(bytes: n.int64Value)
            }
            return .notInstalled
        case .kokoro:
            let lib = ttsFolder.appendingPathComponent("\(sherpaFolderName)/lib/libsherpa-onnx-c-api.dylib")
            let model = ttsFolder.appendingPathComponent("\(kokoroFolderName)/model.int8.onnx")
            // Match KokoroVoice's own lookup (any folder with these prefixes).
            let names = (try? fm.contentsOfDirectory(atPath: ttsFolder.path)) ?? []
            let sherpa = names.sorted().last { $0.hasPrefix("sherpa-onnx-") }
            let kokoro = names.sorted().last { $0.hasPrefix("kokoro-int8-multi-lang") }
            let libOK = sherpa.map { fm.fileExists(atPath: ttsFolder.appendingPathComponent("\($0)/lib/libsherpa-onnx-c-api.dylib").path) } ?? fm.fileExists(atPath: lib.path)
            let modelOK = kokoro.map { fm.fileExists(atPath: ttsFolder.appendingPathComponent("\($0)/model.int8.onnx").path) } ?? fm.fileExists(atPath: model.path)
            guard libOK, modelOK else { return .notInstalled }
            let size = [sherpa, kokoro].compactMap { $0 }.reduce(Int64(0)) { $0 + folderSize(ttsFolder.appendingPathComponent($1)) }
            return .installed(bytes: size)
        }
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: Install

    func install(_ c: VoiceComponent) {
        if case .working = state(c) { return }
        states[c] = .working(progress: nil, note: "Starting…")
        tasks[c] = Task { [weak self] in
            guard let self else { return }
            do {
                switch c {
                case .whisperEngine: try await self.installEngine()
                case .whisperModel(let m): try await self.installWhisperModel(m)
                case .kokoro: try await self.installKokoro()
                }
                self.finish(c)
            } catch is CancellationError {
                self.finish(c)
            } catch let e as URLError where e.code == .cancelled {
                self.finish(c)
            } catch {
                self.states[c] = .failed(error.localizedDescription)
                self.cleanup(c)
            }
        }
    }

    private func finish(_ c: VoiceComponent) {
        cleanup(c)
        states[c] = Self.detect(c)
    }

    private func cleanup(_ c: VoiceComponent) {
        tasks[c] = nil; downloaders[c] = nil; processes[c] = nil
    }

    func cancel(_ c: VoiceComponent) {
        downloaders[c]?.cancel()
        processes[c]?.terminate()
        tasks[c]?.cancel()
        // finish() runs when the task unwinds; reset immediately for responsiveness.
        states[c] = Self.detect(c)
    }

    private func setProgress(_ c: VoiceComponent, _ p: Double?, _ note: String) {
        if case .working = state(c) { states[c] = .working(progress: p, note: note) }
    }

    private func download(_ url: URL, for c: VoiceComponent, to dest: URL, label: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        let d = Downloader()
        downloaders[c] = d
        let tmp = try await d.download(url) { [weak self] done, total in
            Task { @MainActor in
                let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
                self?.setProgress(c, total > 0 ? Double(done) / Double(total) : nil,
                                  total > 0 ? "\(label) \(mb(done)) of \(mb(total)) MB" : "\(label) \(mb(done)) MB")
            }
        }
        defer { try? fm.removeItem(at: tmp) }
        try fm.moveItem(at: tmp, to: part)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)   // atomic rename within the same folder
    }

    private func installWhisperModel(_ m: WhisperModelChoice) async throws {
        let c = VoiceComponent.whisperModel(m)
        try await download(m.downloadURL, for: c, to: m.localURL, label: "Downloading")
        if Self.detect(c) == .notInstalled { throw VoiceModelError.message("Download finished but the file is missing.") }
    }

    private func installKokoro() async throws {
        let c = VoiceComponent.kokoro
        let fm = FileManager.default
        let existing = Self.detect(c)
        if case .installed = existing { return }
        try fm.createDirectory(at: Self.ttsFolder, withIntermediateDirectories: true)
        let items: [(URL, String, String)] = [
            (Self.sherpaURL, Self.sherpaFolderName, "Speech runtime"),
            (Self.kokoroURL, Self.kokoroFolderName, "Voice model"),
        ]
        for (url, folderName, label) in items {
            let dest = Self.ttsFolder.appendingPathComponent(folderName)
            if fm.fileExists(atPath: dest.path), folderName == Self.sherpaFolderName,
               fm.fileExists(atPath: dest.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib").path) { continue }
            if fm.fileExists(atPath: dest.path), folderName == Self.kokoroFolderName,
               fm.fileExists(atPath: dest.appendingPathComponent("model.int8.onnx").path) { continue }
            let archive = Self.ttsFolder.appendingPathComponent("\(folderName).tar.bz2")
            try await download(url, for: c, to: archive, label: "\(label):")
            defer { try? fm.removeItem(at: archive) }
            setProgress(c, nil, "Unpacking \(label.lowercased())…")
            try await extract(archive, into: Self.ttsFolder)
            try Task.checkCancellation()
        }
        if case .installed = Self.detect(c) { return }
        throw VoiceModelError.message("Unpacked, but the expected files were not found in \(Self.ttsFolder.path).")
    }

    /// Extracts into a staging folder, then moves the top-level items into `folder`,
    /// so an interrupted extraction never leaves a half-written model folder behind.
    private func extract(_ archive: URL, into folder: URL) async throws {
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let (status, out) = try await Task.detached { () -> (Int32, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xjf", archive.path, "-C", staging.path]
            let pipe = Pipe()
            p.standardError = pipe; p.standardOutput = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        guard status == 0 else { throw VoiceModelError.message("Unpacking failed: \(out.suffix(200))") }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: staging.path) {
            let src = staging.appendingPathComponent(name)
            let dst = folder.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
            _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dst.path])
        }
    }

    private func installEngine() async throws {
        guard let brew = Self.brewPath else { states[.whisperEngine] = .needsHomebrew; throw CancellationError() }
        try await runBrew(brew, ["install", "whisper-cpp"], note: "brew install whisper-cpp")
        if Self.whisperServerPath == nil { throw VoiceModelError.message("Homebrew finished but whisper-server was not found.") }
    }

    private func runBrew(_ brew: String, _ args: [String], note: String) async throws {
        let c = VoiceComponent.whisperEngine
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        processes[c] = p
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard let line = s.split(whereSeparator: \.isNewline).last.map(String.init), !line.isEmpty else { return }
            Task { @MainActor in self?.setProgress(c, nil, String(line.prefix(90))) }
        }
        setProgress(c, nil, "Running \(note)…")
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else { throw VoiceModelError.message("Homebrew exited with status \(status).") }
    }

    private nonisolated static func run(_ exe: String, _ args: [String]) async throws -> Int32 {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }.value
    }

    // MARK: Uninstall

    func uninstall(_ c: VoiceComponent) {
        if case .working = state(c) { return }
        let fm = FileManager.default
        switch c {
        case .whisperModel(let m):
            try? fm.removeItem(at: m.localURL)
            states[c] = Self.detect(c)
        case .kokoro:
            let names = (try? fm.contentsOfDirectory(atPath: Self.ttsFolder.path)) ?? []
            for n in names where n.hasPrefix("sherpa-onnx-") || n.hasPrefix("kokoro-int8-multi-lang") {
                try? fm.removeItem(at: Self.ttsFolder.appendingPathComponent(n))
            }
            states[c] = Self.detect(c)
        case .whisperEngine:
            guard let brew = Self.brewPath else { states[c] = .needsHomebrew; return }
            states[c] = .working(progress: nil, note: "Running brew uninstall…")
            tasks[c] = Task { [weak self] in
                guard let self else { return }
                do { try await self.runBrew(brew, ["uninstall", "whisper-cpp"], note: "brew uninstall whisper-cpp"); self.finish(c) }
                catch { self.cleanup(c); self.states[c] = .failed(error.localizedDescription) }
            }
        }
    }
}

enum VoiceModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Download helper (progress + cancel)

final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cont: CheckedContinuation<URL, Error>?
    private var progress: ((Int64, Int64) -> Void)?
    private var movedTo: URL?
    private var lastReport = Date.distantPast

    func download(_ url: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        self.progress = progress
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                self.cont = c
                let t = s.downloadTask(with: url)
                self.task = t
                t.resume()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            movedTo = nil
            finish(.failure(VoiceModelError.message("Server answered HTTP \(http.statusCode).")))
            return
        }
        // The system deletes `location` after this returns, so move it first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("macpilot-dl-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: keep); finish(.success(keep)) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ r: Result<URL, Error>) {
        guard let c = cont else { return }
        cont = nil
        session?.finishTasksAndInvalidate()
        c.resume(with: r)
    }
}

// MARK: - UI

struct VoiceModelsSection: View {
    @ObservedObject private var store = VoiceModelStore.shared
    @State private var confirmUninstall: VoiceComponent?

    var body: some View {
        Section {
            row(.whisperEngine)
            ForEach(WhisperModelChoice.allCases) { m in row(.whisperModel(m)) }
        } header: {
            Text("Listening (Whisper on this Mac)")
        } footer: {
            Text("Runs fully offline. Pick the model MacPilot uses with the circle on the left; bigger models are more accurate but slower.")
        }

        Section {
            row(.kokoro)
            LabeledContent("Disk used by voice models",
                           value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
        } header: {
            Text("Speaking (Kokoro voice)")
        } footer: {
            Text("Models are stored in ~/Library/Application Support/MacPilot.")
        }
        .onAppear { store.refresh() }
        .confirmationDialog("Uninstall \(confirmUninstall?.title ?? "")?",
                            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }),
                            titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { if let c = confirmUninstall { store.uninstall(c) }; confirmUninstall = nil }
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
        } message: {
            Text("You can download it again later.")
        }
    }

    @ViewBuilder
    private func row(_ c: VoiceComponent) -> some View {
        let st = store.state(c)
        HStack(alignment: .center, spacing: 10) {
            if case .whisperModel(let m) = c {
                let installed: Bool = { if case .installed = st { return true }; return false }()
                Button {
                    store.selectedWhisperModel = m
                } label: {
                    Image(systemName: store.selectedWhisperModel == m ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(installed ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!installed)
                .help(installed ? "Use this model" : "Download it first")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title)
                subtitle(c, st)
            }
            Spacer(minLength: 8)
            actions(c, st)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func subtitle(_ c: VoiceComponent, _ st: ComponentState) -> some View {
        switch st {
        case .notInstalled:
            Text("\(c.detail) · download about \(c.approxMB) MB").font(.caption).foregroundStyle(.secondary)
        case .installed(let b):
            let size = b > 0 ? " · \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))" : ""
            Text("Installed\(size)").font(.caption).foregroundStyle(.green)
        case .working(let p, let note):
            VStack(alignment: .leading, spacing: 2) {
                if let p { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .needsHomebrew:
            Text("Needs Homebrew (brew.sh). Install it first, then press Refresh.").font(.caption).foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private func actions(_ c: VoiceComponent, _ st: ComponentState) -> some View {
        switch st {
        case .notInstalled, .failed:
            Button("Download & set up") { store.install(c) }
        case .installed:
            Button("Uninstall", role: .destructive) { confirmUninstall = c }
        case .working:
            Button("Cancel") { store.cancel(c) }
        case .needsHomebrew:
            Button("Refresh") { store.refresh() }
        }
    }
}
