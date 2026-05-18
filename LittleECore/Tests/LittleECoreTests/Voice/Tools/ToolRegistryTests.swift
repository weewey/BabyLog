import XCTest
@testable import LittleECore
import Foundation

private struct StubTool: ChatTool {
    let name: String
    let description: String
    let inputSchema = ToolInputSchema(properties: [], required: [])
    let requiresConfirmation: Bool
    let resultContent: String

    init(name: String, description: String = "", requiresConfirmation: Bool = false, resultContent: String = "") {
        self.name = name
        self.description = description
        self.requiresConfirmation = requiresConfirmation
        self.resultContent = resultContent
    }

    func execute(arguments: ToolArguments) async throws -> ToolResult {
        ToolResult(content: resultContent)
    }
}

final class ToolRegistryTests: XCTestCase {

    func test_registry_returnsToolByName() {
        let registry = ToolRegistry([
            StubTool(name: "createFeedLog"),
            StubTool(name: "createDiaperLog"),
        ])

        XCTAssertEqual(registry.tool(named: "createFeedLog")?.name, "createFeedLog")
        XCTAssertEqual(registry.tool(named: "createDiaperLog")?.name, "createDiaperLog")
    }

    func test_registry_returnsNilForUnknownName() {
        let registry = ToolRegistry([StubTool(name: "createFeedLog")])

        XCTAssertNil(registry.tool(named: "nope"))
    }

    func test_registry_preservesInsertionOrder() {
        let registry = ToolRegistry([
            StubTool(name: "a"),
            StubTool(name: "b"),
            StubTool(name: "c"),
        ])

        XCTAssertEqual(registry.all.map(\.name), ["a", "b", "c"])
    }

    func test_registry_lastDuplicateNameWins() {
        let registry = ToolRegistry([
            StubTool(name: "k", resultContent: "first"),
            StubTool(name: "k", resultContent: "second"),
        ])

        XCTAssertEqual(registry.all.count, 1)
        let tool = registry.tool(named: "k") as? StubTool
        XCTAssertEqual(tool?.resultContent, "second")
    }
}
