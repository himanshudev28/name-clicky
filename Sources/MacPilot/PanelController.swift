import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app,
/// so the user's current app stays frontmost (Spotlight-style).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Accessory apps may not route Edit-menu shortcuts to a non-activating panel,
    // so handle the standard text-editing ones directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let key = event.charactersIgnoringModifiers {
            let action: Selector? = switch key {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            case "w": #selector(NSWindow.cancelOperation(_:))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() ?? orderOut(nil) } // Esc closes
}

@MainActor
final class PanelController {
    private(set) var panel: KeyablePanel!
    private let size = CGSize(width: 380, height: 500)
    weak var statusButton: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var isHiding = false
    private var container: NSView!
    /// The pill the popup grows out of / shrinks back into (Dynamic Island style).
    private let pillScale = CATransform3DMakeScale(0.3, 0.07, 1)

    init<Content: View>(rootView: Content) {
        let panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = CGSize(width: 320, height: 340)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none // keep the panel out of Claude's screenshots

        // Same material, radius and hairline border as macOS menu bar popovers (Control Center).
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        // A plain container we can scale for the Dynamic Island grow/shrink animation.
        let container = NSView()
        container.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        self.container = container
        panel.onCancel = { [weak self] in self?.hide() }
        self.panel = panel
    }

    var isVisible: Bool { panel.isVisible && !isHiding }

    func toggle() { isVisible ? hide() : show() }

    /// Dynamic Island style: a small pill under the menu bar icon springs open into the popup.
    func show() {
        NotificationCenter.default.post(name: .macPilotFocusInput, object: nil)
        if isVisible { panel.makeKeyAndOrderFront(nil); return }
        isHiding = false
        position()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.2 : 0.12
            panel.animator().alphaValue = 1
        }
        if !reduceMotion, let layer = anchoredLayer() {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: pillScale)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.mass = 1
            spring.stiffness = 260
            spring.damping = 22
            spring.duration = spring.settlingDuration
            layer.transform = CATransform3DIdentity
            layer.add(spring, forKey: "island")
            DispatchQueue.main.asyncAfter(deadline: .now() + spring.duration) { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        }
        startOutsideClickMonitor()
    }

    /// Shrinks back into the pill and fades out.
    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        stopOutsideClickMonitor()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion, let layer = anchoredLayer() {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: pillScale)
            shrink.duration = 0.2
            shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "island")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.panel.orderOut(nil)
                self.container.layer?.removeAnimation(forKey: "island")
                self.panel.alphaValue = 1
                self.isHiding = false
            }
        }
    }

    /// The container's layer, anchored at its top center (just under the menu bar icon).
    private func anchoredLayer() -> CALayer? {
        guard let layer = container.layer else { return nil }
        let b = container.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 1) // AppKit layers: y = 1 is the top
        layer.position = CGPoint(x: b.midX, y: b.maxY)
        return layer
    }

    /// Native popovers close when you click anywhere else.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        guard AppSettings.shared.closePopupOnOutsideClick else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// Under the menu bar icon if we can find it, otherwise top-right of the active screen.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = statusButton?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frameSize = panel.frame.size
        var x = visible.maxX - frameSize.width - 10
        if let button = statusButton, let bw = button.window {
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            x = min(max(r.midX - frameSize.width / 2, visible.minX + 8), visible.maxX - frameSize.width - 8)
        }
        let y = visible.maxY - frameSize.height - 5
        panel.setFrame(CGRect(x: x, y: y, width: frameSize.width, height: frameSize.height), display: false)
    }
}

extension Notification.Name {
    static let macPilotFocusInput = Notification.Name("macPilotFocusInput")
}

