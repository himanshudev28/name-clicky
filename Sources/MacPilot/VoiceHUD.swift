import AppKit
import SwiftUI

/// The floating voice pill shown while you hold the hotkey: listens with a live
/// waveform, then shows progress and the reply, then hides itself.
/// Clicking it opens the full chat panel.
@MainActor
final class VoiceHUDModel: ObservableObject {
    enum Phase: Equatable { case hidden, listening, working, reply(String), error(String) }
    @Published var phase: Phase = .hidden
}

@MainActor
final class VoiceHUDController {
    let model = VoiceHUDModel()
    var onClick: (() -> Void)?

    private let settings = AppSettings.shared
    private var panel: NSPanel!
    private var hideWork: DispatchWorkItem?
    private let size = CGSize(width: 520, height: 170)

    init(voice: VoiceController, session: ClaudeSession) {
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the SwiftUI pill draws its own shadow
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none // stay out of Claude's screenshots
        let view = VoiceHUDView(model: model, voice: voice, session: session) { [weak self] in self?.onClick?() }
        p.contentView = NSHostingView(rootView: view)
        panel = p
    }

    func showListening() { show(.listening, autoHide: nil) }
    func showWorking() { show(.working, autoHide: nil) }
    func showFollowUp() { show(.reply("Anything else?"), autoHide: nil) }

    func showReply(_ text: String) {
        // Longer replies stay a little longer.
        let seconds = min(12, 4 + Double(text.count) / 40)
        show(.reply(text), autoHide: seconds)
    }

    func showError(_ text: String) { show(.error(text), autoHide: 6) }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        // Let the exit animation play before removing the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .hidden else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    var isActive: Bool { model.phase != .hidden }

    private func show(_ phase: VoiceHUDModel.Phase, autoHide: Double?) {
        hideWork?.cancel()
        if !panel.isVisible || model.phase == .hidden { position() }
        panel.orderFrontRegardless()
        model.phase = phase
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var origin: CGPoint
        switch settings.hudPosition {
        case .island:
            // Hangs just under the menu bar, centered (no notch needed).
            origin = CGPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 4)
        case .bottom:
            origin = CGPoint(x: v.midX - size.width / 2, y: v.minY + 24)
        case .top:
            origin = CGPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 8)
        case .cursor:
            origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
            origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View

private struct VoiceHUDView: View {
    @ObservedObject var model: VoiceHUDModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var session: ClaudeSession
    var onClick: () -> Void

    private var visible: Bool { model.phase != .hidden }
    private var position: HUDPosition { AppSettings.shared.hudPosition }

    var body: some View {
        VStack {
            if position == .island {
                if visible {
                    island
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.3, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.4, anchor: .top).combined(with: .opacity)))
                }
                Spacer(minLength: 0)
            } else {
                if position != .top { Spacer(minLength: 0) }
                if visible {
                    pill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6, anchor: position == .top ? .top : .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)))
                }
                if position == .top { Spacer(minLength: 0) }
            }
        }
        .frame(width: 520, height: 170)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: visible)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
    }

    /// Dynamic Island style: a solid black capsule that grows out of the menu bar
    /// and stretches with its content, springing between sizes.
    private var island: some View {
        let expanded = message.count > 34 || { if case .reply = model.phase { return true }; return false }()
        return HStack(spacing: 10) {
            leading.frame(width: 34, height: 22)
            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(textStyle)
                .lineLimit(expanded ? 4 : 1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: expanded ? 380 : 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, expanded ? 18 : 14)
        .padding(.vertical, expanded ? 14 : 9)
        .frame(minWidth: 150)
        .background {
            RoundedRectangle(cornerRadius: expanded ? 26 : 20, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .padding(.top, 6)
        .environment(\.colorScheme, .dark)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onClick)
        .help("Open MacPilot")
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: message)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: expanded)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            leading.frame(width: 44, height: 28)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textStyle)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 200)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(Capsule(style: .continuous).strokeBorder(borderGradient, lineWidth: 1.2))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Capsule())
        .onTapGesture(perform: onClick)
        .help("Open MacPilot")
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .listening:
            Waveform(level: CGFloat(voice.level))
        case .working:
            ThinkingDots()
        case .reply:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }

    private var message: String {
        switch model.phase {
        case .listening: return voice.transcript.isEmpty ? "Listening…" : voice.transcript
        case .working:
            if voice.isTranscribing { return "Transcribing…" }
            return session.statusText == "Done" ? "Working…" : session.statusText
        case .reply(let t): return t
        case .error(let t): return t
        case .hidden: return ""
        }
    }

    private var textStyle: AnyShapeStyle {
        if case .listening = model.phase, voice.transcript.isEmpty { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }

    private var borderGradient: LinearGradient {
        let colors: [Color] = switch model.phase {
        case .listening: [.purple.opacity(0.9), .blue.opacity(0.7)]
        case .working: [.blue.opacity(0.7), .cyan.opacity(0.6)]
        case .error: [.orange.opacity(0.8), .red.opacity(0.6)]
        default: [.white.opacity(0.25), .white.opacity(0.1)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// Bars that follow the microphone level with a little per-bar variation.
private struct Waveform: View {
    let level: CGFloat
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                    let h = 5 + (level * 0.85 + 0.15 * CGFloat(wobble) * max(level, 0.12)) * 22 * weights[i]
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: h)
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 5 - Double(i) * 0.7) + 1) / 2
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.6 + 0.5 * phase)
                        .opacity(0.4 + 0.6 * phase)
                }
            }
        }
    }
}
