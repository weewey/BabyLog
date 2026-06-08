import XCTest
import BabyLogCore
@testable import BabyLog

final class ChatBackendDefaultingTests: XCTestCase {

    private final class Store: ChatBackendPreferenceStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
    }

    func test_appleUnavailable_defaultsToGemma_andDoesNotMigrate() {
        let store = Store()
        store.values[ChatBackendDefaulting.selectedBackendKey] = "gemma"

        let resolved = ChatBackendDefaulting.resolveDefault(store: store, appleAvailable: false)

        XCTAssertEqual(resolved, .gemma)
        XCTAssertEqual(store.values[ChatBackendDefaulting.selectedBackendKey], "gemma")
        XCTAssertNil(store.values[ChatBackendDefaulting.migrationKey])
    }

    func test_appleAvailable_freshInstall_defaultsToApple() {
        let store = Store()

        let resolved = ChatBackendDefaulting.resolveDefault(store: store, appleAvailable: true)

        XCTAssertEqual(resolved, .apple)
        // No explicit selection existed, so none is written — the default applies.
        XCTAssertNil(store.values[ChatBackendDefaulting.selectedBackendKey])
        XCTAssertEqual(store.values[ChatBackendDefaulting.migrationKey], "done")
    }

    func test_appleAvailable_migratesExistingGemmaSelectionToApple_once() {
        let store = Store()
        store.values[ChatBackendDefaulting.selectedBackendKey] = "gemma"

        _ = ChatBackendDefaulting.resolveDefault(store: store, appleAvailable: true)

        XCTAssertEqual(store.values[ChatBackendDefaulting.selectedBackendKey], "apple")
        XCTAssertEqual(store.values[ChatBackendDefaulting.migrationKey], "done")
    }

    func test_migration_runsOnlyOnce_respectsLaterGemmaChoice() {
        let store = Store()
        store.values[ChatBackendDefaulting.selectedBackendKey] = "gemma"

        // First resolve migrates to Apple.
        _ = ChatBackendDefaulting.resolveDefault(store: store, appleAvailable: true)
        // User then deliberately switches back to Gemma.
        store.values[ChatBackendDefaulting.selectedBackendKey] = "gemma"
        // Second resolve must NOT override their choice again.
        _ = ChatBackendDefaulting.resolveDefault(store: store, appleAvailable: true)

        XCTAssertEqual(store.values[ChatBackendDefaulting.selectedBackendKey], "gemma")
    }
}
