import AppKit
import SwiftUI

// `ScreenControl --snapshot out.png [--dark] [--reference]` renders the panel with sample data
// and exits. `--reference` uses the Italian strings and layout of the system menu screenshot,
// for pixel comparison.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Snapshot.render(to: CommandLine.arguments[index + 1],
                    dark: CommandLine.arguments.contains("--dark"),
                    reference: CommandLine.arguments.contains("--reference")) }
    exit(0)
}
if CommandLine.arguments.contains("--selftest-persist") {
    SelfTest.runPersist()
    exit(0)
}
if CommandLine.arguments.contains("--selftest-power") {
    SelfTest.runPower()
    exit(0)
}
if CommandLine.arguments.contains("--selftest-writes") {
    SelfTest.runWrites()
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
