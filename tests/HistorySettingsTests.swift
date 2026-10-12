import Foundation
import SwiftUI
import AppKit
import BipuuCore

@main @MainActor
struct HistorySettingsTests {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    static func suite() -> UserDefaults {
        let name = "bipuu.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func render(to path: String, flip: ((UserDefaults) -> Void)? = nil) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        if let flip { flip(.standard) }
        let size = NSSize(width: 520, height: 430)
        let view = ScrollView { VStack(alignment: .leading, spacing: 14) {
            HistorySettingsView(databasePath: "/Users/me/Library/Application Support/Bipuu/bipuu.sqlite")
        }.padding(20) }
        .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        return rep
    }

    static func darkPixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent + c.greenComponent + c.blueComponent < 1.0 { n += 1 }       // text on a light window
        } }
        return n
    }

    static func main() {
        let none: [String: String] = [:]

        // Defaults: everything on, 90 days.
        let d = suite()
        check(HistorySettings.recordingEnabled(defaults: d, environment: none), "recording is on by default")
        check(HistorySettings.inferenceEnabled(defaults: d, environment: none), "task suggestions are on by default")
        check(HistorySettings.retentionDays(defaults: d) == 90, "90 days by default")
        let defaultPolicy = HistorySettings.retentionPolicy(defaults: d)
        check(defaultPolicy.maxAge == 90 * 86_400 && defaultPolicy.maxEvents == RetentionPolicy.defaultMaxEvents, "default policy \(defaultPolicy)")

        // The choices apply immediately.
        d.set(false, forKey: HistorySettings.recordKey)
        check(!HistorySettings.recordingEnabled(defaults: d, environment: none), "switch recording off")
        check(!HistorySettings.inferenceEnabled(defaults: d, environment: none), "no recording, no task suggestions")
        check(HistorySettings.inferencePolicy(defaults: d, environment: none) == nil, "so no inference policy")
        d.set(true, forKey: HistorySettings.recordKey)
        d.set(false, forKey: HistorySettings.inferKey)
        check(HistorySettings.recordingEnabled(defaults: d, environment: none) && !HistorySettings.inferenceEnabled(defaults: d, environment: none), "suggestions off on their own")
        d.set(true, forKey: HistorySettings.inferKey)
        let policy = HistorySettings.inferencePolicy(defaults: d, environment: none, home: "/Users/me")
        check(policy?.excludedRoots == ["/", "/Users/me"], "the root and home are never projects")

        // Retention choices, including "forever", and values that are not offered.
        for (days, age) in [(30, 30.0 * 86_400), (90, 90 * 86_400), (365, 365 * 86_400)] {
            d.set(days, forKey: HistorySettings.retentionKey)
            check(HistorySettings.retentionDays(defaults: d) == days && HistorySettings.retentionPolicy(defaults: d).maxAge == age, "\(days) days")
        }
        d.set(0, forKey: HistorySettings.retentionKey)
        let forever = HistorySettings.retentionPolicy(defaults: d)
        check(forever.maxAge == nil && forever.maxEvents == RetentionPolicy.defaultMaxEvents, "forever still has the count cap: \(forever)")
        for bad: Any in [7, -1, 100_000, "ninety", 3.5] {
            d.set(bad, forKey: HistorySettings.retentionKey)
            check(HistorySettings.retentionDays(defaults: d) == 90, "\(bad) falls back to 90 days")
        }
        check(HistorySettings.retentionChoices.contains(HistorySettings.defaultRetentionDays), "the default is one of the choices")

        // Environment overrides can only switch things off.
        let fresh = suite()
        check(!HistorySettings.recordingEnabled(defaults: fresh, environment: ["BIPUU_RECORD_EVENTS": "0"]), "env switches recording off")
        check(!HistorySettings.inferenceEnabled(defaults: fresh, environment: ["BIPUU_INFER_TASKS": "0"]), "env switches suggestions off")
        check(HistorySettings.recordingEnabled(defaults: fresh, environment: ["BIPUU_RECORD_EVENTS": "1"]), "env cannot force it on past a default of on")
        let off = suite(); off.set(false, forKey: HistorySettings.recordKey)
        check(!HistorySettings.recordingEnabled(defaults: off, environment: ["BIPUU_RECORD_EVENTS": "1"]), "env cannot override the user's off")

        // The settings page draws (a blank picture would have almost no dark text pixels).
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
        let page = render(to: out + "/history-settings.png")
        check(page != nil && darkPixels(page!) > 1_500, "the page draws text (\(page.map(darkPixels) ?? 0) dark pixels)")

        if failures == 0 { print("History settings: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}
