import CryptoKit
import Foundation

/// Encryption at rest for everything sensitive (cookies, OAuth tokens, client
/// secret, sharing token). One random 256-bit key lives in the macOS Keychain;
/// data is sealed with AES-GCM and written to files only readable by the user.
/// Nothing sensitive is ever written to disk or UserDefaults in plaintext.
enum SecureStore {
    private static let keyAccount = "vault-key-v1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?

    static var directory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary", isDirectory: true)
            .appendingPathComponent("secure", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        // A read failure (e.g. the Keychain prompt after a rebuild was
        // denied or timed out) throws instead of making a new key: replacing
        // the key would make every saved sign-in unreadable for good.
        if let data = try KeychainStore.readData(for: keyAccount) {
            guard data.count == 32 else { throw CocoaError(.coderInvalidValue) }
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }
        DebugLog.write("No encryption key in the Keychain yet; creating one.", category: "security")
        let key = SymmetricKey(size: .bits256)
        try KeychainStore.setData(key.withUnsafeBytes { Data($0) }, for: keyAccount)
        cachedKey = key
        return key
    }

    static func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key()).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key())
    }

    /// Encrypts and writes atomically with owner-only permissions.
    static func write(_ plaintext: Data, to url: URL) throws {
        let sealed = try seal(plaintext)
        try sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(_ url: URL) throws -> Data? {
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        return try open(sealed)
    }

    /// Overwrites a plaintext file's bytes before deleting it. (On SSDs and
    /// APFS this is best-effort; the important part is the file is gone.)
    static func destroyFile(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if let handle = try? FileHandle(forWritingTo: url),
           let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            try? handle.write(contentsOf: Data(count: size.intValue))
            try? handle.synchronize()
            try? handle.close()
        }
        try? fm.removeItem(at: url)
    }
}

/// Small named secrets (OAuth token, client secret, sharing token), stored
/// together in one encrypted file.
enum SecretVault {
    enum Name: String, CaseIterable {
        case youtubeOAuthToken
        case youtubeClientSecret
        case sharingToken
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    private static var url: URL { SecureStore.directory.appendingPathComponent("secrets.vault") }

    static func value(_ name: Name) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[name.rawValue]
    }

    /// Returns false if the encrypted write failed (the value is then not saved).
    @discardableResult
    static func set(_ value: String?, for name: Name) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = loadLocked()
        values[name.rawValue] = value?.isEmpty == false ? value : nil
        do {
            try SecureStore.write(try JSONEncoder().encode(values), to: url)
            cache = values
            return true
        } catch {
            DebugLog.write("Could not save encrypted secrets: \(error.localizedDescription)", category: "security")
            return false
        }
    }

    private static func loadLocked() -> [String: String] {
        if let cache { return cache }
        let values = (try? SecureStore.read(url))
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = values
        return values
    }
}
