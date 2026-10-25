import Foundation
import Security
import CryptoKit
import Darwin

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Identity: Equatable {
    let key: String
    let email: String
    let plan: String
    let accountID: String
    let accessToken: String
    static func parse(_ data: Data) throws -> Identity {
        guard data.count < 1_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let id = tokens["id_token"] as? String,
              let account = tokens["account_id"] as? String, !account.isEmpty else {
            throw AppFailure("This login is not a complete ChatGPT subscription login. Sign in again with Codex.")
        }
        let pieces = id.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw AppFailure("The login identity is invalid.") }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let email = claims["email"] as? String, !email.isEmpty else {
            throw AppFailure("The login has no readable account identity.")
        }
        let details = claims["https://api.openai.com/auth"] as? [String: Any]
        if let claimAccount = details?["chatgpt_account_id"] as? String, claimAccount != account {
            throw AppFailure("The login contains conflicting account identities.")
        }
        let hash = SHA256.hash(data: Data((subject + "\n" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        return Identity(key: hash, email: email, plan: details?["chatgpt_plan_type"] as? String ?? "ChatGPT", accountID: account, accessToken: access)
    }
}
struct Profile: Codable, Identifiable {
    var id: String
    var label: String
    var auth: Data
    var savedAt: Date
}
struct Recovery: Codable {
    let original: Data
    let targetKey: String
    let startedAt: Date
}
struct VaultData: Codable {
    var profiles: [Profile] = []
    var recovery: Recovery? = nil
}

final class KeychainVault {
    let service: String
    init(service: String = "local.eric.CodexAccounts.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "vault"]
    }
    func load() throws -> VaultData {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return VaultData() }
        guard status == errSecSuccess, let bytes = result as? Data else { throw AppFailure("Cannot open Keychain (\(status)). Unlock your login Keychain and try again.") }
        return try JSONDecoder().decode(VaultData.self, from: bytes)
    }
    func save(_ value: VaultData) throws {
        let bytes = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = bytes
            q[kSecAttrLabel as String] = "Codex Accounts saved logins"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Cannot save the login to Keychain (\(status)). No account switch was completed.") }
    }
}

struct AuthFile {
    let home: URL
    var url: URL { home.appendingPathComponent("auth.json") }
    func read() throws -> Data {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular else { throw AppFailure("auth.json must be a regular file, not a link.") }
        let bytes = try Data(contentsOf: url)
        _ = try Identity.parse(bytes)
        return bytes
    }
    func preflight() throws {
        _ = try read()
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("cap_sid").path) {
            throw AppFailure("This Codex version has an extra login file (cap_sid). Switching is disabled until this app supports it.")
        }
        let config = home.appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            // Only root TOML keys apply. Do not inspect or modify MCP credentials.
            for line in text.components(separatedBy: .newlines) {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if clean.hasPrefix("[") { break }
                if clean.hasPrefix("cli_auth_credentials_store"), !clean.contains("\"file\""), !clean.contains("'file'") {
                    throw AppFailure("Codex uses a different credential store. This app supports file-based Codex login only.")
                }
                if clean.hasPrefix("forced_chatgpt_workspace_id") || clean.hasPrefix("forced_login_method") {
                    throw AppFailure("Codex has an enforced login policy. This app will not override it.")
                }
            }
        }
    }
    func replace(with bytes: Data, expected: Data) throws {
        _ = try Identity.parse(bytes)
        guard try read() == expected else { throw AppFailure("The current login changed during the switch. Try again after all Codex processes have stopped.") }
        let temp = home.appendingPathComponent(".codex-accounts-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppFailure("Cannot create the protected login file.") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AppFailure("Cannot write the login file.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw AppFailure("Cannot flush the login file.") }
        guard try read() == expected else { throw AppFailure("The login changed before replacement. Nothing was switched.") }
        guard Darwin.rename(temp.path, url.path) == 0 else { throw AppFailure("Cannot activate the saved login.") }
    }
}

struct UsageWindow: Identifiable {
    let id: String
    let title: String
    let remaining: Int
    let resets: Date?
}
struct Usage {
    let windows: [UsageWindow]
    let fetchedAt: Date
    static func parse(_ data: Data) throws -> Usage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = root["rate_limit"] as? [String: Any] else { throw AppFailure("Usage data is not available for this account.") }
        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rate[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
            let seconds = w["limit_window_seconds"] as? Int ?? 0
            let title = seconds == 604800 ? "Weekly" : seconds == 18000 ? "5-hour" : seconds > 0 ? "\(seconds / 3600)-hour" : "Usage"
            windows.append(UsageWindow(id: key, title: title, remaining: max(0, min(100, Int((100 - used).rounded()))), resets: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }))
        }
        guard !windows.isEmpty else { throw AppFailure("Usage data has no supported windows.") }
        return Usage(windows: windows, fetchedAt: Date())
    }
}
struct LoginNeedsRenewal: LocalizedError {
    var errorDescription: String? { "Open Codex to renew this login. If Codex asks you to sign in again, add the account again here afterward." }
}
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
func fetchUsage(_ identity: Identity) async throws -> Usage {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.setValue("Bearer " + identity.accessToken, forHTTPHeaderField: "Authorization")
    request.setValue(identity.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppFailure("No usage response received.") }
    if http.statusCode == 401 { throw LoginNeedsRenewal() }
    guard http.statusCode == 200 else { throw AppFailure("OpenAI could not verify this login (HTTP \(http.statusCode)). Try again later.") }
    return try Usage.parse(data)
}

final class ProcessLock {
    private let fd: Int32
    init(at url: URL) throws {
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppFailure("Cannot open the Codex Accounts lock file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw AppFailure("Codex Accounts is already running. Use its menu-bar icon.")
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

// The CLI emits ANSI styling even with NO_COLOR set.
func deviceLoginCode(from output: String) -> String? {
    let plain = output.replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    guard let match = plain.range(of: "\\b[A-Z0-9]{4,6}-[A-Z0-9]{4,6}\\b", options: .regularExpression) else { return nil }
    return String(plain[match])
}
// The standalone CLI's managed app-server daemon (`codex app-server --managed-daemon` and its
// `codex app-server daemon ...` supervisor) runs the same binary as a user's terminal `codex`,
// so it is recognized by its arguments, not just its path.
func isStandaloneAppServerDaemon(path: String, args: String, codexHome: URL) -> Bool {
    guard path.hasPrefix(codexHome.appendingPathComponent("packages/standalone").path + "/") else { return false }
    let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let sub = words.firstIndex(of: "app-server") else { return false }
    return words.contains("--managed-daemon") || words.dropFirst(sub + 1).first == "daemon"
}

struct WeeklyPace {
    let used: Double
    let expectedUsed: Double
    let dailyBudget: Double
    var overPace: Bool { used > expectedUsed + 5 }
    static func calculate(remaining: Int, reset: Date, now: Date) -> WeeklyPace? {
        let left = reset.timeIntervalSince(now)
        guard left > 0, left <= 604800 else { return nil }
        let remaining = Double(max(0, min(100, remaining)))
        return WeeklyPace(used: 100 - remaining, expectedUsed: 100 * (1 - left / 604800), dailyBudget: min(remaining, remaining / (left / 86400)))
    }
}
