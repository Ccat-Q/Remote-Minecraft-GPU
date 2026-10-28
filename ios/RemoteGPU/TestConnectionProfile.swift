import Foundation
import Security

enum RemoteGPUTestProfileError: Error, LocalizedError {
    case invalidInput, invalidSavedProfile, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "请输入主机名、有效端口和 Token；Token 不能有首尾空白或控制字符。"
        case .invalidSavedProfile: return "保存的测试配置无法读取，请清除后重新配置。"
        case .keychain(let status): return "无法访问本机 Keychain（状态 \(status)），未回退到明文存储。"
        }
    }
}

struct RemoteGPUTestProfile: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let port: UInt16
    let token: String

    init(host: String, port: UInt16, token: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
            !host.contains("/"), !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
            !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !token.isEmpty, token.utf8.count <= 4096,
            token == token.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteGPUTestProfileError.invalidInput
        }
        self.host = host; self.port = port; self.token = token
    }
    var description: String { "RemoteGPUTestProfile(host=\(host), port=\(port), token=[REDACTED])" }
    var debugDescription: String { description }
}

// Separate storage from validation so failures can be tested without pretending
// that a macOS in-memory fixture proves iPhone Keychain persistence.
protocol RemoteGPUCredentialVault {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func clear() throws
}

struct RemoteGPUKeychainVault: RemoteGPUCredentialVault {
    private let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "org.remotegpu.prototype") + ".test-connection") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "remote-display", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        var match = query
        match[kSecReturnData as String] = true
        match[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteGPUTestProfileError.keychain(status) }
        guard let data = result as? Data else { throw RemoteGPUTestProfileError.invalidSavedProfile }
        return data
    }
    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        // Update before add: replacing settings must not delete a valid old
        // credential first, then lose it if the subsequent write fails.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RemoteGPUTestProfileError.keychain(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteGPUTestProfileError.keychain(status)
        }
    }
}

final class RemoteGPUTestProfileStore {
    private let vault: any RemoteGPUCredentialVault
    init(vault: any RemoteGPUCredentialVault = RemoteGPUKeychainVault()) { self.vault = vault }
    func load() throws -> RemoteGPUTestProfile? {
        guard let data = try vault.read() else { return nil }
        do {
            let saved = try JSONDecoder().decode(RemoteGPUTestProfile.self, from: data)
            return try RemoteGPUTestProfile(host: saved.host, port: saved.port, token: saved.token)
        } catch { throw RemoteGPUTestProfileError.invalidSavedProfile }
    }
    func save(_ profile: RemoteGPUTestProfile) throws {
        // Revalidate decoded/programmatically supplied values as well.
        let checked = try RemoteGPUTestProfile(host: profile.host, port: profile.port, token: profile.token)
        try vault.write(JSONEncoder().encode(checked))
    }
    func clear() throws { try vault.clear() }
}
