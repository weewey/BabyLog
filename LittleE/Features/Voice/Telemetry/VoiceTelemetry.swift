import Foundation
import LittleECore

/// In-memory rolling log of voice capture events. Local only, never shipped
/// off-device. Surfaced via the debug pane in Settings (gated behind a toggle).
@Observable
final class VoiceTelemetry: @unchecked Sendable {

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let transcript: String
        let parsed: String
        let userCorrected: Bool
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 200

    func record(transcript: String, parsed: ToolUse, userCorrected: Bool = false) {
        let entry = Entry(
            timestamp: Date(),
            transcript: transcript,
            parsed: String(describing: parsed),
            userCorrected: userCorrected
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }
}
