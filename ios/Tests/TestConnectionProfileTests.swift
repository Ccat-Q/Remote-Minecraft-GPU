import XCTest
@testable import RemoteGPUProtocol

// In-memory fixtures test app policy, NOT iPhone Keychain persistence/signing.
private final class TestCredentialVault: RemoteGPUCredentialVault, @unchecked Sendable {
    var data: Data?
    var fail = false
    func read() throws -> Data? {
        if fail { throw RemoteGPUTestProfileError.keychain(-25308) }
        return data
    }
    func write(_ data: Data) throws {
        if fail { throw RemoteGPUTestProfileError.keychain(-25308) }
        self.data = data
    }
    func clear() throws {
        if fail { throw RemoteGPUTestProfileError.keychain(-25308) }
        data = nil
    }
}

final class TestConnectionProfileTests: XCTestCase {
    func testFirstSetupReplaceLoadFromNewStoreAndClear() throws {
        let vault = TestCredentialVault()
        let store = RemoteGPUTestProfileStore(vault: vault)
        XCTAssertNil(try store.load())
        let first = try RemoteGPUTestProfile(host: " example.test ", port: 4434, token: "synthetic-first-token")
        try store.save(first)
        let loaded = try XCTUnwrap(RemoteGPUTestProfileStore(vault: vault).load())
        XCTAssertEqual(loaded.host, "example.test")
        XCTAssertEqual(loaded.port, 4434)
        XCTAssertEqual(loaded.token, first.token)
        try store.save(RemoteGPUTestProfile(host: "other.test", port: 4435, token: "synthetic-replacement"))
        XCTAssertEqual(try store.load()?.host, "other.test")
        XCTAssertEqual(try store.load()?.token, "synthetic-replacement")
        try store.clear()
        XCTAssertNil(try store.load())
        try store.clear() // Clearing an absent record is idempotent.
    }

    func testInvalidInputAndTokenNotSilentlyTrimmed() throws {
        for token in ["", " leading", "trailing ", "embedded\nnewline", "embedded\0nul", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try RemoteGPUTestProfile(host: "example.test", port: 4434, token: token))
        }
        for host in ["", " ", "https://example.test", "two hosts.test", "line\nfeed.test", "bad\0host.test"] {
            XCTAssertThrowsError(try RemoteGPUTestProfile(host: host, port: 4434, token: "synthetic"))
        }
        XCTAssertThrowsError(try RemoteGPUTestProfile(host: "example.test", port: 0, token: "synthetic"))
    }

    func testDecodedCorruptionIsRevalidatedAndNeverPrinted() throws {
        let vault = TestCredentialVault()
        let store = RemoteGPUTestProfileStore(vault: vault)
        for value in ["not JSON synthetic-secret", "{\"host\":\"example.test\",\"port\":0,\"token\":\"synthetic-secret\"}",
                      "{\"host\":\"example.test\",\"port\":4434,\"token\":\" synthetic-secret \"}"] {
            vault.data = Data(value.utf8)
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            }
        }
    }

    func testKeychainErrorsFailClosedAndFailedUpdateKeepsPreviousValue() throws {
        let vault = TestCredentialVault()
        let store = RemoteGPUTestProfileStore(vault: vault)
        let first = try RemoteGPUTestProfile(host: "example.test", port: 4434, token: "synthetic-first")
        try store.save(first)
        let previous = vault.data
        vault.fail = true
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(RemoteGPUTestProfile(host: "other.test", port: 4435, token: "synthetic-next")))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(vault.data, previous) // No delete-before-write or plaintext fallback.
        vault.fail = false
        XCTAssertEqual(try store.load()?.token, first.token)
    }

    func testDescriptionsRedactCredential() throws {
        let profile = try RemoteGPUTestProfile(host: "example.test", port: 4434, token: "synthetic-do-not-log")
        XCTAssertFalse(String(describing: profile).contains(profile.token))
        XCTAssertFalse(String(reflecting: profile).contains(profile.token))
        XCTAssertTrue(profile.description.contains("[REDACTED]"))
    }
}
