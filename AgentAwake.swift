import CryptoKit
import Darwin
import Foundation

private let sessionMinutes = 9_999
private let sessionSeconds = Double(sessionMinutes * 60)
private let sessionToleranceSeconds = 180

private struct Owner: Codable {
    var pid: Int32
    var started: String
}

private struct Lease: Codable {
    var source: String
    var sessionHash: String
    var turnHash: String?
    var createdAt: Double
    var refreshedAt: Double
    var expiresAt: Double
    var owner: Owner?
}

private struct OwnedSession: Codable {
    var startedAt: Double
}

private struct ControllerState: Codable {
    var version = 2
    var leases: [String: Lease] = [:]
    var shutdownNotBefore: Double?
    var ownedSession: OwnedSession?
    var dryRunAmphetamineActive = false
}

private struct ProcessRecord {
    var pid: Int32
    var parentPID: Int32
    var started: String
    var command: String
}

private struct HookPayload {
    let values: [String: Any]

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ControllerError.invalidPayload("hook input must be a JSON object")
        }
        values = dictionary
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    func bool(_ key: String) -> Bool? {
        values[key] as? Bool
    }
}

private enum HookAction: String {
    case start
    case heartbeat
    case stop
    case stopSession = "stop-session"
}

private enum Source: String {
    case codex
    case cursor
    case claude
}

private enum ControllerError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidPayload(String)
    case missingIdentity(String)
    case processFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "invalid arguments"
        case let .invalidPayload(message):
            return message
        case let .missingIdentity(source):
            return "missing session identity for \(source)"
        case let .processFailed(message):
            return message
        }
    }
}

private final class Controller {
    private let fileManager = FileManager.default
    private let environment = ProcessInfo.processInfo.environment
    private let stateDirectory: URL
    private let stateFile: URL
    private let lockFile: URL
    private let logFile: URL
    private let dryRun: Bool

    init() throws {
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultBase = home
            .appendingPathComponent("Library/Application Support/AgentAwake", isDirectory: true)
        let base = environment["AGENT_AWAKE_BASE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? defaultBase
        stateDirectory = environment["AGENT_AWAKE_STATE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? base.appendingPathComponent("state-v2", isDirectory: true)
        stateFile = stateDirectory.appendingPathComponent("state.json")
        lockFile = stateDirectory.appendingPathComponent("controller.lock")
        logFile = base.appendingPathComponent("agent-awake-v2.log")
        dryRun = environment["AGENT_AWAKE_DRY_RUN"] == "1"

        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(stateDirectory.path, 0o700)
    }

    func handleHook(source requestedSource: String, action rawAction: String, input: Data) {
        do {
            guard let action = HookAction(rawValue: rawAction) else {
                throw ControllerError.invalidArguments
            }
            let payload = try HookPayload(data: input)
            let source = try resolveSource(requestedSource, payload: payload)

            if source == .cursor,
               environment["CURSOR_CODE_REMOTE"] == "true"
                   || payload.bool("is_background_agent") == true {
                log("Ignored remote/background Cursor event")
                return
            }

            let identity = try identityFor(source: source, payload: payload)
            let owner = discoverOwner(for: source)
            let timestamp = now()

            try withLockedState { state in
                let matchingKeys = state.leases.compactMap { key, lease in
                    lease.source == source.rawValue && lease.sessionHash == identity.sessionHash
                        ? key
                        : nil
                }

                switch action {
                case .start:
                    let key = leaseKey(
                        source: source,
                        sessionHash: identity.sessionHash,
                        turnHash: identity.turnHash
                    )
                    upsertLease(
                        key: key,
                        source: source,
                        identity: identity,
                        owner: owner,
                        timestamp: timestamp,
                        state: &state
                    )
                    state.shutdownNotBefore = nil

                case .heartbeat:
                    let exactKey = leaseKey(
                        source: source,
                        sessionHash: identity.sessionHash,
                        turnHash: identity.turnHash
                    )
                    if state.leases[exactKey] != nil {
                        refreshLease(
                            key: exactKey,
                            owner: owner,
                            timestamp: timestamp,
                            state: &state
                        )
                    } else if !matchingKeys.isEmpty {
                        for key in matchingKeys {
                            refreshLease(
                                key: key,
                                owner: owner,
                                timestamp: timestamp,
                                state: &state
                            )
                        }
                    } else {
                        upsertLease(
                            key: exactKey,
                            source: source,
                            identity: identity,
                            owner: owner,
                            timestamp: timestamp,
                            state: &state
                        )
                        log("Recovered missing \(source.rawValue) start lease from activity event")
                    }
                    state.shutdownNotBefore = nil

                case .stop:
                    if let turnHash = identity.turnHash {
                        let key = leaseKey(
                            source: source,
                            sessionHash: identity.sessionHash,
                            turnHash: turnHash
                        )
                        state.leases.removeValue(forKey: key)
                    } else {
                        for key in matchingKeys {
                            state.leases.removeValue(forKey: key)
                        }
                    }
                    scheduleShutdownIfEmpty(timestamp: timestamp, state: &state)

                case .stopSession:
                    for key in matchingKeys {
                        state.leases.removeValue(forKey: key)
                    }
                    scheduleShutdownIfEmpty(timestamp: timestamp, state: &state)
                }

                reconcile(timestamp: timestamp, state: &state)
            }
        } catch {
            log("Hook event failed open: \(error)")
        }
    }

    func reconcileNow() {
        do {
            let timestamp = now()
            try withLockedState { state in
                reconcile(timestamp: timestamp, state: &state)
            }
        } catch {
            log("Reconcile failed: \(error)")
        }
    }

    func printStatus() {
        do {
            try withLockedState { state in
                let sources = Dictionary(grouping: state.leases.values, by: \.source)
                    .mapValues(\.count)
                let output: [String: Any] = [
                    "version": state.version,
                    "leaseCount": state.leases.count,
                    "sources": sources,
                    "shutdownNotBefore": state.shutdownNotBefore as Any,
                    "amphetamineOwned": state.ownedSession != nil,
                    "amphetamineActive": dryRun
                        ? state.dryRunAmphetamineActive
                        : amphetamineIsActive(),
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: output,
                    options: [.prettyPrinted, .sortedKeys]
                )
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } catch {
            let message = "{\"error\":\"status unavailable\"}\n"
            FileHandle.standardOutput.write(Data(message.utf8))
        }
    }

    func selfTestLargeProcessOutput() {
        let result = runProcess(
            executable: "/usr/bin/jot",
            arguments: ["-b", "agent-awake-process-output", "100000"]
        )
        let output: [String: Any] = [
            "status": result.status,
            "bytes": result.stdout.utf8.count,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func resolveSource(_ requested: String, payload: HookPayload) throws -> Source {
        if environment["CURSOR_VERSION"] != nil || payload.string("conversation_id") != nil {
            return .cursor
        }
        if requested != "auto", let source = Source(rawValue: requested) {
            return source
        }
        if payload.string("turn_id") != nil {
            return .codex
        }
        if payload.string("session_id") != nil {
            return .claude
        }
        throw ControllerError.invalidPayload("could not identify hook source")
    }

    private func identityFor(source: Source, payload: HookPayload) throws
        -> (sessionHash: String, turnHash: String?)
    {
        let sessionID: String?
        let turnID: String?

        switch source {
        case .cursor:
            sessionID = payload.string("conversation_id") ?? payload.string("session_id")
            turnID = payload.string("generation_id")
        case .codex:
            sessionID = payload.string("session_id")
            turnID = payload.string("turn_id")
        case .claude:
            sessionID = payload.string("session_id")
            turnID = nil
        }

        guard let sessionID else {
            throw ControllerError.missingIdentity(source.rawValue)
        }
        return (
            sessionHash: digest(sessionID),
            turnHash: turnID.map(digest)
        )
    }

    private func leaseKey(
        source: Source,
        sessionHash: String,
        turnHash: String?
    ) -> String {
        digest([source.rawValue, sessionHash, turnHash ?? "session"].joined(separator: ":"))
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func upsertLease(
        key: String,
        source: Source,
        identity: (sessionHash: String, turnHash: String?),
        owner: Owner?,
        timestamp: Double,
        state: inout ControllerState
    ) {
        let existing = state.leases[key]
        state.leases[key] = Lease(
            source: source.rawValue,
            sessionHash: identity.sessionHash,
            turnHash: identity.turnHash,
            createdAt: existing?.createdAt ?? timestamp,
            refreshedAt: timestamp,
            expiresAt: timestamp + leaseLifetime,
            owner: owner ?? existing?.owner
        )
    }

    private func refreshLease(
        key: String,
        owner: Owner?,
        timestamp: Double,
        state: inout ControllerState
    ) {
        guard var lease = state.leases[key] else {
            return
        }
        lease.refreshedAt = timestamp
        lease.expiresAt = timestamp + leaseLifetime
        lease.owner = owner ?? lease.owner
        state.leases[key] = lease
    }

    private var leaseLifetime: Double {
        environment["AGENT_AWAKE_LEASE_SECONDS"].flatMap(Double.init) ?? (8 * 60 * 60)
    }

    private var shutdownGrace: Double {
        environment["AGENT_AWAKE_STOP_GRACE_SECONDS"].flatMap(Double.init) ?? 15
    }

    private func scheduleShutdownIfEmpty(
        timestamp: Double,
        state: inout ControllerState
    ) {
        if state.leases.isEmpty {
            state.shutdownNotBefore = max(
                state.shutdownNotBefore ?? 0,
                timestamp + shutdownGrace
            )
        }
    }

    private func reconcile(timestamp: Double, state: inout ControllerState) {
        let processSnapshot = dryRun ? nil : loadProcessSnapshot()
        let beforeSweep = state.leases.count
        state.leases = state.leases.filter { _, lease in
            if lease.expiresAt <= timestamp {
                log("Expired stale \(lease.source) lease")
                return false
            }
            guard let owner = lease.owner, let processSnapshot else {
                return true
            }
            guard let current = processSnapshot[owner.pid] else {
                log("Cleared \(lease.source) lease after its host exited")
                return false
            }
            if current.started != owner.started {
                log("Cleared \(lease.source) lease after PID reuse")
                return false
            }
            return true
        }

        if beforeSweep > 0, state.leases.isEmpty, state.shutdownNotBefore == nil {
            state.shutdownNotBefore = timestamp
        }

        if !state.leases.isEmpty {
            state.shutdownNotBefore = nil
            ensureAmphetamineActive(timestamp: timestamp, state: &state)
            return
        }

        guard timestamp >= (state.shutdownNotBefore ?? timestamp) else {
            return
        }
        stopOwnedAmphetamineIfNeeded(timestamp: timestamp, state: &state)
        state.shutdownNotBefore = nil
    }

    private func ensureAmphetamineActive(
        timestamp: Double,
        state: inout ControllerState
    ) {
        if sessionMatchesOwnership(timestamp: timestamp, state: state) {
            return
        }

        if state.ownedSession != nil {
            state.ownedSession = nil
        }

        if dryRun {
            if state.dryRunAmphetamineActive {
                return
            }
            state.dryRunAmphetamineActive = true
            state.ownedSession = OwnedSession(startedAt: timestamp)
            return
        }

        if amphetamineIsActive() {
            return
        }

        do {
            try amphetamine(
                "start new session with options {duration:\(sessionMinutes), interval:minutes, displaySleepAllowed:true}"
            )
            try amphetamine("allow display sleep")
            try amphetamine("enable closed display mode")
            state.ownedSession = OwnedSession(startedAt: timestamp)
            log("Started owned Amphetamine session for active agent lease")
        } catch {
            if amphetamineIsActive() {
                try? amphetamine("end session")
            }
            state.ownedSession = nil
            log("Could not establish Amphetamine session: \(error)")
        }
    }

    private func stopOwnedAmphetamineIfNeeded(
        timestamp: Double,
        state: inout ControllerState
    ) {
        guard state.ownedSession != nil else {
            return
        }

        if dryRun {
            if sessionMatchesOwnership(timestamp: timestamp, state: state) {
                state.dryRunAmphetamineActive = false
            }
            state.ownedSession = nil
            return
        }

        if sessionMatchesOwnership(timestamp: timestamp, state: state) {
            do {
                try amphetamine("end session")
                log("Ended owned Amphetamine session after final agent lease")
            } catch {
                log("Could not end owned Amphetamine session: \(error)")
                return
            }
        } else {
            log("Amphetamine session changed externally; left it untouched")
        }
        state.ownedSession = nil
    }

    private func sessionMatchesOwnership(
        timestamp: Double,
        state: ControllerState
    ) -> Bool {
        guard let owned = state.ownedSession else {
            return false
        }
        if dryRun {
            return state.dryRunAmphetamineActive
        }
        guard amphetamineIsActive(),
              let remaining = try? amphetamineResult("session time remaining"),
              let remainingSeconds = Double(remaining.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }
        let expected: Double = sessionSeconds - (timestamp - owned.startedAt)
        let difference: Double = Swift.abs(remainingSeconds - expected)
        return expected > 0 && difference <= Double(sessionToleranceSeconds)
    }

    private func amphetamineIsActive() -> Bool {
        guard let result = try? amphetamineResult("session is active") else {
            return false
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func amphetamine(_ command: String) throws {
        _ = try amphetamineResult(command)
    }

    private func amphetamineResult(_ command: String) throws -> String {
        let result = runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Amphetamine\" to \(command)"]
        )
        guard result.status == 0 else {
            throw ControllerError.processFailed("Amphetamine AppleScript failed")
        }
        return result.stdout
    }

    private func discoverOwner(for source: Source) -> Owner? {
        guard let snapshot = loadProcessSnapshot() else {
            return nil
        }
        var current = Int32(getpid())
        var visited = Set<Int32>()

        for _ in 0..<24 {
            guard visited.insert(current).inserted,
                  let record = snapshot[current]
            else {
                break
            }
            if hostCommand(record.command, matches: source) {
                return Owner(pid: record.pid, started: record.started)
            }
            if record.parentPID <= 1 {
                break
            }
            current = record.parentPID
        }
        return nil
    }

    private func hostCommand(_ command: String, matches source: Source) -> Bool {
        switch source {
        case .cursor:
            return command.contains("/Applications/Cursor.app/")
                || command.contains("/cursor-agent")
        case .codex:
            return command.contains("/Applications/ChatGPT.app/")
                || command.contains("/Applications/Codex.app/")
                || (command.contains("/codex") && command.contains("app-server"))
        case .claude:
            return command.contains("/Applications/Claude.app/")
                || (command.contains("/claude") && !command.contains("agent-awake"))
        }
    }

    private func loadProcessSnapshot() -> [Int32: ProcessRecord]? {
        let result = runProcess(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,lstart=,command="]
        )
        guard result.status == 0 else {
            return nil
        }

        var records: [Int32: ProcessRecord] = [:]
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count >= 8,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1])
            else {
                continue
            }
            let started = fields[2...6].joined(separator: " ")
            let command = fields[7...].joined(separator: " ")
            records[pid] = ProcessRecord(
                pid: pid,
                parentPID: parentPID,
                started: started,
                command: command
            )
        }
        return records
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "")
        }
    }

    private func now() -> Double {
        environment["AGENT_AWAKE_TEST_NOW"].flatMap(Double.init)
            ?? Date().timeIntervalSince1970
    }

    private func withLockedState<T>(
        _ body: (inout ControllerState) throws -> T
    ) throws -> T {
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ControllerError.processFailed("could not open state lock")
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        chmod(lockFile.path, 0o600)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ControllerError.processFailed("could not lock controller state")
        }

        var state = loadState()
        let result = try body(&state)
        try saveState(state)
        return result
    }

    private func loadState() -> ControllerState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(ControllerState.self, from: data)
        else {
            return ControllerState()
        }
        return state
    }

    private func saveState(_ state: ControllerState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFile, options: .atomic)
        chmod(stateFile.path, 0o600)
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(
                atPath: logFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: logFile) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}

private func main() {
    do {
        let controller = try Controller()
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            throw ControllerError.invalidArguments
        }

        switch arguments[1] {
        case "hook":
            guard arguments.count == 4 else {
                throw ControllerError.invalidArguments
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            controller.handleHook(
                source: arguments[2],
                action: arguments[3],
                input: input
            )
        case "reconcile":
            controller.reconcileNow()
        case "status":
            controller.printStatus()
        case "__self-test-large-process-output":
            controller.selfTestLargeProcessOutput()
        default:
            throw ControllerError.invalidArguments
        }
    } catch {
        // Hook failures must fail open and must not emit protocol-breaking output.
        exit(0)
    }
}

main()
