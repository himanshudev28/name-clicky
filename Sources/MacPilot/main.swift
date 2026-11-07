import AppKit

// Pure AppKit entry point. The app starts as a menu bar app (no Dock icon);
// AppDelegate switches the activation policy if the user turns the Dock icon on.
// Writing to a `claude` process that just exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
