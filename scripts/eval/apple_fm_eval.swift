// Real on-device eval for the Apple Foundation Models chat backend.
//
// Unlike `run_eval.py` (which proxies the on-device prompts through the
// Claude API), this harness drives the *actual* Apple FM model via
// `FoundationModels` natively on macOS 26. It mirrors the app's Apple FM
// path: tool schemas built from `tools.json` the same way
// `AppleFMToolMapping` builds them, the same Apple instructions string from
// `LiveChatSessionFactory`, and Apple's native tool loop.
//
// Build & run:
//   swiftc -O -o /tmp/apple_fm_eval scripts/eval/apple_fm_eval.swift
//   /tmp/apple_fm_eval scripts/eval/tools.json scripts/eval/dataset.jsonl \
//       scripts/eval/results/apple_fm_real.json
//
// Scores (deterministic only — no tone judge):
//   tool correctness  — did the model call the expected tool (or none)?
//   param correctness — expected params present w/ right values, forbidden absent.

import Foundation
import FoundationModels

// MARK: - Dataset / tool models

struct ToolDef: Decodable {
    let name: String
    let description: String
    let input_schema: InputSchema

    struct InputSchema: Decodable {
        let properties: [String: Property]
        let required: [String]?
    }
    struct Property: Decodable {
        let type: String
        let description: String?
        let `enum`: [String]?
    }
}

struct Row: Decodable {
    let id: String
    let user: String
    let expected_tool: String?
    let expected_params: [String: JSONLite]?
    let forbid_params: [String]?
}

// Minimal JSON value for expected_params comparison.
enum JSONLite: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .other
    }
}

// MARK: - Recording tool

/// Records the first tool the model calls (name + raw JSON args) and returns
/// a benign success so Apple's loop can continue to a confirmation.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(name: String, json: String)] = []
    func record(_ name: String, _ json: String) {
        lock.lock(); calls.append((name, json)); lock.unlock()
    }
    var first: (name: String, json: String)? {
        lock.lock(); defer { lock.unlock() }; return calls.first
    }
}

@available(macOS 26.0, *)
struct EvalTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let recorder: CallRecorder

    func call(arguments: GeneratedContent) async throws -> String {
        recorder.record(name, arguments.jsonString)
        // Generic success — eval only scores the captured call, not effects.
        return "Done."
    }
}

@available(macOS 26.0, *)
func makeSchema(_ def: ToolDef) throws -> GenerationSchema {
    let required = Set(def.input_schema.required ?? [])
    let props: [DynamicGenerationSchema.Property] = def.input_schema.properties.map { (key, p) in
        let valueSchema: DynamicGenerationSchema
        if let choices = p.enum, !choices.isEmpty {
            valueSchema = DynamicGenerationSchema(name: "\(def.name)_\(key)", anyOf: choices)
        } else {
            switch p.type {
            case "integer": valueSchema = DynamicGenerationSchema(type: Int.self)
            case "number":  valueSchema = DynamicGenerationSchema(type: Double.self)
            case "boolean": valueSchema = DynamicGenerationSchema(type: Bool.self)
            default:        valueSchema = DynamicGenerationSchema(type: String.self)
            }
        }
        return DynamicGenerationSchema.Property(
            name: key, description: p.description, schema: valueSchema,
            isOptional: !required.contains(key)
        )
    }
    let root = DynamicGenerationSchema(name: def.name, description: def.description, properties: props)
    return try GenerationSchema(root: root, dependencies: [])
}

// MARK: - Apple instructions (mirrors LiveChatSessionFactory.appleInstructions)

let TODAY = "2026-04-14 09:00"
// Mirrors LiveChatSessionFactory.appleInstructions (no-profile variant).
let instructions = ProcessInfo.processInfo.environment["EVAL_PROMPT"] ?? """
You are the BabyLog Assistant. You help track a baby.
The current local date and time is \(TODAY); use local time for any dates \
you pass to tools (no timezone suffix) and assume the time is now unless \
the parent gives a specific time.
Use the provided tools to log feeds, diapers, growth, milestones, \
appointments, and pumping sessions, and to answer questions about them.
Act immediately with sensible defaults — never ask the parent a \
clarifying question for a routine log. A bare "dirty", "poo", "bm", or \
"soiled" means a dirty diaper; "wet" means a wet diaper; assume now for \
the time.
If the parent mentions more than one thing (for example a diaper and a \
feed), call a separate tool for each one.
After logging, confirm what you did in one warm, brief sentence. Never \
show internal record ids to the user.
"""

// MARK: - Scoring helpers

func numeric(_ s: String) -> Double? { Double(s) }

func paramsMatch(expected: [String: JSONLite]?, forbidden: [String]?, actualJSON: String?) -> Bool {
    guard let actualJSON,
          let data = actualJSON.data(using: .utf8),
          let actual = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return (expected?.isEmpty ?? true) && (forbidden?.isEmpty ?? true) }

    // Forbidden params must be absent (or null).
    for f in forbidden ?? [] {
        if let v = actual[f], !(v is NSNull) { return false }
    }
    // Expected params present with matching value.
    for (k, exp) in expected ?? [:] {
        guard let got = actual[k], !(got is NSNull) else { return false }
        switch exp {
        case .number(let n):
            let gd = (got as? NSNumber)?.doubleValue ?? numeric("\(got)")
            if gd == nil || abs(gd! - n) > 0.0001 { return false }
        case .string(let s):
            // Case-insensitive for enum-ish values.
            if "\(got)".lowercased() != s.lowercased() { return false }
        case .bool(let b):
            if (got as? Bool) != b { return false }
        case .other:
            break
        }
    }
    return true
}

// MARK: - Main

@available(macOS 26.0, *)
func run() async {
    let args = CommandLine.arguments
    guard args.count >= 4 else {
        FileHandle.standardError.write("usage: apple_fm_eval <tools.json> <dataset.jsonl> <out.json>\n".data(using: .utf8)!)
        exit(2)
    }
    let toolsPath = args[1], dataPath = args[2], outPath = args[3]

    let toolDefs = try! JSONDecoder().decode([ToolDef].self, from: Data(contentsOf: URL(fileURLWithPath: toolsPath)))
    let rows: [Row] = try! String(contentsOfFile: dataPath, encoding: .utf8)
        .split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(Row.self, from: Data(line.utf8))
        }

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        FileHandle.standardError.write("Apple FM unavailable: \(model.availability)\n".data(using: .utf8)!)
        exit(1)
    }

    var results: [[String: Any]] = []
    var toolHits = 0, paramHits = 0, toolAnyHits = 0

    for (i, row) in rows.enumerated() {
        let recorder = CallRecorder()
        let tools: [any Tool] = toolDefs.compactMap { def in
            guard let schema = try? makeSchema(def) else { return nil }
            return EvalTool(name: def.name, description: def.description, parameters: schema, recorder: recorder)
        }
        let session = LanguageModelSession(tools: tools, instructions: instructions)

        var replyText = ""
        var errored: String? = nil
        do {
            let resp = try await session.respond(to: row.user)
            replyText = resp.content
        } catch {
            errored = "\(error)"
        }

        let called = recorder.first?.name
        let calledJSON = recorder.first?.json
        let toolOK = (called == row.expected_tool)
        let paramOK = toolOK && paramsMatch(expected: row.expected_params, forbidden: row.forbid_params, actualJSON: calledJSON)
        // Lenient variant: credit compound requests where the expected tool is
        // among any call (the model may log a co-mentioned action first).
        let allNames = recorder.calls.map { $0.name }
        let toolAnyOK = row.expected_tool == nil ? allNames.isEmpty : allNames.contains(row.expected_tool!)
        if toolOK { toolHits += 1 }
        if paramOK { paramHits += 1 }
        if toolAnyOK { toolAnyHits += 1 }

        results.append([
            "id": row.id,
            "user": row.user,
            "expected_tool": row.expected_tool ?? NSNull(),
            "called_tool": called ?? NSNull(),
            "called_args": calledJSON ?? NSNull(),
            "tool_ok": toolOK,
            "param_ok": paramOK,
            "reply": replyText,
            "error": errored ?? NSNull(),
        ])

        let mark = toolOK ? (paramOK ? "✓" : "~") : "✗"
        FileHandle.standardError.write(
            "[\(i + 1)/\(rows.count)] \(mark) \(row.id) exp=\(row.expected_tool ?? "none") got=\(called ?? "none")\n"
                .data(using: .utf8)!
        )
    }

    let n = rows.count
    let summary: [String: Any] = [
        "backend": "apple_fm_real",
        "model": "SystemLanguageModel.default (on-device)",
        "n": n,
        "tool_accuracy": Double(toolHits) / Double(n),
        "tool_any_accuracy": Double(toolAnyHits) / Double(n),
        "param_accuracy": Double(paramHits) / Double(n),
        "today": TODAY,
    ]
    let out: [String: Any] = ["summary": summary, "results": results]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: outPath))

    print("\n=== Apple FM (on-device) eval ===")
    print(String(format: "tool accuracy:      %.1f%% (%d/%d)", 100 * Double(toolHits) / Double(n), toolHits, n))
    print(String(format: "tool-any accuracy:  %.1f%% (%d/%d)", 100 * Double(toolAnyHits) / Double(n), toolAnyHits, n))
    print(String(format: "param accuracy:     %.1f%% (%d/%d)", 100 * Double(paramHits) / Double(n), paramHits, n))
    print("wrote \(outPath)")
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("requires macOS 26+")
}
