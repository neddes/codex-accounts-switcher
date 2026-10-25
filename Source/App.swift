import AppKit
import SwiftUI
import Combine

@MainActor final class AccountModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var active: Identity?
    @Published var usage: Usage?
    @Published var accountUsage: [String: Usage] = [:]
    @Published var usageErrors: [String: String] = [:]
    @Published var message = "Save your current account to get started."
    @Published var busy = false
    @Published var loginCode: String?
    @Published var recoveryPending = false
    @Published var signingIn = false
    @Published var vaultReady = false
    private let vault = KeychainVault()
    private var state = VaultData()
    private let auth = AuthFile(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    private var loginProcess: Process?
    private var loginHome: URL?
    private var loginBuffer = Data()
    private var loginTimer: Timer?
    private var snapshotTimer: Timer?
    var demo: Bool
    @Published var refreshNotice = ""
    private var noticeTask: Task<Void, Never>?
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }
    var cliURL: URL? { appURL?.appendingPathComponent("Contents/Resources/codex") }

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            func fixture(_ id: String, _ email: String) -> Data {
                let payload = try! JSONSerialization.data(withJSONObject: ["sub": id, "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": id, "chatgpt_plan_type": id == "demo-one" ? "Pro 20×" : id == "demo-two" ? "Pro 5×" : "Plus"]])
                let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["id_token": "demo." + encoded + ".demo", "access_token": "demo-only", "refresh_token": "demo-only", "account_id": id]])
            }
            let first = fixture("demo-one", "primary@example.com")
            let second = fixture("demo-two", "second@example.com")
            let firstID = try! Identity.parse(first).key
            let third = fixture("demo-three", "personal@example.com")
            let thirdID = try! Identity.parse(third).key
            let secondID = try! Identity.parse(second).key
            active = try? Identity.parse(first)
            profiles = [Profile(id: firstID, label: "Primary", auth: first, savedAt: Date()), Profile(id: secondID, label: "Side projects", auth: second, savedAt: Date()), Profile(id: thirdID, label: "Personal", auth: third, savedAt: Date())]
            accountUsage = [
                firstID: Usage(windows: [UsageWindow(id: "weekly", title: "Weekly", remaining: 74, resets: Date().addingTimeInterval(4 * 86400))], fetchedAt: Date()),
                secondID: Usage(windows: [UsageWindow(id: "weekly", title: "Weekly", remaining: 92, resets: Date().addingTimeInterval(5 * 86400))], fetchedAt: Date()),
                thirdID: Usage(windows: [UsageWindow(id: "weekly", title: "Weekly", remaining: 65, resets: Date().addingTimeInterval(3 * 86400))], fetchedAt: Date())
            ]
            message = "Demo mode · fictional accounts and usage."
            return
        }
        do {
            state = try vault.load()
            vaultReady = true
            profiles = state.profiles
            recoveryPending = state.recovery != nil
            active = try? Identity.parse(auth.read())
            if recoveryPending { message = "A previous switch was interrupted. Restore the previous login before switching again." }
            else if !profiles.isEmpty { message = "" }
        } catch { message = error.localizedDescription }
        // Capture refreshed credentials only for a profile the user has already saved.
        // No token renewal or network polling is performed by this timer.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncCurrent() }
        }
    }
    func syncCurrent() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        do {
            let bytes = try auth.read()
            let identity = try Identity.parse(bytes)
            if active?.key != identity.key { usage = nil }
            active = identity
            if let i = state.profiles.firstIndex(where: { $0.id == identity.key }), state.profiles[i].auth != bytes {
                var next = state
                next.profiles[i].auth = bytes
                next.profiles[i].savedAt = Date()
                try vault.save(next)
                state = next; profiles = next.profiles
            }
        } catch { message = "Cannot read or save the current login. " + error.localizedDescription }
    }
    private func save(_ bytes: Data, label: String? = nil) throws {
        guard vaultReady else { throw AppFailure("Keychain is unavailable. Reopen Codex Accounts after unlocking Keychain.") }
        let identity = try Identity.parse(bytes)
        var next = state
        if let index = next.profiles.firstIndex(where: { $0.id == identity.key }) {
            next.profiles[index].auth = bytes
            next.profiles[index].savedAt = Date()
            if let label { next.profiles[index].label = label }
        } else {
            next.profiles.append(Profile(id: identity.key, label: label ?? "Account \(next.profiles.count + 1)", auth: bytes, savedAt: Date()))
        }
        try vault.save(next)
        state = next; profiles = next.profiles
    }
    func saveCurrent() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        do {
            try auth.preflight()
            let bytes = try auth.read()
            let identity = try Identity.parse(bytes)
            try save(bytes, label: state.profiles.first(where: { $0.id == identity.key })?.label ?? "Primary")
            active = identity
            message = "Current account saved in Keychain."
        } catch { message = error.localizedDescription }
    }
    func refreshUsage() {
        guard !demo, vaultReady, !busy else { return }
        syncCurrent()
        let saved = profiles
        busy = true
        Task {
            defer { busy = false }
            var failed = false
            for profile in saved {
                do {
                    let identity = try Identity.parse(profile.auth)
                    accountUsage[profile.id] = try await fetchUsage(identity)
                    usageErrors[profile.id] = nil
                } catch {
                    accountUsage[profile.id] = nil
                    usageErrors[profile.id] = "Usage unavailable"
                    failed = true
                }
            }
            message = failed ? "Some usage could not be checked. Use Add account to renew the login." : ""
            refreshNotice = failed ? "Partly updated" : "Updated"
            noticeTask?.cancel()
            noticeTask = Task {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                refreshNotice = ""
            }
        }
    }

    func addAccount() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        guard let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            message = "Install the official Codex app first."; return
        }
        do {
            // Preserve a valid current login before initiating a separate sign-in.
            if let bytes = try? auth.read() { try save(bytes, label: active.flatMap { a in state.profiles.first(where: { $0.id == a.key })?.label } ?? "Primary") }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Accounts", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let home = base.appendingPathComponent("login-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            loginHome = home
            loginBuffer = Data()
            loginCode = nil
            let p = Process()
            p.executableURL = cli
            p.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login", "--device-auth"]
            // Do not pass API keys, proxies, alternate endpoints or the active CODEX_HOME.
            p.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": home.path, "TERM": "dumb", "NO_COLOR": "1"]
            p.currentDirectoryURL = home
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor in self?.readLoginOutput(bytes) }
            }
            p.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in self?.finishLogin(status: process.terminationStatus) }
            }
            loginProcess = p
            signingIn = true
            busy = true
            message = "Starting official Codex sign-in…"
            try p.run()
            loginTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.cancelLogin() }
            }
        } catch {
            busy = false; signingIn = false; loginProcess = nil; cleanLoginHome(); message = error.localizedDescription
        }
    }
    private func readLoginOutput(_ bytes: Data) {
        guard loginProcess != nil else { return }
        if loginBuffer.count < 32_768 { loginBuffer.append(bytes) }
        let output = String(decoding: loginBuffer, as: UTF8.self)
        // Only expose a device code. Never display raw CLI output or tokens.
        if let code = deviceLoginCode(from: output) {
            loginCode = code
            message = "Open OpenAI sign-in, enter this code, and select another account."
        }
    }
    private func finishLogin(status: Int32) {
        loginTimer?.invalidate(); loginTimer = nil
        defer { busy = false; signingIn = false; loginProcess = nil; loginCode = nil; loginBuffer = Data(); cleanLoginHome() }
        guard status == 0, let home = loginHome else { message = "Sign-in stopped or failed. Your current Codex login was not changed."; return }
        do {
            let bytes = try AuthFile(home: home).read()
            let identity = try Identity.parse(bytes)
            try save(bytes)
            if identity.key == active?.key {
                message = "Login updated for the current account."
            } else { message = "Account saved. Select Switch when you are ready." }
        } catch { message = error.localizedDescription }
    }
    private func cleanLoginHome() {
        guard let home = loginHome else { return }
        try? FileManager.default.removeItem(at: home)
        loginHome = nil
    }
    func cancelLogin() {
        loginTimer?.invalidate()
        if let p = loginProcess, p.isRunning { p.terminate() }
    }
    func openLogin() {
        guard loginCode != nil else { return }
        NSWorkspace.shared.open(URL(string: "https://auth.openai.com/codex/device")!)
    }
    func copyCode() {
        guard let code = loginCode else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
    }
    func rename(_ profile: Profile) {
        guard !demo, vaultReady, !busy else { return }
        let alert = NSAlert(); alert.messageText = "Name this account"
        let field = NSTextField(string: profile.label); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !label.isEmpty else { return }
        do { try save(profile.auth, label: label) } catch { message = error.localizedDescription }
    }
    func remove(_ profile: Profile) {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        let alert = NSAlert(); alert.messageText = "Remove \(profile.label)?"
        alert.informativeText = "This removes the saved login from this app. It does not sign you out of Codex."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var next = state; next.profiles.removeAll { $0.id == profile.id }
            try vault.save(next); state = next; profiles = next.profiles; message = "Saved account removed."
        } catch { message = error.localizedDescription }
    }
    private func runningCodexProcesses() throws -> [(pid: Int32, path: String, args: String)] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AppFailure("Cannot check for running Codex processes.") }
        var result: [(pid: Int32, path: String, args: String)] = []
        for rawLine in String(decoding: output, as: UTF8.self).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let sep = line.firstIndex(of: " "), let pid = Int32(line[line.startIndex..<sep]) else { continue }
            let path = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name == "codex" || name == "codex-cli" { result.append((pid, path, "")) }
        }
        guard !result.isEmpty else { return result }
        // Arguments are read separately: comm paths can contain spaces, so the two can't share one ps line.
        let a = Process(); a.executableURL = URL(fileURLWithPath: "/bin/ps")
        a.arguments = ["-o", "pid=,args=", "-p", result.map { String($0.pid) }.joined(separator: ",")]
        let argsPipe = Pipe(); a.standardOutput = argsPipe; a.standardError = FileHandle.nullDevice
        try a.run()
        let argsOutput = argsPipe.fileHandleForReading.readDataToEndOfFile(); a.waitUntilExit()
        var argsByPid: [Int32: String] = [:]
        for rawLine in String(decoding: argsOutput, as: UTF8.self).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let sep = line.firstIndex(of: " "), let pid = Int32(line[line.startIndex..<sep]) else { continue }
            argsByPid[pid] = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        }
        return result.map { ($0.pid, $0.path, argsByPid[$0.pid] ?? "") }
    }
    // Codex's own background helpers - the plugin app-server that the ChatGPT browser
    // extension and similar plugin hosts spawn under CODEX_HOME/plugins/.plugin-appserver
    // (their exact layout inside that directory has changed over time, e.g. moving from a
    // flat binary to a nested CodexCLI.app bundle, so match by directory prefix rather than
    // an exact/allow-listed path), the standalone CLI's managed app-server daemon (see
    // isStandaloneAppServerDaemon), plus the app's own embedded CLI - are not user-visible
    // CLI/IDE sessions. They restart on demand and pick up the new login, so it's safe for
    // the switch to signal them directly instead of waiting on them indefinitely. Everything
    // else (a terminal `codex` session, the VS Code extension's bundled codex, etc.) is left
    // alone; the user closes those themselves.
    private func isCodexOwnedHelper(_ process: (pid: Int32, path: String, args: String)) -> Bool {
        if let cli = cliURL, process.path == cli.path { return true }
        let appserverPrefix = auth.home.appendingPathComponent("plugins/.plugin-appserver").path + "/"
        return process.path.hasPrefix(appserverPrefix) || isStandaloneAppServerDaemon(path: process.path, args: process.args, codexHome: auth.home)
    }
    private func stopCodex() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        for app in running { _ = app.terminate() }
        var termSentAt: [Int32: Int] = [:]
        for iteration in 0..<120 {
            let appStillOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
            let processes = try runningCodexProcesses()
            if !appStillOpen && processes.isEmpty { return }
            for process in processes where isCodexOwnedHelper(process) {
                if let sentAt = termSentAt[process.pid] {
                    if iteration - sentAt >= 8 { kill(process.pid, SIGKILL) }
                } else {
                    kill(process.pid, SIGTERM)
                    termSentAt[process.pid] = iteration
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let blockers = ((try? runningCodexProcesses()) ?? []).filter { !isCodexOwnedHelper($0) }
        if !blockers.isEmpty {
            let names = blockers.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent) (pid \($0.pid)) at \($0.path)" }.joined(separator: "; ")
            throw AppFailure("Codex did not fully stop. Close its quit dialog and any Codex CLI or IDE sessions, then try again. Still running: \(names). No login was replaced.")
        }
        throw AppFailure("Codex did not fully stop. Close its quit dialog and any Codex CLI or IDE sessions, then try again. No login was replaced.")
    }
    func openCodex() async throws {
        guard let url = appURL else { throw AppFailure("The official Codex app was not found.") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
    func switchTo(_ profile: Profile) {
        guard !demo, vaultReady, !busy, !recoveryPending, profile.id != active?.key else { return }
        let alert = NSAlert(); alert.messageText = "Switch to \(profile.label)?"
        alert.informativeText = "Finish or stop all Codex tasks first, including scheduled work. This closes and reopens Codex. Local chats stay on this Mac; continuing one sends its context under the selected account. Cloud chats and connected services may differ."
        alert.addButton(withTitle: "Switch and reopen"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            var didReplace = false
            var before: Data?
            do {
                try auth.preflight()
                let target = try Identity.parse(profile.auth)
                message = "Checking the saved login with OpenAI…"
                var targetUsage: Usage?
                // Codex owns token renewal. An expired access token does not mean the
                // saved refresh token is invalid; let the official app renew it on launch.
                do { targetUsage = try await fetchUsage(target) }
                catch is LoginNeedsRenewal { targetUsage = nil }
                message = "Waiting for Codex to close…"
                try await stopCodex()
                try auth.preflight()
                let original = try auth.read(); before = original
                try save(original)
                // A durable Keychain journal survives a crash between file replacement and launch.
                var next = state
                next.recovery = Recovery(original: original, targetKey: profile.id, startedAt: Date())
                try vault.save(next); state = next; recoveryPending = true
                try auth.replace(with: profile.auth, expected: original); didReplace = true
                guard try Identity.parse(auth.read()).key == profile.id else { throw AppFailure("Login verification failed.") }
                try await openCodex()
                next = state; next.recovery = nil
                try vault.save(next); state = next; recoveryPending = false
                active = target; usage = targetUsage
                message = targetUsage == nil ? "\(profile.label) is selected. Codex will try to renew the saved login. Check the account shown there." : "\(profile.label) is selected. Check the account shown in Codex."
            } catch {
                if didReplace {
                    // Do not overwrite files if the relaunched app might have refreshed them.
                    message = "Switch interrupted. Use Restore previous login after closing Codex. " + error.localizedDescription
                } else {
                    if before != nil {
                        var next = state; next.recovery = nil
                        do { try vault.save(next); state = next; recoveryPending = false }
                        catch { recoveryPending = true }
                    }
                    message = error.localizedDescription
                }
            }
            busy = false
        }
    }
    func restore() {
        guard !demo, vaultReady, !busy, let recovery = state.recovery else { return }
        let alert = NSAlert(); alert.messageText = "Restore the previous login?"
        alert.informativeText = "Finish all Codex tasks first. Codex must close before its previous login can be restored."
        alert.addButton(withTitle: "Restore and reopen"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await stopCodex()
                let current = try auth.read()
                let identity = try Identity.parse(current)
                let old = try Identity.parse(recovery.original)
                guard identity.key == recovery.targetKey || identity.key == old.key else { throw AppFailure("Another account is now active. Recovery will not overwrite it.") }
                // Keep the latest token if the original account is already active.
                if identity.key != old.key {
                    try save(current)
                    try auth.replace(with: recovery.original, expected: current)
                }
                try await openCodex()
                var next = state; next.recovery = nil
                try vault.save(next); state = next; recoveryPending = false
                active = try Identity.parse(auth.read()); usage = nil
                message = "Previous login restored. If it expired, sign in again in Codex."
            } catch { message = error.localizedDescription }
        }
    }
}

struct AccountPanel: View {
    @ObservedObject var model: AccountModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "person.2.circle.fill").font(.system(size: 30)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Accounts Switcher").font(.system(size: 17, weight: .semibold))
                    Text("By Eric · Your accounts, one workspace.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Divider()
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Start with your current account").font(.headline)
                    Text(model.active?.email ?? "Sign in to the official Codex app first.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Save current account") { model.saveCurrent() }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.busy || model.active == nil || !model.vaultReady)
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: profile.id == model.active?.key ? "checkmark.circle.fill" : "person.crop.circle")
                                .font(.system(size: 23)).foregroundStyle(profile.id == model.active?.key ? Color.teal : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text((try? Identity.parse(profile.auth).email) ?? "Preview account").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                if let usage = model.accountUsage[profile.id] {
                                    ForEach(usage.windows) { window in
                                        HStack(spacing: 6) {
                                            Text("\(window.remaining)% left")
                                                .foregroundStyle(window.remaining < 15 ? Color.orange : Color.teal)
                                            if let reset = window.resets {
                                                Text("↻ " + reset.formatted(.dateTime.day().month(.abbreviated)))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .fixedSize()
                                        .help(window.title + (window.resets.map { " · Resets " + $0.formatted() } ?? ""))
                                    }
                                } else {
                                    Text(model.usageErrors[profile.id] ?? "Usage not checked").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if profile.id == model.active?.key { Text("Active").font(.system(size: 11, weight: .medium)).foregroundStyle(.teal) }
                            else { Button("Switch") { model.switchTo(profile) }.disabled(model.busy || model.recoveryPending || !model.vaultReady) }
                            Menu {
                                Button("Rename") { model.rename(profile) }
                                Button("Remove saved login") { model.remove(profile) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy || model.recoveryPending || !model.vaultReady)
                        }
                        PlanSelection(profile: profile, demo: model.demo)
                        if profile.id != model.profiles.last?.id { Divider().padding(.top, 4) }
                        }
                    }
                }
                CombinedPace(model: model)
                Button { model.addAccount() } label: { Label("Add account", systemImage: "plus") }.disabled(model.busy || model.recoveryPending || !model.vaultReady)
            }
            if let code = model.loginCode {
                VStack(alignment: .leading, spacing: 10) {
                    Text(code).font(.system(size: 25, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy code") { model.copyCode() }
                        Button("Open OpenAI sign-in") { model.openLogin() }.buttonStyle(.borderedProminent)
                    }

                }
            }
            if model.signingIn { Button("Cancel sign-in") { model.cancelLogin() }.font(.caption) }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.recoveryPending { Button("Restore previous login") { model.restore() }.disabled(model.busy) }
            Divider()
            HStack {
                Button("Refresh") { model.refreshUsage() }.disabled(model.busy || model.active == nil || !model.vaultReady)
                Text(model.refreshNotice).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Open Codex") { Task { try? await model.openCodex() } }.disabled(model.busy)
                Menu {
                    Text("Saved logins: macOS Keychain")
                    Text("Manual switching · no auto-updater")
                    Divider()
                    Button("Quit Codex Accounts") { NSApp.terminate(nil) }.disabled(model.busy)
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 11))
        }
        .padding(22)
        .frame(width: 500)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var sizingSubscription: AnyCancellable?
    private var popupController: NSHostingController<AnyView>?
    private var model: AccountModel!
    private var processLock: ProcessLock?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        if !preview {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Accounts", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                processLock = try ProcessLock(at: support.appendingPathComponent("app.lock"))
            } catch {
                let alert = NSAlert(); alert.messageText = error.localizedDescription
                alert.runModal(); NSApp.terminate(nil); return
            }
        }
        model = AccountModel(demo: preview)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: "Codex Accounts")
        status.button?.toolTip = "Codex Accounts"
        status.button?.target = self; status.button?.action = #selector(toggle)
        popover = NSPopover(); popover.behavior = .transient
        popover.animates = false
        popupController = NSHostingController(rootView: AnyView(EmptyView()))
        popupController?.sizingOptions = []
        popover.contentViewController = popupController
        sizingSubscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sizePopup() }
        }
        if (preview && !CommandLine.arguments.contains("--preview-popup")) || CommandLine.arguments.contains("--show-window") || model.profiles.isEmpty {
            let controller = NSHostingController(rootView: AccountPanel(model: model))
            let win = NSWindow(contentViewController: controller)
            win.title = preview ? "Codex Accounts · Preview" : "Codex Accounts"
            win.styleMask = [.titled, .closable]; win.center(); win.makeKeyAndOrderFront(nil)
            window = win; NSApp.activate(ignoringOtherApps: true)
        }
        if preview && CommandLine.arguments.contains("--preview-popup") {
            DispatchQueue.main.async { self.toggle() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window, !flag { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else if !flag { toggle() }
        return true
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            model.syncCurrent()
            sizePopup()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    private func sizePopup() {
        guard let button = status.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let maximum = max(CGFloat(200), (screen?.visibleFrame.height ?? 800) - 40)
        let measure = NSHostingView(rootView: AccountPanel(model: model).fixedSize(horizontal: false, vertical: true))
        let height = min(maximum, ceil(measure.fittingSize.height))
        popupController?.rootView = AnyView(
            ScrollView(.vertical) {
                AccountPanel(model: model).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 500, height: height, alignment: .top)
        )
        popupController?.view.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        popover.contentSize = NSSize(width: 500, height: height)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true { return .terminateCancel }
        return .terminateNow
    }
}

struct PlanSelection: View {
    let profile: Profile
    var demo = false
    @AppStorage("pacePlanSelections") private var selections = "{}"
    var body: some View {
        let saved = demo ? [profile.id: ((try? Identity.parse(profile.auth).plan) ?? "Plus")] : planSelections(selections)
        Menu {
            ForEach(["Plus", "Pro 5×", "Pro 20×"], id: \.self) { plan in
                Button(plan) {
                    var values = saved; values[profile.id] = plan
                    if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) { selections = text }
                }
            }
        } label: { Text(saved[profile.id] ?? ((try? Identity.parse(profile.auth).plan.lowercased()) == "plus" ? "Plus" : "Choose plan")) }
        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).disabled(demo)
    }
}
func planSelections(_ text: String) -> [String: String] {
    (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
}
struct CombinedPace: View {
    @ObservedObject var model: AccountModel
    @AppStorage("pacePlanSelections") private var selections = "{}"
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let saved = model.demo ? Dictionary(uniqueKeysWithValues: model.profiles.enumerated().map { ($0.element.id, $0.offset == 0 ? "Pro 20×" : $0.offset == 1 ? "Pro 5×" : "Plus") }) : planSelections(selections)
            let entries = model.profiles.compactMap { profile -> (Profile, Double, WeeklyPace)? in
                let plan = saved[profile.id] ?? ((try? Identity.parse(profile.auth).plan.lowercased()) == "plus" ? "Plus" : "")
                let weight: Double = plan == "Plus" ? 1 : plan == "Pro 5×" ? 5 : plan == "Pro 20×" ? 20 : 0
                guard weight > 0, let week = model.accountUsage[profile.id]?.windows.first(where: { $0.title == "Weekly" }), let reset = week.resets,
                      let pace = WeeklyPace.calculate(remaining: week.remaining, reset: reset, now: context.date) else { return nil }
                return (profile, weight, pace)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Combined weekly pace").font(.system(size: 13, weight: .semibold))
                if !entries.isEmpty && entries.count == model.profiles.count {
                    let total = entries.reduce(0) { $0 + $1.1 }
                    let used = entries.reduce(0) { $0 + $1.1 * $1.2.used } / total
                    let expected = entries.reduce(0) { $0 + $1.1 * $1.2.expectedUsed } / total
                    let budget = entries.reduce(0) { $0 + $1.1 * $1.2.dailyBudget } / total
                    HStack {
                        Text(String(format: "%.0f%% left", 100 - used)).font(.system(size: 20, weight: .semibold))
                        Spacer()
                        Text(used > expected + 5 ? "Above pace" : "On track").foregroundStyle(used > expected + 5 ? Color.orange : Color.teal)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                    let color = accountColor(index)
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(color.opacity(0.18))
                                        Rectangle().fill(color).frame(width: geometry.size.width * entry.1 / total * entry.2.used / 100)
                                    }.frame(width: geometry.size.width * entry.1 / total)
                                }
                            }.clipShape(Capsule())
                        }
                    }.frame(height: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            HStack(spacing: 4) {
                                Circle().fill(accountColor(index)).frame(width: 7, height: 7)
                                Text(entry.0.label)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.1f%% / day budget", budget))
                    }
                    Text(String(format: "%.0f%% used · %.0f%% at steady pace", used, expected)).foregroundStyle(.secondary)
                    Text("Solid = used · pale = left · plan-weighted estimate").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Choose account plans and refresh usage to see the total.").foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).padding(.vertical, 6)
            .help("Combined estimate weighted by Plus 1×, Pro 5× and Pro 20×. Each account keeps its own reset date. Allowances cannot transfer between accounts; the daily budget sums each account's remaining allowance divided by its time to reset.")
        }
    }
}

func accountColor(_ index: Int) -> Color {
    let colors: [Color] = [.teal, .indigo, .orange, .pink, .blue, .green]
    return colors[index % colors.count]
}
