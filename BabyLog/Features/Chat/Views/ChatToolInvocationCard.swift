import SwiftUI
import BabyLogCore

// MARK: - Presentation types

/// Flat row emitted by `pairToolMessages(_:)` for the chat list to render.
/// Non-tool messages pass through untouched; matching `.call`/`.result`
/// pairs collapse into a single `ToolInvocation` so the UI can animate a
/// spinner → green-check transition on one row instead of two.
enum ChatPresentationRow: Equatable, Identifiable {
    case message(ChatMessage)
    case toolInvocation(ToolInvocation)

    var id: UUID {
        switch self {
        case let .message(m): return m.id
        case let .toolInvocation(t): return t.anchorMessageId
        }
    }
}

struct ToolInvocation: Equatable {
    /// Tool call id supplied by the model. Stable across the call/result pair.
    let toolId: String
    /// UUID of the `.call` ChatMessage (or the orphan `.result` message).
    /// Used by `ForEach` so SwiftUI can track identity across a streaming
    /// call→result transition.
    let anchorMessageId: UUID
    let name: String
    let arguments: ToolArguments
    let result: ToolResult?

    var isPending: Bool { result == nil }
    var isError: Bool { result?.isError == true }
}

/// Walk a chat history and pair `.call`/`.result` tool messages into one
/// `ToolInvocation` per tool-call id. Non-tool messages pass through in
/// their original order. Orphan `.result` entries (no preceding call) still
/// get their own row rather than being dropped.
func pairToolMessages(_ messages: [ChatMessage]) -> [ChatPresentationRow] {
    // Index results by tool id so we can attach them on the call row.
    var resultById: [String: ToolResult] = [:]
    var seenCallIds: Set<String> = []
    for m in messages {
        guard m.role == .tool, let entry = m.toolEntry else { continue }
        if case let .result(id, _, result) = entry {
            resultById[id] = result
        }
        if case let .call(id, _, _) = entry {
            seenCallIds.insert(id)
        }
    }

    var rows: [ChatPresentationRow] = []
    for m in messages {
        guard m.role == .tool, let entry = m.toolEntry else {
            rows.append(.message(m))
            continue
        }
        switch entry {
        case let .call(id, name, args):
            rows.append(.toolInvocation(ToolInvocation(
                toolId: id,
                anchorMessageId: m.id,
                name: name,
                arguments: args,
                result: resultById[id]
            )))
        case let .result(id, name, result):
            if seenCallIds.contains(id) { continue } // already attached above
            rows.append(.toolInvocation(ToolInvocation(
                toolId: id,
                anchorMessageId: m.id,
                name: name,
                arguments: ToolArguments([:]),
                result: result
            )))
        }
    }
    return rows
}

// MARK: - Card view

/// Unified tool call bubble matching the product spec:
///   - Pending: spinning indicator, gray `call` pill
///   - Success: green checkmark, green `result` pill, tinted bg
///   - Error:   red triangle, red `error` pill, red-tinted bg
///
/// Has a collapsible `Show details` disclosure that reveals arguments
/// (always) and the result body (when present).
struct ChatToolInvocationCard: View {
    let invocation: ToolInvocation

    @State private var showDetails: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if showDetails {
                detailsBlock
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1)
        )
        .padding(.leading, 24)
        .padding(.trailing, 32)
        .animation(.easeInOut(duration: 0.15), value: showDetails)
        .animation(.easeInOut(duration: 0.2), value: invocation.isPending)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 16, height: 16)

            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(invocation.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            statePill

            Spacer(minLength: 0)

            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text(showDetails ? "Hide details" : "Show details")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatToolCardDetailsToggle")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if invocation.isPending {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        } else if invocation.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var statePill: some View {
        Text(pillText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(pillFill)
            )
            .foregroundStyle(pillForeground)
    }

    private var pillText: String {
        if invocation.isPending { return "call" }
        return invocation.isError ? "error" : "result"
    }

    private var pillFill: Color {
        if invocation.isPending { return Color.secondary.opacity(0.15) }
        return invocation.isError ? Color.red.opacity(0.15) : Color.green.opacity(0.15)
    }

    private var pillForeground: Color {
        if invocation.isPending { return .secondary }
        return invocation.isError ? .red : .green
    }

    // MARK: Details

    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !invocation.arguments.values.isEmpty {
                Text("Arguments")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(formattedArguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let result = invocation.result {
                if !invocation.arguments.values.isEmpty {
                    Divider().padding(.vertical, 2)
                }
                Text(result.isError ? "Error" : "Result")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(result.isError ? .red : .secondary)
                Text(result.content.isEmpty ? "(empty)" : result.content)
                    .font(.caption.monospaced())
                    .foregroundStyle(result.isError ? .red : .primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var formattedArguments: String {
        let sorted = invocation.arguments.values.keys.sorted()
        return sorted.map { key in
            let value = invocation.arguments.values[key] ?? .null
            return "\(key): \(display(value))"
        }.joined(separator: "\n")
    }

    private func display(_ value: JSONValue) -> String {
        switch value {
        case let .string(s): return "\"\(s)\""
        case let .int(i): return "\(i)"
        case let .double(d): return "\(d)"
        case let .bool(b): return "\(b)"
        case .null: return "null"
        case .array: return "[…]"
        case .object: return "{…}"
        }
    }

    // MARK: Background / a11y

    private var backgroundTint: Color {
        if invocation.isPending { return Color(.secondarySystemBackground) }
        return invocation.isError
            ? Color.red.opacity(0.06)
            : Color.green.opacity(0.07)
    }

    private var borderTint: Color {
        if invocation.isPending { return Color.secondary.opacity(0.2) }
        return invocation.isError
            ? Color.red.opacity(0.3)
            : Color.green.opacity(0.3)
    }

    private var accessibilityIdentifier: String {
        if invocation.isPending { return "chatToolCardPending" }
        return invocation.isError ? "chatToolCardError" : "chatToolCardResult"
    }

    private var accessibilityLabel: String {
        if invocation.isPending {
            return "Tool call pending: \(invocation.name)"
        }
        if invocation.isError {
            return "Tool call failed: \(invocation.name). \(invocation.result?.content ?? "")"
        }
        return "Tool call complete: \(invocation.name)"
    }
}

// MARK: - Previews

#Preview("Pending") {
    ChatToolInvocationCard(invocation: ToolInvocation(
        toolId: "t1",
        anchorMessageId: UUID(),
        name: "createFeedLog",
        arguments: ToolArguments(["volumeMl": .int(60)]),
        result: nil
    ))
    .padding()
}

#Preview("Success") {
    ChatToolInvocationCard(invocation: ToolInvocation(
        toolId: "t1",
        anchorMessageId: UUID(),
        name: "createFeedLog",
        arguments: ToolArguments(["volumeMl": .int(60)]),
        result: ToolResult(content: "Logged 60 ml. id=abc", isError: false)
    ))
    .padding()
}

#Preview("Error") {
    ChatToolInvocationCard(invocation: ToolInvocation(
        toolId: "t1",
        anchorMessageId: UUID(),
        name: "createFeedLog",
        arguments: ToolArguments(["volumeMl": .int(9999)]),
        result: ToolResult(content: "volumeOutOfRange", isError: true)
    ))
    .padding()
}
