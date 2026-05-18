import Foundation

/// Tool wrapping `GrowthMeasurementRepository.save`. At least one of
/// `weightGrams`, `heightCm`, or `headCircumferenceCm` must be present.
public struct CreateGrowthMeasurementTool: ChatTool {

    public let name = "createGrowthMeasurement"
    public let description = "Record a growth measurement. Provide at least one of weight (grams), height (cm), or head circumference (cm)."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("weightGrams", .init(type: .integer, description: "Weight in grams (500–15000).")),
            ("heightCm", .init(type: .number, description: "Length / height in centimetres (20–120).")),
            ("headCircumferenceCm", .init(type: .number, description: "Head circumference in centimetres (20–60).")),
            ("measuredAt", .init(type: .string, description: "Local time as yyyy-MM-ddTHH:mm:ss (no Z suffix). Defaults to now.")),
        ],
        required: []
    )

    private let repository: any GrowthMeasurementRepository
    private let clock: any Clock

    public init(repository: any GrowthMeasurementRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let weight = try arguments.optionalInt("weightGrams")
        let height = try arguments.optionalDouble("heightCm")
        let head = try arguments.optionalDouble("headCircumferenceCm")
        let measuredAt = try arguments.optionalDate("measuredAt") ?? clock.now()

        guard weight != nil || height != nil || head != nil else {
            throw ChatToolError.executionFailed("At least one of weightGrams, heightCm, or headCircumferenceCm must be supplied.")
        }

        let measurement = try GrowthMeasurement(
            date: measuredAt,
            weightGrams: weight,
            heightCm: height,
            headCircumferenceCm: head
        )
        try await repository.save(measurement)
        let all = try await repository.all()

        let summary = Self.summarizeForModel(justSaved: measurement, all: all)
        return ToolResult(content: summary)
    }

    static func summarizeForModel(
        justSaved: GrowthMeasurement,
        all: [GrowthMeasurement]
    ) -> String {
        // Prior measurements = everything strictly before the one we
        // just saved, ordered newest-first so we can search for the
        // most recent value on each axis.
        let prior = all
            .filter { $0.id.value != justSaved.id.value && $0.date < justSaved.date }
            .sorted { $0.date > $1.date }

        var parts: [String] = []
        parts.append("Logged growth measurement:")
        var measured: [String] = []
        var deltas: [String] = []

        if let w = justSaved.weightGrams {
            let kg = Double(w) / 1000.0
            measured.append(String(format: "%.2f kg", kg))
            if let prevW = prior.first(where: { $0.weightGrams != nil })?.weightGrams {
                let d = w - prevW
                if d != 0 {
                    let sign = d > 0 ? "+" : "−"
                    deltas.append("\(sign)\(abs(d)) g since last")
                }
            }
        }
        if let h = justSaved.heightCm {
            measured.append(String(format: "%.1f cm", h))
            if let prevH = prior.first(where: { $0.heightCm != nil })?.heightCm {
                let d = h - prevH
                if abs(d) >= 0.05 {
                    let sign = d > 0 ? "+" : "−"
                    deltas.append(String(format: "\(sign)%.1f cm height", abs(d)))
                }
            }
        }
        if let hc = justSaved.headCircumferenceCm {
            measured.append(String(format: "head %.1f cm", hc))
            if let prevHc = prior.first(where: { $0.headCircumferenceCm != nil })?.headCircumferenceCm {
                let d = hc - prevHc
                if abs(d) >= 0.05 {
                    let sign = d > 0 ? "+" : "−"
                    deltas.append(String(format: "\(sign)%.1f cm head", abs(d)))
                }
            }
        }
        parts.append(measured.joined(separator: ", ") + ".")
        if !deltas.isEmpty {
            parts.append("Change: " + deltas.joined(separator: ", ") + ".")
        }
        if let mostRecent = prior.first {
            let days = Int(justSaved.date.timeIntervalSince(mostRecent.date) / 86400)
            if days >= 1 {
                parts.append("\(days) day\(days == 1 ? "" : "s") since last measurement.")
            }
        } else {
            parts.append("First growth measurement on record.")
        }
        parts.append("id=\(justSaved.id.value.uuidString)")
        return parts.joined(separator: " ")
    }
}
