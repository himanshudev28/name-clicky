import AppKit
import SwiftUI

/// MacPilot's virtual cursor (clicky-style). While Claude works it appears next to
/// your pointer with a label saying what's happening, glides to whatever Claude
/// clicks, presses or types into, pulses on each action, then fades out.
/// It never moves your real mouse and ignores clicks. Can be turned off in Settings.
@MainActor
final class AgentCursorModel: ObservableObject {
    @Published var visible = false
    @Published var label = ""
    @Published var pulse = 0 // bump to play the click ripple
}

@MainActor
final class AgentCursorController {
    private let model = AgentCursorModel()
    private let settings = AppSettings.shared
    private var window: NSWindow!
    private var observer: NSObjectProtocol?
    private var fadeWork: DispatchWorkItem?
    private var pointLabelUntil = Date.distantPast
    private var tip = CGPoint.zero // current tip position, CG global coordinates

    private let size = CGSize(width: 340, height: 96)
    private let hotspot = CGPoint(x: 10, y: 10) // arrow tip inside the window (from top-left)

    /// How long `mpctl` waits before acting, so the cursor arrives first.
    static let glideDelayMs = 300

    init() {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.sharingType = .none // never appears in Claude's screenshots
        w.contentView = NSHostingView(rootView: AgentCursorView(model: model, hotspot: hotspot))
        window = w
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.macpilot.point"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let x = (info["x"] as? NSNumber)?.doubleValue
            let y = (info["y"] as? NSNumber)?.doubleValue
            let label = info["label"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if let x, let y { self.moveTo(CGPoint(x: x, y: y), label: label) } else { self.say(label, sticky: true) }
            }
        }
    }

    // MARK: Session hooks

    /// Claude started working: appear next to the user's pointer.
    func begin(status: String) {
        guard settings.showAgentCursor else { return }
        fadeWork?.cancel()
        if !model.visible {
            let m = NSEvent.mouseLocation
            tip = CGPoint(x: m.x + 34, y: primaryMaxY - m.y + 26)
            window.setFrameOrigin(origin(for: tip))
            window.orderFrontRegardless()
            model.label = status
            model.visible = true
        }
        say(status, sticky: false)
    }

    /// Progress text from the session (e.g. "Running AppleScript…").
    func status(_ text: String) {
        guard model.visible else { return }
        say(text, sticky: false)
    }

    /// Claude finished: linger a moment, then fade out.
    func end(finalText: String = "Done") {
        guard model.visible else { return }
        say(finalText, sticky: false)
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    func hide() {
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.visible else { return }
                self.window.orderOut(nil)
            }
        }
    }

    // MARK: Movement

    private func moveTo(_ target: CGPoint, label: String) {
        guard settings.showAgentCursor else { return }
        fadeWork?.cancel()
        if !model.visible {
            begin(status: label)
        }
        say(label, sticky: true)

        let distance = hypot(target.x - tip.x, target.y - tip.y)
        let duration = min(0.28, max(0.14, Double(distance) / 3000))
        tip = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0)
            window.animator().setFrame(CGRect(origin: origin(for: target), size: size), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.model.pulse += 1 }
        }
        // If no session is running (e.g. mpctl used by hand), fade out by itself.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.end(finalText: label) } }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Point labels ("Click “Wi-Fi”") win over generic session status for a moment.
    private func say(_ text: String, sticky: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if sticky {
            pointLabelUntil = Date().addingTimeInterval(1.6)
        } else if Date() < pointLabelUntil {
            return
        }
        model.label = t
    }

    private var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// Window origin (AppKit, bottom-left) that puts the arrow tip at `p` (CG, top-left).
    private func origin(for p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - hotspot.x, y: primaryMaxY - p.y + hotspot.y - size.height)
    }
}

// MARK: - View

private struct AgentCursorView: View {
    @ObservedObject var model: AgentCursorModel
    let hotspot: CGPoint
    @State private var ripple = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.visible {
                // Click ripple, centred on the arrow tip.
                Circle()
                    .stroke(Color.purple.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 34, height: 34)
                    .scaleEffect(ripple ? 1.4 : 0.2)
                    .opacity(ripple ? 0 : 0.9)
                    .offset(x: hotspot.x - 17, y: hotspot.y - 17)

                CursorArrow()
                    .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.38, blue: 1.0),
                                                  Color(red: 0.25, green: 0.45, blue: 1.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(CursorArrow().stroke(.white, lineWidth: 1.6))
                    .frame(width: 18, height: 26)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .offset(x: hotspot.x, y: hotspot.y)
                    .transition(.scale(scale: 0.3, anchor: .topLeading).combined(with: .opacity))

                Text(model.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Color(red: 0.45, green: 0.3, blue: 0.95),
                                                               Color(red: 0.25, green: 0.4, blue: 0.95)],
                                                      startPoint: .leading, endPoint: .trailing))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .frame(maxWidth: 290, alignment: .leading)
                    .fixedSize()
                    .offset(x: hotspot.x + 20, y: hotspot.y + 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topLeading)))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: model.label)
            }
        }
        .frame(width: 340, height: 96, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: model.visible)
        .onChange(of: model.pulse) { _, _ in
            ripple = false
            withAnimation(.easeOut(duration: 0.55)) { ripple = true }
        }
    }
}

/// A classic pointer arrow, tip at the top-left corner of its frame.
private struct CursorArrow: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 18, sy = r.height / 26
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(0, 0))
        path.addLine(to: p(0, 21))
        path.addLine(to: p(5.2, 16.2))
        path.addLine(to: p(8.6, 24.4))
        path.addLine(to: p(12.0, 23.0))
        path.addLine(to: p(8.6, 15.0))
        path.addLine(to: p(15.4, 15.0))
        path.closeSubpath()
        return path
    }
}
