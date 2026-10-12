import Foundation
import SwiftUI
import AppKit
import BipuuCore

@main @MainActor
struct WorkOverviewTests {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }

    static func row(_ title: String, origin: TaskOrigin = .explicit, sessions: Int = 1, working: Int = 0, live: Int? = nil,
                    approvals: Int = 0, questions: Int = 0, last: Date? = nil) -> TaskRow {
        let task = WorkTask(id: TaskID(title), title: title, origin: origin, createdAt: ago(86_400), updatedAt: ago(7_200))
        return TaskRow(task: task, summary: TaskSummary(taskID: task.id, sessionCount: sessions, workingSessionCount: working,
                                                        liveSessionCount: live ?? sessions, pendingApprovalCount: approvals,
                                                        openQuestionCount: questions, lastEventAt: last))
    }

    /// A realistic overview: attention first, a proposal, finished work, loose sessions, overflow.
    static func fixture() -> WorkOverview {
        func p(_ n: String) -> Project { Project(id: ProjectID(n), name: n, roots: ["/code/\(n)"], createdAt: ago(900_000)) }
        return WorkOverview(groups: [
            ProjectGroup(project: p("bipuu"), tasks: [
                row("Ship the importer", sessions: 2, working: 1, approvals: 1, last: ago(20)),
                row("bipuu · feature/island-work", origin: .inferred, sessions: 1, working: 1, last: ago(190)),
                row("Fix flaky relay test", sessions: 3, live: 0, last: ago(5_400)),
            ]),
            ProjectGroup(project: p("web-app"), tasks: [
                row("web-app · main", origin: .inferred, sessions: 2, live: 2, questions: 1, last: ago(3_600)),
            ]),
            ProjectGroup(project: nil, tasks: [row("Scratch notes", sessions: 0)]),
        ], unattachedSessionCount: 2, hiddenTaskCount: 3)
    }

    /// Draws the view into a bitmap the way the app does (an NSHostingView), because `ImageRenderer`
    /// cannot draw a ScrollView. Returns nil if nothing could be drawn.
    static func render(_ overview: WorkOverview, to path: String) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let size = NSSize(width: 640, height: 160)
        let view = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22).fill(Color(hex: "#0B0C0F"))
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#15171B")).padding(.horizontal, 8).padding(.top, 36).padding(.bottom, 8)
            WorkOverviewList(overview: overview, now: now)
                .padding(.leading, 98).padding(.trailing, 16).padding(.top, 42).padding(.bottom, 14)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))     // let SwiftUI finish its first layout pass
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        return rep
    }

    /// Pixels that are clearly lighter than the dark card: the text, dots and icons. A blank render has none.
    static func brightPixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { n += 1 }
            }
        }
        return n
    }

    static func main() {
        // Sentences.
        check(WorkText.summary(row("a", sessions: 2, working: 1)) == "2 sessions · 1 working", WorkText.summary(row("a", sessions: 2, working: 1)))
        check(WorkText.summary(row("a", sessions: 1)) == "1 session · idle", WorkText.summary(row("a")))
        check(WorkText.summary(row("a", sessions: 3, live: 0)) == "3 sessions · finished", WorkText.summary(row("a", sessions: 3, live: 0)))
        check(WorkText.summary(row("a", sessions: 0)) == "No sessions", "no sessions")
        check(WorkText.summary(row("a", sessions: 2, working: 1, approvals: 1)) == "Needs you · 1 approval · 2 sessions", WorkText.summary(row("a", sessions: 2, working: 1, approvals: 1)))
        check(WorkText.summary(row("a", approvals: 3)).hasPrefix("Needs you · 3 approvals"), WorkText.summary(row("a", approvals: 3)))
        check(WorkText.summary(row("a", questions: 1)) == "Needs you · question · 1 session", WorkText.summary(row("a", questions: 1)))
        check(WorkText.age(of: ago(10), now: now) == "now", "just now")
        for seconds in [300.0, 7_200, 200_000] {
            let a = WorkText.age(of: ago(seconds), now: now)
            check(!a.isEmpty && a != "now" && !a.contains("-") && !a.contains("\u{2212}") && a.rangeOfCharacter(from: .decimalDigits) != nil,
                  "age of \(seconds) s: \"\(a)\"")
        }
        check(WorkText.age(of: .distantPast, now: now).isEmpty, "never active")
        check(WorkText.age(of: now.addingTimeInterval(60), now: now).isEmpty, "clock in the future")
        check(WorkText.unattached(1) == "1 session without a task" && WorkText.unattached(4) == "4 sessions without a task", "unattached")
        check(WorkText.hidden(3) == "+3 more tasks", "hidden")
        let spoken = WorkText.spoken(row("Fix it", origin: .inferred, approvals: 1, last: ago(60)), now: now)
        check(spoken.contains("Fix it") && spoken.contains("Needs you") && spoken.contains("Proposed by Bipuu"), spoken)

        // Rendering: the populated list and the empty state really draw something.
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
        let full = render(fixture(), to: out + "/work-overview.png")
        check(full != nil && brightPixels(full!) > 800, "populated list draws text (\(full.map(brightPixels) ?? 0) bright pixels)")
        let empty = render(WorkOverview(groups: [], unattachedSessionCount: 0, hiddenTaskCount: 0), to: out + "/work-overview-empty.png")
        check(empty != nil && brightPixels(empty!) > 200, "empty state draws text")
        let blank = render(WorkOverview(groups: [ProjectGroup(project: nil, tasks: [])], unattachedSessionCount: 0, hiddenTaskCount: 0), to: out + "/work-overview-blank.png")
        check(blank != nil && brightPixels(blank!) < brightPixels(full!) / 10, "the check can tell a blank picture from a full one")
        let attention = render(WorkOverview(groups: [ProjectGroup(project: nil, tasks: [row("Needs a decision", approvals: 2, last: ago(30))])],
                                            unattachedSessionCount: 0, hiddenTaskCount: 0), to: out + "/work-overview-attention.png")
        check(attention != nil && brightPixels(attention!) > 150, "attention row draws")

        if failures == 0 { print("Work overview: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}
