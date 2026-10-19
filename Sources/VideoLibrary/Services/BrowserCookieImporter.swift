import CommonCrypto
import Foundation
import Security
import SQLite3

/// Imports YouTube/Google cookies from the user's browsers into the
/// encrypted CookieCache.
///
/// - Chromium-based browsers (Arc, Dia, Chrome, Brave, …) keep cookies in a
///   SQLite database, AES-encrypted with a key in the macOS Keychain
///   ("<Browser> Safe Storage"). macOS asks the user before handing it over.
/// - Firefox-based browsers keep cookies in plain SQLite.
/// - Safari's cookie file is protected by macOS, so it's read through yt-dlp
///   (which needs Full Disk Access for VideoLibrary).
///
/// Decrypted cookies go straight into the encrypted CookieCache; they're
/// never written to disk in plaintext.
enum BrowserCookieImporter {
    enum Engine: Sendable {
        /// Keychain (service, account) candidates, tried in order.
        case chromium(keychain: [(service: String, account: String?)])
        case firefox
        case safari
    }

    struct Browser: Identifiable, Sendable {
        let id: String
        let name: String
        /// Relative to ~/Library/Application Support.
        let dataPath: String
        let engine: Engine
    }

    static let catalog: [Browser] = [
        chromium("arc", "Arc", "Arc/User Data", key: "Arc Safe Storage", account: "Arc"),
        chromium("dia", "Dia", "Dia/User Data", key: "Dia Safe Storage", account: "Dia"),
        chromium("chrome", "Google Chrome", "Google/Chrome", key: "Chrome Safe Storage", account: "Chrome"),
        chromium("brave", "Brave", "BraveSoftware/Brave-Browser", key: "Brave Safe Storage", account: "Brave"),
        chromium("edge", "Microsoft Edge", "Microsoft Edge", key: "Microsoft Edge Safe Storage", account: "Microsoft Edge"),
        chromium("vivaldi", "Vivaldi", "Vivaldi", key: "Vivaldi Safe Storage", account: "Vivaldi"),
        chromium("opera", "Opera", "com.operasoftware.Opera", key: "Opera Safe Storage", account: "Opera"),
        chromium("comet", "Comet", "Comet", key: "Comet Safe Storage", account: "Comet"),
        Browser(id: "helium", name: "Helium", dataPath: "net.imput.helium",
                engine: .chromium(keychain: [("Helium Storage Key", nil), ("Helium Safe Storage", nil)])),
        chromium("chromium", "Chromium", "Chromium", key: "Chromium Safe Storage", account: "Chromium"),
        chromium("whale", "Naver Whale", "Naver/Whale", key: "Whale Safe Storage", account: "Whale"),
        chromium("yandex", "Yandex Browser", "Yandex/YandexBrowser", key: "Yandex Safe Storage", account: "Yandex"),
        chromium("thorium", "Thorium", "Thorium", key: "Thorium Safe Storage", account: "Thorium"),
        chromium("sidekick", "Sidekick", "Sidekick", key: "Sidekick Safe Storage", account: "Sidekick"),
        Browser(id: "firefox", name: "Firefox", dataPath: "Firefox/Profiles", engine: .firefox),
        Browser(id: "zen", name: "Zen", dataPath: "zen/Profiles", engine: .firefox),
        Browser(id: "librewolf", name: "LibreWolf", dataPath: "librewolf/Profiles", engine: .firefox),
        Browser(id: "mullvad", name: "Mullvad Browser", dataPath: "MullvadBrowser/Profiles", engine: .firefox),
        Browser(id: "waterfox", name: "Waterfox", dataPath: "Waterfox/Profiles", engine: .firefox),
        Browser(id: "floorp", name: "Floorp", dataPath: "Floorp/Profiles", engine: .firefox),
        Browser(id: "tor", name: "Tor Browser", dataPath: "TorBrowser-Data/Browser", engine: .firefox),
        Browser(id: "safari", name: "Safari", dataPath: "", engine: .safari)
    ]

    private static func chromium(_ id: String, _ name: String, _ path: String, key: String, account: String) -> Browser {
        Browser(id: id, name: name, dataPath: path, engine: .chromium(keychain: [(key, account), (key, nil)]))
    }

    struct Profile: Identifiable, Hashable, Sendable {
        let id: String          // folder name, e.g. "Default", "Profile 1"
        let displayName: String
        let cookiesPath: String
    }

    struct Installed: Identifiable, Sendable {
        let browser: Browser
        let profiles: [Profile]
        var id: String { browser.id }
    }

    enum ImportError: LocalizedError {
        case browserNotInstalled(String)
        case keychainDenied(String)
        case databaseUnreadable(String)
        case notSignedIn(String, Service)
        case safariNeedsFullDiskAccess
        case toolMissing

        var errorDescription: String? {
            switch self {
            case .browserNotInstalled(let name):
                "Couldn't find \(name)'s cookies. Open \(name) once, then try again."
            case .keychainDenied(let name):
                "macOS didn't allow access to \(name)'s cookie key. Try again and choose “Always Allow” (enter your Mac password if asked)."
            case .databaseUnreadable(let detail):
                "Couldn't read the browser's cookie database. Quit the browser and try again. (\(detail))"
            case .notSignedIn(let name, let service):
                "No \(service.rawValue) sign-in was found in \(name). Sign in to \(service.signInSite) in \(name) first, then import again."
            case .safariNeedsFullDiskAccess:
                "macOS protects Safari's cookies. Give VideoLibrary Full Disk Access in System Settings › Privacy & Security, then try again."
            case .toolMissing:
                "Importing from Safari needs yt-dlp. Install it from Settings › Tools."
            }
        }
    }

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Browsers on this Mac that have a cookie store, with their profiles.
    static func installedBrowsers() -> [Installed] {
        catalog.compactMap { browser in
            let profiles = profiles(for: browser)
            return profiles.isEmpty ? nil : Installed(browser: browser, profiles: profiles)
        }
    }

    static func profiles(for browser: Browser) -> [Profile] {
        let fm = FileManager.default
        switch browser.engine {
        case .safari:
            let installed = fm.fileExists(atPath: "/Applications/Safari.app")
                || fm.fileExists(atPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
            return installed ? [Profile(id: "Default", displayName: "Safari", cookiesPath: "")] : []

        case .firefox:
            let root = appSupport.appendingPathComponent(browser.dataPath)
            let folders = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            return folders.sorted().compactMap { folder in
                let path = root.appendingPathComponent(folder).appendingPathComponent("cookies.sqlite").path
                guard fm.fileExists(atPath: path) else { return nil }
                let name = folder.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder
                return Profile(id: folder, displayName: name, cookiesPath: path)
            }

        case .chromium:
            let root = appSupport.appendingPathComponent(browser.dataPath)
            func cookies(in folder: URL) -> String? {
                ["Network/Cookies", "Cookies"]
                    .map { folder.appendingPathComponent($0).path }
                    .first(where: fm.fileExists(atPath:))
            }
            // Opera keeps a single profile at the top level.
            if let path = cookies(in: root), !fm.fileExists(atPath: root.appendingPathComponent("Default").path) {
                return [Profile(id: "Default", displayName: browser.name, cookiesPath: path)]
            }
            let names = profileDisplayNames(root: root)
            let folders = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            return folders
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .compactMap { folder -> Profile? in
                    guard let path = cookies(in: root.appendingPathComponent(folder)) else { return nil }
                    let name = names[folder] ?? folder
                    // Skip browser-internal profiles (e.g. Arc's "__ARC_SYSTEM_PROFILE").
                    guard !name.hasPrefix("__") else { return nil }
                    return Profile(id: folder, displayName: name, cookiesPath: path)
                }
                .sorted { lhs, rhs in
                    if lhs.id == "Default" { return true }
                    if rhs.id == "Default" { return false }
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
        }
    }

    /// Reads, decrypts and saves the browser's YouTube/Google cookies.
    /// Returns how many cookies were imported.
    @discardableResult
    static func importCookies(_ service: Service, from browser: Browser, profile: Profile) throws -> ImportResult {
        let rows: [CookieRow]
        switch browser.engine {
        case .safari:
            return try importFromSafari(service)
        case .firefox:
            rows = try readFirefoxRows(at: profile.cookiesPath)
        case .chromium(let keychain):
            guard FileManager.default.fileExists(atPath: profile.cookiesPath) else {
                throw ImportError.browserNotInstalled(browser.name)
            }
            let key = try decryptionKey(for: browser.name, candidates: keychain)
            rows = try readChromiumRows(at: profile.cookiesPath).compactMap { row in
                guard row.value.isEmpty else { return row }
                guard let value = decrypt(row.encryptedValue, key: key, stripHashPrefix: row.metaVersion >= 24) else { return nil }
                var decrypted = row
                decrypted.value = value
                return decrypted
            }
        }
        return try save(rows, service: service, from: browser.name, profile: profile.id)
    }

    /// What an import found and saved.
    struct ImportResult: Sendable {
        let cookieCount: Int
        /// e.g. ["YouTube", "Nebula"]
        let services: [String]
    }

    /// Which sign-in to import. Each has its own Import button, so
    /// importing YouTube never touches Nebula and vice versa.
    enum Service: String, Sendable {
        case youtube = "YouTube"
        case nebula = "Nebula"

        var sites: Set<String> {
            switch self {
            case .youtube: ["youtube.com", "google.com"]
            case .nebula: ["nebula.tv"]
            }
        }

        var signInSite: String {
            switch self {
            case .youtube: "youtube.com"
            case .nebula: "nebula.tv"
            }
        }

        func isSignedIn(_ names: Set<String>) -> Bool {
            switch self {
            case .youtube: names.contains("SAPISID") || names.contains("LOGIN_INFO") || names.contains("__Secure-3PSID")
            case .nebula: names.contains("nebula_auth.apiToken")
            }
        }
    }

    private static func save(_ rows: [CookieRow], service: Service, from browserName: String, profile: String) throws -> ImportResult {
        let filled = rows.filter { !$0.value.isEmpty }
        var found: [String] = []
        var total = 0
        for service in [service] {
            let serviceRows = filled.filter { row in
                let host = row.hostKey.hasPrefix(".") ? String(row.hostKey.dropFirst()) : row.hostKey
                return service.sites.contains { host == $0 || host.hasSuffix("." + $0) }
            }
            guard service.isSignedIn(Set(serviceRows.map(\.name))) else { continue }
            let lines = serviceRows.map { row in
                [
                    (row.isHTTPOnly ? "#HttpOnly_" : "") + row.hostKey,
                    row.hostKey.hasPrefix(".") ? "TRUE" : "FALSE",
                    row.path.isEmpty ? "/" : row.path,
                    row.isSecure ? "TRUE" : "FALSE",
                    String(row.expiresUnix),
                    row.name,
                    row.value
                ].joined(separator: "\t")
            }
            // Replace only this service's cookies; other sign-ins stay.
            try CookieCache.merge(netscapeText: lines.joined(separator: "\n"), replacingSites: service.sites)
            found.append(service.rawValue)
            total += lines.count
        }
        guard !found.isEmpty else { throw ImportError.notSignedIn(browserName, service) }
        DebugLog.write("Imported \(total) cookies (\(found.joined(separator: ", "))) from \(browserName) (\(profile)).", category: "security")
        return ImportResult(cookieCount: total, services: found)
    }

    // MARK: - Safari (via yt-dlp)

    private static func importFromSafari(_ service: Service) throws -> ImportResult {
        guard let ytdlp = YtDlpService.findExecutable(named: "yt-dlp") else { throw ImportError.toolMissing }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("VideoLibrary-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let jar = directory.appendingPathComponent("cookies.txt")
        defer {
            SecureStore.destroyFile(at: jar)
            try? fm.removeItem(at: directory)
        }

        // yt-dlp loads Safari's cookies and saves the jar to --cookies on exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "--cookies-from-browser", "safari", "--cookies", jar.path,
            "--skip-download", "--no-playlist", "--no-warnings", "--quiet",
            "--", "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if output.contains("Operation not permitted") || output.contains("PermissionError") {
            throw ImportError.safariNeedsFullDiskAccess
        }
        guard let text = try? String(contentsOf: jar, encoding: .utf8) else {
            throw ImportError.databaseUnreadable(output.split(separator: "\n").last.map(String.init) ?? "no output")
        }
        let rows = text.split(separator: "\n").compactMap { line -> CookieRow? in
            var line = String(line)
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if httpOnly { line.removeFirst("#HttpOnly_".count) } else if line.hasPrefix("#") { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            let host = fields[0]
            guard host.hasSuffix("youtube.com") || host.hasSuffix("google.com") || host.hasSuffix("nebula.tv") else { return nil }
            return CookieRow(hostKey: host, name: fields[5], value: fields[6], encryptedValue: Data(),
                             path: fields[2], expiresUnix: Int64(fields[4]) ?? 0,
                             isSecure: fields[3] == "TRUE", isHTTPOnly: httpOnly, metaVersion: 0)
        }
        return try save(rows, service: service, from: "Safari", profile: "Default")
    }

    // MARK: - Keychain key

    private static func decryptionKey(
        for browserName: String,
        candidates: [(service: String, account: String?)]
    ) throws -> Data {
        var password: Data?
        var lastStatus = errSecItemNotFound
        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let account = candidate.account { query[kSecAttrAccount as String] = account }
            var item: CFTypeRef?
            lastStatus = SecItemCopyMatching(query as CFDictionary, &item)
            if lastStatus == errSecSuccess, let data = item as? Data {
                password = data
                break
            }
            if lastStatus != errSecItemNotFound { break }
        }
        guard let password else {
            if lastStatus == errSecItemNotFound { throw ImportError.browserNotInstalled(browserName) }
            throw ImportError.keychainDenied(browserName)
        }
        // Chromium on macOS: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16-byte key.
        var derived = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let result = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw ImportError.keychainDenied(browserName) }
        return derived
    }

    private static func decrypt(_ data: Data, key: Data, stripHashPrefix: Bool) -> String? {
        // "v10" prefix + AES-128-CBC, IV of 16 spaces, PKCS7 padding.
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else { return nil }
        let ciphertext = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, outputCapacity, &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plaintext = output.prefix(outputLength)
        // Newer Chromium (DB meta version ≥ 24) prepends SHA-256(host) to the value.
        if stripHashPrefix, plaintext.count >= 32 { plaintext = plaintext.dropFirst(32) }
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - SQLite

    private struct CookieRow {
        let hostKey: String
        let name: String
        var value: String
        let encryptedValue: Data
        let path: String
        /// Unix seconds; 0 = session cookie.
        let expiresUnix: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let metaVersion: Int
    }

    /// Opens a private copy of a browser's (possibly locked) SQLite database.
    private static func withDatabaseCopy<T>(at path: String, fileName: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("VideoLibrary-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                SecureStore.destroyFile(at: temp.appendingPathComponent(fileName + suffix))
            }
            try? fm.removeItem(at: temp)
        }
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try fm.copyItem(atPath: path + suffix, toPath: temp.appendingPathComponent(fileName + suffix).path)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appendingPathComponent(fileName).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ImportError.databaseUnreadable(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func readFirefoxRows(at path: String) throws -> [CookieRow] {
        try withDatabaseCopy(at: path, fileName: "cookies.sqlite") { db in
            let sql = """
            SELECT host, name, value, path, expiry, isSecure, isHttpOnly FROM moz_cookies
            WHERE host LIKE '%youtube.com' OR host LIKE '%google.com' OR host LIKE '%nebula.tv'
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ImportError.databaseUnreadable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            var rows: [CookieRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var expiry = sqlite3_column_int64(statement, 4)
                if expiry > 100_000_000_000 { expiry /= 1000 }   // newer Firefox stores milliseconds
                rows.append(CookieRow(
                    hostKey: text(0), name: text(1), value: text(2), encryptedValue: Data(),
                    path: text(3), expiresUnix: expiry,
                    isSecure: sqlite3_column_int(statement, 5) != 0,
                    isHTTPOnly: sqlite3_column_int(statement, 6) != 0,
                    metaVersion: 0
                ))
            }
            return rows
        }
    }

    private static func readChromiumRows(at path: String) throws -> [CookieRow] {
        try withDatabaseCopy(at: path, fileName: "Cookies") { db in
            try readChromiumRows(db: db)
        }
    }

    private static func readChromiumRows(db: OpaquePointer?) throws -> [CookieRow] {
        var metaVersion = 0
        var metaStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &metaStatement, nil) == SQLITE_OK,
           sqlite3_step(metaStatement) == SQLITE_ROW,
           let text = sqlite3_column_text(metaStatement, 0) {
            metaVersion = Int(String(cString: text)) ?? 0
        }
        sqlite3_finalize(metaStatement)

        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
        FROM cookies
        WHERE host_key LIKE '%youtube.com' OR host_key LIKE '%google.com' OR host_key LIKE '%nebula.tv'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.databaseUnreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var rows: [CookieRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let blobLength = Int(sqlite3_column_bytes(statement, 3))
            let blob = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: blobLength) } ?? Data()
            // Chromium time: microseconds since 1601-01-01. 0 = session cookie.
            let chromeTime = sqlite3_column_int64(statement, 5)
            rows.append(CookieRow(
                hostKey: text(0),
                name: text(1),
                value: text(2),
                encryptedValue: blob,
                path: text(4),
                expiresUnix: chromeTime > 0 ? max(0, chromeTime / 1_000_000 - 11_644_473_600) : 0,
                isSecure: sqlite3_column_int(statement, 6) != 0,
                isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
                metaVersion: metaVersion
            ))
        }
        return rows
    }

    /// Profile names from the browser's "Local State" file, when present.
    private static func profileDisplayNames(root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }
}
