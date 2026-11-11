import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    exit(SelfTest.run(reportPath: out))
}

if arguments.contains("--redact-bench") {
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    exit(RedactBench.run(reportPath: value("--out"), dumpDir: value("--dump")))
}

if let index = arguments.firstIndex(of: "--render-iconset") {
    let path = arguments.count > index + 1 ? arguments[index + 1] : "/tmp/AppIcon.iconset"
    let ok = MainActor.assumeIsolated {
        _ = NSApplication.shared
        return renderIconset(to: path)
    }
    exit(ok ? 0 : 1)
}

if let index = arguments.firstIndex(of: "--editor-test"), index + 1 < arguments.count {
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    MainActor.assumeIsolated {
        SelfTest.editor(image: arguments[index + 1], out: value("--out"), click: value("--click").flatMap { Int($0) },
                        hover: value("--hover").flatMap { Int($0) }, background: value("--background").flatMap(PostStyle.Background.init(rawValue:)))
    }
}

if let index = arguments.firstIndex(of: "--demo") {
    let dir = arguments.count > index + 1 ? arguments[index + 1] : "/tmp/screenshottool-demo"
    exit(MainActor.assumeIsolated { Demo.run(dir: dir) })
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
