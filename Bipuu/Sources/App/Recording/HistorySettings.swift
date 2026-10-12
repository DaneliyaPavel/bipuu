import Foundation
import BipuuCore

/// The user's choices about the local history, in one place: what the keys are, what they default to,
/// and what policies they mean. UserDefaults and the environment are parameters so this is testable.
///
/// Environment overrides (used by scripts and tests; they win over the stored choice, and can only switch things off):
/// `BIPUU_RECORD_EVENTS=0`, `BIPUU_INFER_TASKS=0`.
enum HistorySettings {
    static let recordKey = "recordEvents"
    static let inferKey = "inferTasks"
    static let retentionKey = "historyRetentionDays"

    /// Days to keep events; 0 means "no age limit". The count cap (`RetentionPolicy.defaultMaxEvents`) always applies.
    static let retentionChoices = [30, 90, 365, 0]
    static let defaultRetentionDays = 90

    static func recordingEnabled(defaults: UserDefaults = .standard,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["BIPUU_RECORD_EVENTS"] == "0" { return false }
        return defaults.object(forKey: recordKey) as? Bool ?? true
    }

    /// Proposing tasks needs the recording it is based on.
    static func inferenceEnabled(defaults: UserDefaults = .standard,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard recordingEnabled(defaults: defaults, environment: environment) else { return false }
        if environment["BIPUU_INFER_TASKS"] == "0" { return false }
        return defaults.object(forKey: inferKey) as? Bool ?? true
    }

    /// A stored value that is not one of the offered choices (hand-edited, from the future) falls back to the default.
    static func retentionDays(defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: retentionKey) as? Int, retentionChoices.contains(stored) else {
            return defaultRetentionDays
        }
        return stored
    }

    static func retentionPolicy(defaults: UserDefaults = .standard) -> RetentionPolicy {
        let days = retentionDays(defaults: defaults)
        return RetentionPolicy(maxAge: days > 0 ? TimeInterval(days) * 86_400 : nil, maxEvents: RetentionPolicy.defaultMaxEvents)
    }

    /// `nil` when proposing tasks is off. The file system root and the home directory are never projects.
    static func inferencePolicy(defaults: UserDefaults = .standard,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory()) -> InferencePolicy? {
        inferenceEnabled(defaults: defaults, environment: environment) ? InferencePolicy(excludedRoots: ["/", home]) : nil
    }
}
