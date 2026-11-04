import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    exit(SelfTest.run(reportPath: out))
}

let others = NSRunningApplication.runningApplications(withBundleIdentifier: "space.thelaunch.screenshottool")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
