import Foundation
import Security

@main struct Tests {
    static func fixture(_ id: String, email: String = "test@example.invalid") throws -> Data {
        let claim: [String: Any] = ["sub": id, "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": id, "chatgpt_plan_type": "pro"]]
        let payload = try JSONSerialization.data(withJSONObject: claim).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["id_token": "fake." + payload + ".fake", "access_token": "test-access-only", "refresh_token": "test-refresh-only", "account_id": id]])
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppFailure("FAILED: " + message) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        var didThrow = false
        do { try body() } catch { didThrow = true }
        try require(didThrow, label)
    }
    static func main() throws {
        try require(deviceLoginCode(from: "Code: ABCD-12345") == "ABCD-12345", "plain device code")
        try require(deviceLoginCode(from: "Code: \u{1B}[94mABCD-12345\u{1B}[0m") == "ABCD-12345", "ANSI device code")
        try require(deviceLoginCode(from: "\u{1B}[94mABCD-") == nil, "incomplete device code")
        try require(deviceLoginCode(from: "Starting sign-in") == nil, "no device code")
        let home = URL(fileURLWithPath: "/Users/test/.codex")
        let standalone = "/Users/test/.codex/packages/standalone/releases/0.164.0-aarch64-apple-darwin/bin/codex"
        try require(isStandaloneAppServerDaemon(path: standalone, args: standalone + " app-server --listen unix:// --managed-daemon", codexHome: home), "managed app-server daemon")
        try require(isStandaloneAppServerDaemon(path: standalone, args: standalone + " app-server daemon pid-update-loop", codexHome: home), "app-server daemon supervisor")
        try require(!isStandaloneAppServerDaemon(path: standalone, args: "codex exec -m model -", codexHome: home), "terminal codex exec is not a daemon")
        try require(!isStandaloneAppServerDaemon(path: standalone, args: "codex", codexHome: home), "interactive codex is not a daemon")
        try require(!isStandaloneAppServerDaemon(path: standalone, args: "codex app-server --listen stdio://", codexHome: home), "manual app-server is not a daemon")
        try require(!isStandaloneAppServerDaemon(path: "/opt/homebrew/bin/codex", args: "codex app-server --managed-daemon", codexHome: home), "daemon outside CODEX_HOME")
        let now = Date(timeIntervalSince1970: 1000000)
        let mid = WeeklyPace.calculate(remaining: 60, reset: now.addingTimeInterval(302400), now: now)!
        try require(mid.expectedUsed == 50 && !mid.overPace, "midweek pace")
        try require(abs(mid.dailyBudget - 60 / 3.5) < 0.001, "daily budget")
        try require(WeeklyPace.calculate(remaining: 20, reset: now.addingTimeInterval(302400), now: now)!.overPace, "over pace")
        try require(WeeklyPace.calculate(remaining: 80, reset: now, now: now) == nil, "expired reset")
        try require(WeeklyPace.calculate(remaining: 80, reset: now.addingTimeInterval(700000), now: now) == nil, "invalid window")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-accounts-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("instance.lock")
        var heldLock: ProcessLock? = try ProcessLock(at: lockURL)
        try rejects("block duplicate app instances") { _ = try ProcessLock(at: lockURL) }
        withExtendedLifetime(heldLock) {}
        heldLock = nil
        let nextLock = try ProcessLock(at: lockURL)
        withExtendedLifetime(nextLock) {}
        let file = AuthFile(home: root)
        let first = try fixture("one")
        let second = try fixture("two", email: "second@example.invalid")
        try first.write(to: file.url)
        let sentinel = Data("keep local conversations and config intact".utf8)
        for name in ["state_5.sqlite", "config.toml", "history.jsonl"] { try sentinel.write(to: root.appendingPathComponent(name)) }
        try require(Identity.parse(first).key != Identity.parse(second).key, "distinct identities")
        try require(Identity.parse(first).email == "test@example.invalid", "identity label")
        try rejects("reject incomplete login") { _ = try Identity.parse(Data("{}".utf8)) }
        try rejects("reject malformed login") { _ = try Identity.parse(Data("not JSON".utf8)) }
        try file.preflight()
        try file.replace(with: second, expected: first)
        try require(file.read() == second, "successful atomic replacement")
        let attrs = try fm.attributesOfItem(atPath: file.url.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "owner-only permissions")
        for name in ["state_5.sqlite", "config.toml", "history.jsonl"] { try require(Data(contentsOf: root.appendingPathComponent(name)) == sentinel, "preserve " + name) }
        try rejects("reject concurrent auth change") { try file.replace(with: first, expected: first) }
        try require(file.read() == second, "concurrent edit preserved")
        try Data("extra login data".utf8).write(to: root.appendingPathComponent("cap_sid"))
        try rejects("reject unsupported extra auth") { try file.preflight() }
        try fm.removeItem(at: root.appendingPathComponent("cap_sid"))
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        try rejects("reject keyring-backed Codex") { try file.preflight() }
        try Data("forced_chatgpt_workspace_id = \"work\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        try rejects("respect enforced workspace") { try file.preflight() }
        try Data("cli_auth_credentials_store = \"file\"\n[mcp_servers.test]\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        try file.preflight()
        let recovery = Recovery(original: first, targetKey: try Identity.parse(second).key, startedAt: Date())
        let state = VaultData(profiles: [Profile(id: try Identity.parse(first).key, label: "Primary", auth: first, savedAt: Date())], recovery: recovery)
        let restored = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(state))
        try require(restored.recovery?.original == first, "durable recovery bytes")
        try file.replace(with: restored.recovery!.original, expected: second)
        try require(file.read() == first, "restore original login")
        let linkTarget = root.appendingPathComponent("other.json")
        try first.write(to: linkTarget)
        try fm.removeItem(at: file.url)
        try fm.createSymbolicLink(at: file.url, withDestinationURL: linkTarget)
        try rejects("reject symbolic auth file") { _ = try file.read() }
        try require(Data(contentsOf: linkTarget) == first, "symlink destination untouched")
        let usage = try Usage.parse(Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":55,\"limit_window_seconds\":604800,\"reset_at\":1789446689}}}".utf8))
        try require(usage.windows.count == 1 && usage.windows[0].remaining == 45 && usage.windows[0].title == "Weekly", "weekly primary window handled")
        try rejects("unknown usage shape") { _ = try Usage.parse(Data("{}".utf8)) }
        // A separate Keychain namespace with fake credentials only. Never open the real app vault.
        if CommandLine.arguments.contains("--keychain") {
            let service = "local.eric.CodexAccounts.test." + UUID().uuidString
            let vault = KeychainVault(service: service)
            defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
            try require(vault.load().profiles.isEmpty, "new test vault is empty")
            try vault.save(state)
            try require(vault.load().profiles.first?.auth == first, "Keychain round trip")
            var next = state; next.recovery = nil
            try vault.save(next)
            try require(vault.load().recovery == nil, "Keychain update")
            print("PASS: isolated Keychain round trip and journal update (fake credentials only)")
        }
        print("PASS: identity validation, atomic replacement, permissions, conflict protection, policy guards, recovery, history preservation, symlink rejection, and usage parsing")
    }
}
