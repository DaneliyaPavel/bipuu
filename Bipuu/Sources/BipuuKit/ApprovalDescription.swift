import Foundation

// MARK: - What a person is asked to authorise
//
// An approval card must show the operation itself, not a label for it. These types turn the
// agent's tool call into text a human can judge, keep it complete up to a generous cap, and say
// out loud when anything was cut. Pure Foundation: no UI, no I/O, unit-tested standalone.

struct ApprovalDescription: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var label: String
        var value: String
    }

    /// Short category: "Run a shell command", "Edit a file"…
    var action: String
    /// The thing being authorised, as complete as the cap allows: the command, path, URL…
    var primary: String
    /// Further things worth reading before saying yes (directory, replaced text, new content…).
    var fields: [Field]
    /// True when `primary` or a field was cut at `ApprovalDescriber.capBytes`.
    var truncated: Bool
    /// Size in bytes of the largest value before it was cut (0 when nothing was cut).
    var originalBytes: Int

    var primaryLineCount: Int { primary.isEmpty ? 0 : primary.split(separator: "\n", omittingEmptySubsequences: false).count }
}

enum ApprovalDescriber {
    /// Per value. A command or a file body beyond this is not shown whole, and the card says so.
    static let capBytes = 16_384

    static func describe(tool: String, input: [String: Any], cwd: String = "") -> ApprovalDescription {
        var fields: [ApprovalDescription.Field] = []
        var truncated = false
        var largest = 0

        /// Sanitises and caps one value; records truncation.
        func clip(_ raw: String) -> String {
            let clean = sanitizeForDisplay(raw)
            let size = clean.utf8.count
            guard size > capBytes else { return clean }
            truncated = true
            largest = max(largest, size)
            return String(decoding: Array(clean.utf8.prefix(capBytes)), as: UTF8.self)
                .replacingOccurrences(of: "\u{FFFD}", with: "")
        }
        func str(_ key: String) -> String? { input[key] as? String }
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(.init(label: label, value: clip(value)))
        }
        func finish(action: String, primary: String) -> ApprovalDescription {
            ApprovalDescription(action: action, primary: clip(primary), fields: fields,
                                truncated: truncated, originalBytes: truncated ? largest : 0)
        }

        switch tool {
        case "Bash":
            add("Why", str("description"))
            add("Directory", cwd.isEmpty ? nil : cwd)
            if input["run_in_background"] as? Bool == true { add("Mode", "runs in the background") }
            return finish(action: "Run a shell command", primary: str("command") ?? "")

        case "Edit":
            add("Replaces", str("old_string"))
            add("With", str("new_string"))
            if input["replace_all"] as? Bool == true { add("Scope", "every occurrence in the file") }
            return finish(action: "Edit a file", primary: str("file_path") ?? "")

        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            add("Edits", "\(edits.count)")
            for (i, e) in edits.prefix(5).enumerated() {
                add("Edit \(i + 1) replaces", e["old_string"] as? String)
                add("Edit \(i + 1) with", e["new_string"] as? String)
            }
            if edits.count > 5 { add("Not shown", "\(edits.count - 5) more edit(s)"); truncated = true }
            return finish(action: "Edit a file (several changes)", primary: str("file_path") ?? "")

        case "Write":
            let content = str("content") ?? ""
            add("Writes", "\(content.utf8.count) bytes, \(content.split(separator: "\n", omittingEmptySubsequences: false).count) line(s)")
            add("Content", content)
            return finish(action: "Write a file", primary: str("file_path") ?? "")

        case "NotebookEdit":
            add("Mode", str("edit_mode"))
            add("Cell", str("cell_id"))
            add("New source", str("new_source"))
            return finish(action: "Edit a notebook", primary: str("notebook_path") ?? "")

        case "Read":
            return finish(action: "Read a file", primary: str("file_path") ?? "")
        case "Glob":
            add("In", str("path"))
            return finish(action: "Find files", primary: str("pattern") ?? "")
        case "Grep":
            add("In", str("path"))
            add("Files", str("glob"))
            return finish(action: "Search file contents", primary: str("pattern") ?? "")
        case "LS":
            return finish(action: "List a directory", primary: str("path") ?? "")

        case "WebFetch":
            add("Asks", str("prompt"))
            return finish(action: "Fetch a URL", primary: str("url") ?? "")
        case "WebSearch":
            return finish(action: "Search the web", primary: str("query") ?? "")

        case "Task", "Agent":
            add("Agent", str("subagent_type"))
            add("Prompt", str("prompt"))
            return finish(action: "Start a sub-agent", primary: str("description") ?? "")

        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? "?"
                let name = parts.dropFirst().joined(separator: "__")
                add("Arguments", prettyJSON(input))
                return finish(action: "Use an MCP tool", primary: "\(server) › \(name.isEmpty ? "?" : name)")
            }
            add("Input", prettyJSON(input))
            return finish(action: "Use the \(tool) tool", primary: tool)
        }
    }

    /// Stable, readable rendering of a tool input.
    static func prettyJSON(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Makes text safe to put in front of a person deciding whether to allow it: invisible and
    /// direction-changing characters are shown as visible escapes, so a command cannot read
    /// differently from what it does. Newlines and tabs are kept.
    static func sanitizeForDisplay(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            let v = sc.value
            let hidden =
                (v < 0x20 && v != 0x0A && v != 0x09) || v == 0x7F ||
                (0x200B...0x200F).contains(v) ||     // zero-width, LRM, RLM
                (0x202A...0x202E).contains(v) ||     // bidi embeddings and overrides
                (0x2060...0x2064).contains(v) ||     // word joiner, invisible operators
                (0x2066...0x2069).contains(v) ||     // bidi isolates
                v == 0xFEFF || v == 0x00AD
            if hidden {
                out.append(contentsOf: "⟨U+\(String(format: "%04X", v))⟩".unicodeScalars)
            } else {
                out.append(sc)
            }
        }
        return String(out)
    }
}

// MARK: - What "Always" would create

/// One change the agent proposes to its own permission rules if the user picks "Always".
struct AlwaysRule: Equatable, Sendable {
    /// What will be allowed, e.g. "Allow Bash: git status:*".
    var text: String
    /// Where it will be kept, e.g. "saved in .claude/settings.local.json (this project, not shared)".
    var scope: String
}

struct AlwaysScope: Equatable, Sendable {
    var rules: [AlwaysRule]
    /// False when at least one suggestion is of a kind we cannot describe exactly. "Always" is
    /// then not offered: nobody should create a rule they cannot read.
    var fullyUnderstood: Bool

    var isOffered: Bool { fullyUnderstood && !rules.isEmpty }

    static let none = AlwaysScope(rules: [], fullyUnderstood: true)

    /// Parses the agent's `permission_suggestions` (Claude Code's `updatedPermissions` format).
    static func parse(suggestions: Any?) -> AlwaysScope {
        guard let list = suggestions as? [[String: Any]], !list.isEmpty else { return .none }
        var rules: [AlwaysRule] = []
        var understood = true
        for s in list {
            let type = s["type"] as? String ?? ""
            let scope = describeDestination(s["destination"] as? String)
            switch type {
            case "addRules", "replaceRules":
                let behavior = (s["behavior"] as? String ?? "allow").lowercased()
                let verb = behavior == "allow" ? "Allow" : behavior == "deny" ? "Deny" : "Ask for"
                let items = s["rules"] as? [[String: Any]] ?? []
                if items.isEmpty { understood = false }
                // Only an allow-rule is something "Always" should ever create.
                if behavior != "allow" { understood = false }
                for r in items {
                    let tool = r["toolName"] as? String ?? "?"
                    let content = r["ruleContent"] as? String
                    let text = content.map { "\(verb) \(tool): \(ApprovalDescriber.sanitizeForDisplay($0))" }
                        ?? "\(verb) every use of \(tool)"
                    rules.append(.init(text: text, scope: scope))
                }
            case "setMode":
                let mode = s["mode"] as? String ?? "?"
                rules.append(.init(text: "Switch the permission mode to \(mode)", scope: scope))
                understood = false   // changes the whole session's behaviour, not one rule
            case "addDirectories":
                let dirs = (s["directories"] as? [String] ?? []).map(ApprovalDescriber.sanitizeForDisplay)
                rules.append(.init(text: "Allow access to: \(dirs.joined(separator: ", "))", scope: scope))
                if dirs.isEmpty { understood = false }
            default:
                understood = false
                rules.append(.init(text: "Unrecognised change (\(ApprovalDescriber.sanitizeForDisplay(type)))", scope: scope))
            }
        }
        return AlwaysScope(rules: rules, fullyUnderstood: understood)
    }

    static func describeDestination(_ d: String?) -> String {
        switch d {
        case "session":         return "for this session only"
        case "localSettings":   return "saved in .claude/settings.local.json (this project, not shared)"
        case "projectSettings": return "saved in .claude/settings.json (this project, shared with its team)"
        case "userSettings":    return "saved in ~/.claude/settings.json (every project)"
        case "cliArg":          return "for this run only"
        case .some(let other):  return "saved to \(ApprovalDescriber.sanitizeForDisplay(other))"
        case .none:             return "location chosen by the agent"
        }
    }
}

// MARK: - Card geometry

/// How tall the approval card needs to be to show an operation without clipping it silently.
enum ApprovalLayout {
    /// Lines of the operation visible before the block scrolls.
    static let maxVisibleLines = 6
    static let lineHeight: CGFloat = 15
    static let minHeight: CGFloat = 160
    static let maxHeight: CGFloat = 300

    /// Island height for the approval card; nil outside an approval (the default layout applies).
    nonisolated(unsafe) static var height: CGFloat?

    /// Lines the scrolling block holds: the operation plus its extra fields.
    static func totalLines(for d: ApprovalDescription) -> Int {
        var n = max(1, d.primaryLineCount)
        for f in d.fields { n += 1 + f.value.split(separator: "\n", omittingEmptySubsequences: false).count }
        return n
    }

    static func visibleLines(for d: ApprovalDescription) -> Int {
        min(maxVisibleLines, totalLines(for: d))
    }

    static func height(for d: ApprovalDescription, always: AlwaysScope, offersAlways: Bool) -> CGFloat {
        let chrome: CGFloat = 52 + 20 + 30 + 10          // header + title + buttons + gaps
        var notes: CGFloat = 0
        if d.truncated { notes += 28 }                     // a visible, two-line warning
        if offersAlways { notes += CGFloat(min(2, always.rules.count + 1)) * 14 }
        let area = CGFloat(visibleLines(for: d)) * lineHeight + 12
        return min(maxHeight, max(minHeight, chrome + area + notes))
    }
}

// MARK: - Protection against accidental clicks

/// A permission card pops up when an agent asks, not when the person is ready: a click that was
/// aimed at whatever was under the pointer must not become an approval. Allowing (once or always)
/// only works after the card has been on screen for `armDelay`; denying is always possible.
enum ApprovalGuard {
    static let armDelay: TimeInterval = 0.8

    static func isArmed(shownAt: Date?, now: Date = Date()) -> Bool {
        guard let shownAt else { return false }
        return now.timeIntervalSince(shownAt) >= armDelay - 0.001   // tolerance for floating-point time arithmetic
    }

    /// Whether `decision` may be applied now. Only decisions that grant something are held back.
    static func permits(decision: String, shownAt: Date?, now: Date = Date()) -> Bool {
        switch decision {
        case "allow", "always", "answer": return isArmed(shownAt: shownAt, now: now)
        default: return true     // deny and ask never grant anything
        }
    }
}
