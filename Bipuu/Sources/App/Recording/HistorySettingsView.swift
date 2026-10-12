import SwiftUI

/// The "History" page of Settings: what Bipuu records, and for how long it keeps it.
/// Changes apply to the next event; nothing needs a restart.
struct HistorySettingsView: View {
    @AppStorage(HistorySettings.recordKey) private var record = true
    @AppStorage(HistorySettings.inferKey) private var infer = true
    @AppStorage(HistorySettings.retentionKey) private var retentionDays = HistorySettings.defaultRetentionDays

    /// Where the history lives; shown, and revealed in Finder on request.
    let databasePath: String
    var reveal: () -> Void = {}

    var body: some View {
        GroupBox(String(localized: "history.recording", defaultValue: "Recording")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "history.record", defaultValue: "Record agent activity"), isOn: $record)
                Text(String(localized: "history.recordNote",
                            defaultValue: "Bipuu keeps a local log of what your agents do: which tool ran, when, in which project. It never stores prompts, commands, file paths or file contents, and nothing leaves this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(String(localized: "history.infer", defaultValue: "Suggest tasks for new sessions"), isOn: $infer)
                    .disabled(!record)
                Text(String(localized: "history.inferNote",
                            defaultValue: "Groups sessions by project and branch into tasks you can confirm in the Work view. Reads the .git folder of the directory an agent works in."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }

        GroupBox(String(localized: "history.keep", defaultValue: "Keeping")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(String(localized: "history.keepFor", defaultValue: "Keep history for"), selection: $retentionDays) {
                    Text(String(localized: "history.30", defaultValue: "30 days")).tag(30)
                    Text(String(localized: "history.90", defaultValue: "90 days")).tag(90)
                    Text(String(localized: "history.365", defaultValue: "1 year")).tag(365)
                    Text(String(localized: "history.forever", defaultValue: "As long as possible")).tag(0)
                }
                .frame(maxWidth: 320)
                Text(String(format: String(localized: "history.keepNote",
                                           defaultValue: "Older events are removed automatically. At most %@ events are kept, whatever you choose."),
                            RetentionPolicyLimits.maxEvents.formatted()))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(databasePath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(String(localized: "history.reveal", defaultValue: "Show in Finder"), action: reveal)
                }
            }
            .padding(6)
        }
    }
}

import BipuuCore
private enum RetentionPolicyLimits { static let maxEvents = RetentionPolicy.defaultMaxEvents }
