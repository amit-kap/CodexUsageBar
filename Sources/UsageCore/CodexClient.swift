import Foundation

/// An owned, read-only app-server connection. No model turns or credential parsing.
@MainActor
public final class CodexClient {
    public var onUsageUpdate: ((UsageSnapshot) -> Void)?
    public var onDisconnect: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var lines = LineBuffer()
    private var nextID = 1
    private var ready = false
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private let command: URL?
    private let arguments: [String]
    private let timeout: TimeInterval

    public init(command: URL? = nil, arguments: [String] = ["app-server", "--stdio"], timeout: TimeInterval = 20) {
        self.command = command
        self.arguments = arguments
        self.timeout = timeout
    }

    public static func discoverExecutable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func readUsage() async throws -> UsageSnapshot {
        do {
            try await connect()
            let data = try await request(method: "account/rateLimits/read")
            guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
                throw UsageFailure.invalidResponse
            }
            return snapshot
        } catch {
            // Reinitialize on the next poll, including after a wedged subprocess.
            stop()
            throw error
        }
    }

    private func connect() async throws {
        if ready, process?.isRunning == true { return }
        stop()
        guard let executable = command ?? Self.discoverExecutable() else { throw UsageFailure.cliMissing }
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let token = generation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if bytes.isEmpty { self.disconnected() }
                else { self.receive(bytes) }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.disconnected()
            }
        }
        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        try child.run()
        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "codex_usage_bar", "title": "Codex Usage Bar", "version": "1.0.0"]
        ])
        try send(["method": "initialized"])
        ready = true
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> Data {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self, timeout] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return }
                self?.finish(id, result: .failure(UsageFailure.timeout))
            }
            do {
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                try send(message)
            } catch { finish(id, result: .failure(error)) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw UsageFailure.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ bytes: Data) {
        for line in lines.append(bytes) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, pending[id] != nil {
                if let error = message["error"] as? [String: Any] {
                    let raw = error["message"] as? String ?? "Could not read Codex usage."
                    let lower = raw.lowercased()
                    let friendly = lower.contains("auth") || lower.contains("sign") || lower.contains("401")
                        ? "Sign in to Codex with your ChatGPT account, then refresh."
                        : String(raw.prefix(240))
                    finish(id, result: .failure(UsageFailure.remote(friendly)))
                } else if let result = message["result"],
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    finish(id, result: .success(data))
                } else { finish(id, result: .failure(UsageFailure.invalidResponse)) }
            } else if message["method"] as? String == "account/rateLimits/updated",
                      let params = message["params"],
                      let data = try? JSONSerialization.data(withJSONObject: params),
                      let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
                onUsageUpdate?(snapshot)
            }
        }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func disconnected() {
        stop()
        onDisconnect?()
    }

    public func stop() {
        generation = UUID()
        ready = false
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        if let child = process, child.isRunning {
            child.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        lines = LineBuffer()
        for id in Array(pending.keys) { finish(id, result: .failure(UsageFailure.disconnected)) }
    }
}
