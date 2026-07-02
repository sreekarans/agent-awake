import CryptoKit
import Darwin
import Foundation

private let sessionMinutes = 9_999
private let sessionSeconds = Double(sessionMinutes * 60)
private let sessionToleranceSeconds = 180
private let historySchemaVersion = 1
private let defaultHistoryFileBytes = 10 * 1_024 * 1_024
private let defaultHistoryArchives = 4
private let defaultHistoryHourlyBytes = 10 * 1_024 * 1_024
private let defaultHeartbeatSummarySeconds = 5 * 60

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

private struct PendingHeartbeat: Codable {
    var source: String
    var sessionHash: String
    var turnHash: String?
    var leaseKey: String
    var owner: Owner?
    var lastWrittenAt: Double
    var firstPendingAt: Double?
    var lastPendingAt: Double?
    var count: Int
    var expiresAtBefore: Double?
    var expiresAtAfter: Double
    var leaseCount: Int
}

private struct ControllerState: Codable {
    var version = 3
    var leases: [String: Lease] = [:]
    var shutdownNotBefore: Double?
    var ownedSession: OwnedSession?
    var dryRunAmphetamineActive = false
    var historySequence = 0
    var historyHourStart: Double?
    var historyBytesThisHour = 0
    var historyPausedUntil: Double?
    var pendingHeartbeats: [String: PendingHeartbeat] = [:]

    private enum CodingKeys: String, CodingKey {
        case version
        case leases
        case shutdownNotBefore
        case ownedSession
        case dryRunAmphetamineActive
        case historySequence
        case historyHourStart
        case historyBytesThisHour
        case historyPausedUntil
        case pendingHeartbeats
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = 3
        leases = try container.decodeIfPresent([String: Lease].self, forKey: .leases) ?? [:]
        shutdownNotBefore = try container.decodeIfPresent(
            Double.self,
            forKey: .shutdownNotBefore
        )
        ownedSession = try container.decodeIfPresent(
            OwnedSession.self,
            forKey: .ownedSession
        )
        dryRunAmphetamineActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .dryRunAmphetamineActive
        ) ?? false
        historySequence = try container.decodeIfPresent(
            Int.self,
            forKey: .historySequence
        ) ?? 0
        historyHourStart = try container.decodeIfPresent(
            Double.self,
            forKey: .historyHourStart
        )
        historyBytesThisHour = try container.decodeIfPresent(
            Int.self,
            forKey: .historyBytesThisHour
        ) ?? 0
        historyPausedUntil = try container.decodeIfPresent(
            Double.self,
            forKey: .historyPausedUntil
        )
        pendingHeartbeats = try container.decodeIfPresent(
            [String: PendingHeartbeat].self,
            forKey: .pendingHeartbeats
        ) ?? [:]
    }
}

private struct HistoryEvent: Codable {
    var schemaVersion = historySchemaVersion
    var sequence = 0
    var timestamp: String
    var timestampEpoch: Double
    var type: String
    var source: String?
    var action: String?
    var sessionHash: String?
    var turnHash: String?
    var leaseKey: String?
    var ownerPID: Int32?
    var ownerStarted: String?
    var leaseCountBefore: Int?
    var leaseCountAfter: Int?
    var expiresAtBefore: Double?
    var expiresAtAfter: Double?
    var amphetamineOwnedBefore: Bool?
    var amphetamineOwnedAfter: Bool?
    var amphetamineActiveBefore: Bool?
    var amphetamineActiveAfter: Bool?
    var result: String?
    var reason: String?
    var error: String?
    var heartbeatCount: Int?
    var heartbeatFirstAt: Double?
    var heartbeatLastAt: Double?

    init(
        timestamp: Double,
        type: String,
        source: String? = nil,
        action: String? = nil,
        sessionHash: String? = nil,
        turnHash: String? = nil,
        leaseKey: String? = nil,
        owner: Owner? = nil,
        leaseCountBefore: Int? = nil,
        leaseCountAfter: Int? = nil,
        expiresAtBefore: Double? = nil,
        expiresAtAfter: Double? = nil,
        amphetamineOwnedBefore: Bool? = nil,
        amphetamineOwnedAfter: Bool? = nil,
        amphetamineActiveBefore: Bool? = nil,
        amphetamineActiveAfter: Bool? = nil,
        result: String? = nil,
        reason: String? = nil,
        error: String? = nil,
        heartbeatCount: Int? = nil,
        heartbeatFirstAt: Double? = nil,
        heartbeatLastAt: Double? = nil
    ) {
        self.timestamp = HistoryEvent.format(timestamp)
        timestampEpoch = timestamp
        self.type = type
        self.source = source
        self.action = action
        self.sessionHash = sessionHash
        self.turnHash = turnHash
        self.leaseKey = leaseKey
        ownerPID = owner?.pid
        ownerStarted = owner?.started
        self.leaseCountBefore = leaseCountBefore
        self.leaseCountAfter = leaseCountAfter
        self.expiresAtBefore = expiresAtBefore
        self.expiresAtAfter = expiresAtAfter
        self.amphetamineOwnedBefore = amphetamineOwnedBefore
        self.amphetamineOwnedAfter = amphetamineOwnedAfter
        self.amphetamineActiveBefore = amphetamineActiveBefore
        self.amphetamineActiveAfter = amphetamineActiveAfter
        self.result = result
        self.reason = reason
        self.error = error
        self.heartbeatCount = heartbeatCount
        self.heartbeatFirstAt = heartbeatFirstAt
        self.heartbeatLastAt = heartbeatLastAt
    }

    private static func format(_ timestamp: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

private struct ProcessRecord: Codable {
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
    private let baseDirectory: URL
    private let stateDirectory: URL
    private let stateFile: URL
    private let lockFile: URL
    private let historyFile: URL
    private let fallbackLogFile: URL
    private let dryRun: Bool
    private var queuedHistoryEvents: [HistoryEvent] = []

    init() throws {
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultBase = home
            .appendingPathComponent("Library/Application Support/AgentAwake", isDirectory: true)
        baseDirectory = environment["AGENT_AWAKE_BASE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? defaultBase
        stateDirectory = environment["AGENT_AWAKE_STATE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? baseDirectory.appendingPathComponent("state-v2", isDirectory: true)
        stateFile = stateDirectory.appendingPathComponent("state.json")
        lockFile = stateDirectory.appendingPathComponent("controller.lock")
        historyFile = baseDirectory.appendingPathComponent("history.jsonl")
        fallbackLogFile = baseDirectory.appendingPathComponent("agent-awake-v2.log")
        dryRun = environment["AGENT_AWAKE_DRY_RUN"] == "1"

        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(baseDirectory.path, 0o700)
        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(stateDirectory.path, 0o700)
    }

    func handleHook(source requestedSource: String, action rawAction: String, input: Data) {
        let timestamp = now()
        do {
            guard let action = HookAction(rawValue: rawAction) else {
                throw ControllerError.invalidArguments
            }
            let payload = try HookPayload(data: input)
            let source = try resolveSource(requestedSource, payload: payload)

            if source == .cursor,
               environment["CURSOR_CODE_REMOTE"] == "true"
                   || payload.bool("is_background_agent") == true {
                let identity = try? identityFor(source: source, payload: payload)
                let key = identity.map {
                    leaseKey(
                        source: source,
                        sessionHash: $0.sessionHash,
                        turnHash: $0.turnHash
                    )
                }
                recordStandaloneHistory(
                    HistoryEvent(
                        timestamp: timestamp,
                        type: "hook_ignored",
                        source: source.rawValue,
                        action: action.rawValue,
                        sessionHash: identity?.sessionHash,
                        turnHash: identity?.turnHash,
                        leaseKey: key,
                        result: "ignored",
                        reason: "remote_or_background_cursor"
                    )
                )
                return
            }

            let identity = try identityFor(source: source, payload: payload)
            let owner = discoverOwner(for: source)

            try withLockedState { state in
                let hookLeaseCountBefore = state.leases.count
                let amphetamineOwnedBefore = state.ownedSession != nil
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
                    let oldLease = state.leases[key]
                    upsertLease(
                        key: key,
                        source: source,
                        identity: identity,
                        owner: owner,
                        timestamp: timestamp,
                        state: &state
                    )
                    state.shutdownNotBefore = nil
                    let newLease = state.leases[key]
                    queueHistory(
                        HistoryEvent(
                            timestamp: timestamp,
                            type: "hook_received",
                            source: source.rawValue,
                            action: action.rawValue,
                            sessionHash: identity.sessionHash,
                            turnHash: identity.turnHash,
                            leaseKey: key,
                            owner: owner,
                            leaseCountBefore: hookLeaseCountBefore,
                            leaseCountAfter: state.leases.count,
                            amphetamineOwnedBefore: amphetamineOwnedBefore,
                            amphetamineOwnedAfter: state.ownedSession != nil,
                            result: "accepted"
                        )
                    )
                    queueHistory(
                        HistoryEvent(
                            timestamp: timestamp,
                            type: oldLease == nil ? "lease_created" : "lease_refreshed",
                            source: source.rawValue,
                            action: action.rawValue,
                            sessionHash: identity.sessionHash,
                            turnHash: identity.turnHash,
                            leaseKey: key,
                            owner: newLease?.owner,
                            leaseCountBefore: hookLeaseCountBefore,
                            leaseCountAfter: state.leases.count,
                            expiresAtBefore: oldLease?.expiresAt,
                            expiresAtAfter: newLease?.expiresAt,
                            result: oldLease == nil ? "created" : "refreshed"
                        )
                    )

                case .heartbeat:
                    let exactKey = leaseKey(
                        source: source,
                        sessionHash: identity.sessionHash,
                        turnHash: identity.turnHash
                    )
                    if state.leases[exactKey] != nil {
                        let expiresAtBefore = state.leases[exactKey]?.expiresAt
                        refreshLease(
                            key: exactKey,
                            owner: owner,
                            timestamp: timestamp,
                            state: &state
                        )
                        recordHeartbeatHistory(
                            key: exactKey,
                            source: source,
                            identity: identity,
                            owner: owner,
                            timestamp: timestamp,
                            expiresAtBefore: expiresAtBefore,
                            result: "refreshed",
                            state: &state
                        )
                    } else if !matchingKeys.isEmpty {
                        for key in matchingKeys {
                            let expiresAtBefore = state.leases[key]?.expiresAt
                            refreshLease(
                                key: key,
                                owner: owner,
                                timestamp: timestamp,
                                state: &state
                            )
                            recordHeartbeatHistory(
                                key: key,
                                source: source,
                                identity: identity,
                                owner: owner,
                                timestamp: timestamp,
                                expiresAtBefore: expiresAtBefore,
                                result: "refreshed_session",
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
                        queueHistory(
                            HistoryEvent(
                                timestamp: timestamp,
                                type: "missed_start_recovered",
                                source: source.rawValue,
                                action: action.rawValue,
                                sessionHash: identity.sessionHash,
                                turnHash: identity.turnHash,
                                leaseKey: exactKey,
                                owner: owner,
                                leaseCountBefore: hookLeaseCountBefore,
                                leaseCountAfter: state.leases.count,
                                expiresAtAfter: state.leases[exactKey]?.expiresAt,
                                result: "lease_created"
                            )
                        )
                        recordHeartbeatHistory(
                            key: exactKey,
                            source: source,
                            identity: identity,
                            owner: owner,
                            timestamp: timestamp,
                            expiresAtBefore: nil,
                            result: "recovered_missing_start",
                            state: &state
                        )
                    }
                    state.shutdownNotBefore = nil

                case .stop:
                    if let turnHash = identity.turnHash {
                        let key = leaseKey(
                            source: source,
                            sessionHash: identity.sessionHash,
                            turnHash: turnHash
                        )
                        removeLease(
                            key: key,
                            action: action,
                            reason: "turn_stopped",
                            timestamp: timestamp,
                            state: &state
                        )
                    } else {
                        for key in matchingKeys {
                            removeLease(
                                key: key,
                                action: action,
                                reason: "session_stopped_without_turn",
                                timestamp: timestamp,
                                state: &state
                            )
                        }
                    }
                    scheduleShutdownIfEmpty(timestamp: timestamp, state: &state)
                    queueHistory(
                        HistoryEvent(
                            timestamp: timestamp,
                            type: "hook_received",
                            source: source.rawValue,
                            action: action.rawValue,
                            sessionHash: identity.sessionHash,
                            turnHash: identity.turnHash,
                            leaseCountBefore: hookLeaseCountBefore,
                            leaseCountAfter: state.leases.count,
                            amphetamineOwnedBefore: amphetamineOwnedBefore,
                            amphetamineOwnedAfter: state.ownedSession != nil,
                            result: hookLeaseCountBefore == state.leases.count
                                ? "no_matching_lease"
                                : "accepted"
                        )
                    )

                case .stopSession:
                    for key in matchingKeys {
                        removeLease(
                            key: key,
                            action: action,
                            reason: "session_ended",
                            timestamp: timestamp,
                            state: &state
                        )
                    }
                    scheduleShutdownIfEmpty(timestamp: timestamp, state: &state)
                    queueHistory(
                        HistoryEvent(
                            timestamp: timestamp,
                            type: "hook_received",
                            source: source.rawValue,
                            action: action.rawValue,
                            sessionHash: identity.sessionHash,
                            turnHash: identity.turnHash,
                            leaseCountBefore: hookLeaseCountBefore,
                            leaseCountAfter: state.leases.count,
                            amphetamineOwnedBefore: amphetamineOwnedBefore,
                            amphetamineOwnedAfter: state.ownedSession != nil,
                            result: matchingKeys.isEmpty ? "no_matching_lease" : "accepted"
                        )
                    )
                }

                reconcile(timestamp: timestamp, state: &state)
            }
        } catch {
            let source = Source(rawValue: requestedSource)?.rawValue
            let action = HookAction(rawValue: rawAction)?.rawValue
            recordStandaloneHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "hook_error",
                    source: source,
                    action: action,
                    result: "failed_open",
                    error: String(describing: error)
                )
            )
            fallbackLog("Hook event failed open: \(error)")
        }
    }

    func reconcileNow() {
        let timestamp = now()
        do {
            try withLockedState { state in
                reconcile(timestamp: timestamp, state: &state)
            }
        } catch {
            recordStandaloneHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "reconcile_error",
                    result: "failed",
                    error: String(describing: error)
                )
            )
            fallbackLog("Reconcile failed: \(error)")
        }
    }

    func printStatus() {
        do {
            try withReadOnlyState { state in
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
                    "historyPath": historyFile.path,
                    "historyRetainedBytes": retainedHistoryBytes(),
                    "historyPausedUntil": state.historyPausedUntil as Any,
                    "pendingHeartbeatCount": state.pendingHeartbeats.values
                        .reduce(0) { $0 + $1.count },
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

    private func recordHeartbeatHistory(
        key: String,
        source: Source,
        identity: (sessionHash: String, turnHash: String?),
        owner: Owner?,
        timestamp: Double,
        expiresAtBefore: Double?,
        result: String,
        state: inout ControllerState
    ) {
        guard let lease = state.leases[key] else {
            return
        }

        if var pending = state.pendingHeartbeats[key] {
            pending.count += 1
            pending.firstPendingAt = pending.firstPendingAt ?? timestamp
            pending.lastPendingAt = timestamp
            pending.expiresAtBefore = pending.expiresAtBefore ?? expiresAtBefore
            pending.expiresAtAfter = lease.expiresAt
            pending.owner = lease.owner ?? pending.owner
            pending.leaseCount = state.leases.count

            if timestamp - pending.lastWrittenAt >= heartbeatSummarySeconds {
                queueHeartbeatSummary(pending, timestamp: timestamp)
                pending.lastWrittenAt = timestamp
                pending.firstPendingAt = nil
                pending.lastPendingAt = nil
                pending.count = 0
                pending.expiresAtBefore = lease.expiresAt
            }
            state.pendingHeartbeats[key] = pending
            return
        }

        queueHistory(
            HistoryEvent(
                timestamp: timestamp,
                type: "heartbeat",
                source: source.rawValue,
                action: HookAction.heartbeat.rawValue,
                sessionHash: identity.sessionHash,
                turnHash: identity.turnHash,
                leaseKey: key,
                owner: lease.owner ?? owner,
                leaseCountBefore: state.leases.count,
                leaseCountAfter: state.leases.count,
                expiresAtBefore: expiresAtBefore,
                expiresAtAfter: lease.expiresAt,
                result: result,
                heartbeatCount: 1,
                heartbeatFirstAt: timestamp,
                heartbeatLastAt: timestamp
            )
        )
        state.pendingHeartbeats[key] = PendingHeartbeat(
            source: source.rawValue,
            sessionHash: identity.sessionHash,
            turnHash: identity.turnHash,
            leaseKey: key,
            owner: lease.owner ?? owner,
            lastWrittenAt: timestamp,
            firstPendingAt: nil,
            lastPendingAt: nil,
            count: 0,
            expiresAtBefore: lease.expiresAt,
            expiresAtAfter: lease.expiresAt,
            leaseCount: state.leases.count
        )
    }

    private func queueHeartbeatSummary(
        _ pending: PendingHeartbeat,
        timestamp: Double
    ) {
        guard pending.count > 0 else {
            return
        }
        queueHistory(
            HistoryEvent(
                timestamp: timestamp,
                type: "heartbeat_summary",
                source: pending.source,
                action: HookAction.heartbeat.rawValue,
                sessionHash: pending.sessionHash,
                turnHash: pending.turnHash,
                leaseKey: pending.leaseKey,
                owner: pending.owner,
                leaseCountBefore: pending.leaseCount,
                leaseCountAfter: pending.leaseCount,
                expiresAtBefore: pending.expiresAtBefore,
                expiresAtAfter: pending.expiresAtAfter,
                result: "merged",
                heartbeatCount: pending.count,
                heartbeatFirstAt: pending.firstPendingAt,
                heartbeatLastAt: pending.lastPendingAt
            )
        )
    }

    private func flushPendingHeartbeat(
        key: String,
        timestamp: Double,
        state: inout ControllerState
    ) {
        guard let pending = state.pendingHeartbeats.removeValue(forKey: key) else {
            return
        }
        queueHeartbeatSummary(pending, timestamp: timestamp)
    }

    private func removeLease(
        key: String,
        action: HookAction?,
        reason: String,
        timestamp: Double,
        state: inout ControllerState
    ) {
        guard let lease = state.leases[key] else {
            return
        }
        let countBefore = state.leases.count
        flushPendingHeartbeat(key: key, timestamp: timestamp, state: &state)
        state.leases.removeValue(forKey: key)
        queueHistory(
            HistoryEvent(
                timestamp: timestamp,
                type: "lease_removed",
                source: lease.source,
                action: action?.rawValue,
                sessionHash: lease.sessionHash,
                turnHash: lease.turnHash,
                leaseKey: key,
                owner: lease.owner,
                leaseCountBefore: countBefore,
                leaseCountAfter: state.leases.count,
                expiresAtBefore: lease.expiresAt,
                result: "removed",
                reason: reason
            )
        )
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
        let leaseCountBefore = state.leases.count
        let amphetamineOwnedBefore = state.ownedSession != nil
        let processSnapshot = dryRun
            && environment["AGENT_AWAKE_TEST_PROCESS_SNAPSHOT"] == nil
            ? nil
            : loadProcessSnapshot()
        for key in state.leases.keys.sorted() {
            guard let lease = state.leases[key] else {
                continue
            }
            if lease.expiresAt <= timestamp {
                removeLease(
                    key: key,
                    action: nil,
                    reason: "expired",
                    timestamp: timestamp,
                    state: &state
                )
                continue
            }
            guard let owner = lease.owner, let processSnapshot else {
                continue
            }
            guard let current = processSnapshot[owner.pid] else {
                removeLease(
                    key: key,
                    action: nil,
                    reason: "owner_exited",
                    timestamp: timestamp,
                    state: &state
                )
                continue
            }
            if current.started != owner.started {
                removeLease(
                    key: key,
                    action: nil,
                    reason: "owner_pid_reused",
                    timestamp: timestamp,
                    state: &state
                )
            }
        }

        if leaseCountBefore > 0, state.leases.isEmpty, state.shutdownNotBefore == nil {
            state.shutdownNotBefore = timestamp
        }

        let result: String
        if !state.leases.isEmpty {
            state.shutdownNotBefore = nil
            ensureAmphetamineActive(timestamp: timestamp, state: &state)
            result = "active_leases"
        } else if timestamp < (state.shutdownNotBefore ?? timestamp) {
            result = "shutdown_grace"
        } else {
            stopOwnedAmphetamineIfNeeded(timestamp: timestamp, state: &state)
            state.shutdownNotBefore = nil
            result = "no_active_leases"
        }

        queueHistory(
            HistoryEvent(
                timestamp: timestamp,
                type: "reconcile",
                leaseCountBefore: leaseCountBefore,
                leaseCountAfter: state.leases.count,
                amphetamineOwnedBefore: amphetamineOwnedBefore,
                amphetamineOwnedAfter: state.ownedSession != nil,
                result: result
            )
        )
    }

    private func ensureAmphetamineActive(
        timestamp: Double,
        state: inout ControllerState
    ) {
        if sessionMatchesOwnership(timestamp: timestamp, state: state) {
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_decision",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: true,
                    amphetamineOwnedAfter: true,
                    amphetamineActiveBefore: true,
                    amphetamineActiveAfter: true,
                    result: "owned_session_active"
                )
            )
            return
        }

        if state.ownedSession != nil {
            state.ownedSession = nil
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_ownership_cleared",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: true,
                    amphetamineOwnedAfter: false,
                    result: "cleared",
                    reason: "session_changed_externally"
                )
            )
        }

        if dryRun {
            if state.dryRunAmphetamineActive {
                queueHistory(
                    HistoryEvent(
                        timestamp: timestamp,
                        type: "amphetamine_decision",
                        leaseCountBefore: state.leases.count,
                        leaseCountAfter: state.leases.count,
                        amphetamineOwnedBefore: false,
                        amphetamineOwnedAfter: false,
                        amphetamineActiveBefore: true,
                        amphetamineActiveAfter: true,
                        result: "external_session_active"
                    )
                )
                return
            }
            state.dryRunAmphetamineActive = true
            state.ownedSession = OwnedSession(startedAt: timestamp)
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_started",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: false,
                    amphetamineOwnedAfter: true,
                    amphetamineActiveBefore: false,
                    amphetamineActiveAfter: true,
                    result: "started"
                )
            )
            return
        }

        if amphetamineIsActive() {
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_decision",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: false,
                    amphetamineOwnedAfter: false,
                    amphetamineActiveBefore: true,
                    amphetamineActiveAfter: true,
                    result: "external_session_active"
                )
            )
            return
        }

        do {
            try amphetamine(
                "start new session with options {duration:\(sessionMinutes), interval:minutes, displaySleepAllowed:true}"
            )
            try amphetamine("allow display sleep")
            try amphetamine("enable closed display mode")
            state.ownedSession = OwnedSession(startedAt: timestamp)
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_started",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: false,
                    amphetamineOwnedAfter: true,
                    amphetamineActiveBefore: false,
                    amphetamineActiveAfter: true,
                    result: "started"
                )
            )
        } catch {
            if amphetamineIsActive() {
                try? amphetamine("end session")
            }
            state.ownedSession = nil
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_error",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: false,
                    amphetamineOwnedAfter: false,
                    amphetamineActiveAfter: false,
                    result: "start_failed",
                    error: String(describing: error)
                )
            )
        }
    }

    private func stopOwnedAmphetamineIfNeeded(
        timestamp: Double,
        state: inout ControllerState
    ) {
        guard state.ownedSession != nil else {
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_decision",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: false,
                    amphetamineOwnedAfter: false,
                    result: "not_owned"
                )
            )
            return
        }

        if dryRun {
            if sessionMatchesOwnership(timestamp: timestamp, state: state) {
                state.dryRunAmphetamineActive = false
            }
            state.ownedSession = nil
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_stopped",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: true,
                    amphetamineOwnedAfter: false,
                    amphetamineActiveBefore: true,
                    amphetamineActiveAfter: false,
                    result: "stopped"
                )
            )
            return
        }

        if sessionMatchesOwnership(timestamp: timestamp, state: state) {
            do {
                try amphetamine("end session")
                queueHistory(
                    HistoryEvent(
                        timestamp: timestamp,
                        type: "amphetamine_stopped",
                        leaseCountBefore: state.leases.count,
                        leaseCountAfter: state.leases.count,
                        amphetamineOwnedBefore: true,
                        amphetamineOwnedAfter: false,
                        amphetamineActiveBefore: true,
                        amphetamineActiveAfter: false,
                        result: "stopped"
                    )
                )
            } catch {
                queueHistory(
                    HistoryEvent(
                        timestamp: timestamp,
                        type: "amphetamine_error",
                        leaseCountBefore: state.leases.count,
                        leaseCountAfter: state.leases.count,
                        amphetamineOwnedBefore: true,
                        amphetamineOwnedAfter: true,
                        amphetamineActiveBefore: true,
                        result: "stop_failed",
                        error: String(describing: error)
                    )
                )
                return
            }
        } else {
            queueHistory(
                HistoryEvent(
                    timestamp: timestamp,
                    type: "amphetamine_ownership_cleared",
                    leaseCountBefore: state.leases.count,
                    leaseCountAfter: state.leases.count,
                    amphetamineOwnedBefore: true,
                    amphetamineOwnedAfter: false,
                    result: "left_untouched",
                    reason: "session_changed_externally"
                )
            )
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
        if let fixturePath = environment["AGENT_AWAKE_TEST_PROCESS_SNAPSHOT"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)),
           let fixture = try? JSONDecoder().decode([ProcessRecord].self, from: data) {
            return Dictionary(uniqueKeysWithValues: fixture.map { ($0.pid, $0) })
        }
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

    private var historyFileBytes: Int {
        positiveEnvironmentInt(
            "AGENT_AWAKE_HISTORY_FILE_BYTES",
            default: defaultHistoryFileBytes
        )
    }

    private var historyArchives: Int {
        positiveEnvironmentInt(
            "AGENT_AWAKE_HISTORY_ARCHIVES",
            default: defaultHistoryArchives
        )
    }

    private var historyHourlyBytes: Int {
        positiveEnvironmentInt(
            "AGENT_AWAKE_HISTORY_HOURLY_BYTES",
            default: defaultHistoryHourlyBytes
        )
    }

    private var heartbeatSummarySeconds: Double {
        Double(
            positiveEnvironmentInt(
                "AGENT_AWAKE_HEARTBEAT_SUMMARY_SECONDS",
                default: defaultHeartbeatSummarySeconds
            )
        )
    }

    private func positiveEnvironmentInt(_ key: String, default defaultValue: Int) -> Int {
        guard let raw = environment[key],
              let value = Int(raw),
              value > 0
        else {
            return defaultValue
        }
        return value
    }

    private func queueHistory(_ event: HistoryEvent) {
        queuedHistoryEvents.append(event)
    }

    private func recordStandaloneHistory(_ event: HistoryEvent) {
        do {
            try withLockedState { _ in
                queueHistory(event)
            }
        } catch {
            fallbackLog("Structured history failed: \(error)")
        }
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

        queuedHistoryEvents.removeAll(keepingCapacity: true)
        var state = loadState()
        do {
            let result = try body(&state)
            let lines = try prepareHistoryLines(timestamp: now(), state: &state)
            try saveState(state)
            do {
                try appendHistoryLines(lines)
            } catch {
                fallbackLog("Structured history append failed: \(error)")
            }
            queuedHistoryEvents.removeAll(keepingCapacity: true)
            return result
        } catch {
            queuedHistoryEvents.removeAll(keepingCapacity: true)
            throw error
        }
    }

    private func withReadOnlyState<T>(
        _ body: (ControllerState) throws -> T
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
        return try body(loadState())
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

    private func prepareHistoryLines(
        timestamp: Double,
        state: inout ControllerState
    ) throws -> [Data] {
        let hourStart = floor(timestamp / 3_600) * 3_600
        var events = queuedHistoryEvents

        if state.historyHourStart != hourStart {
            let mustRecordResume = state.historyPausedUntil != nil
            state.historyHourStart = hourStart
            state.historyBytesThisHour = 0
            state.historyPausedUntil = nil
            if mustRecordResume {
                events.insert(
                    HistoryEvent(
                        timestamp: timestamp,
                        type: "history_resumed",
                        result: "hourly_budget_reset"
                    ),
                    at: 0
                )
            }
        }

        if let pausedUntil = state.historyPausedUntil,
           timestamp < pausedUntil {
            return []
        }

        var lines: [Data] = []
        for var event in events {
            event.sequence = state.historySequence + 1
            let line = try encodeHistoryLine(event)
            if state.historyBytesThisHour + line.count > historyHourlyBytes {
                var pauseEvent = HistoryEvent(
                    timestamp: timestamp,
                    type: "history_paused",
                    result: "hourly_byte_limit",
                    reason: "history writes reached the hourly limit"
                )
                pauseEvent.sequence = state.historySequence + 1
                let pauseLine = try encodeHistoryLine(pauseEvent)
                state.historySequence = pauseEvent.sequence
                state.historyBytesThisHour += pauseLine.count
                state.historyPausedUntil = hourStart + 3_600
                lines.append(pauseLine)
                break
            }
            state.historySequence = event.sequence
            state.historyBytesThisHour += line.count
            lines.append(line)
        }
        return lines
    }

    private func encodeHistoryLine(_ event: HistoryEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        return data
    }

    private func appendHistoryLines(_ lines: [Data]) throws {
        for line in lines {
            if historyFileSize(historyFile) + line.count > historyFileBytes {
                try rotateHistoryFiles()
            }
            if !fileManager.fileExists(atPath: historyFile.path) {
                guard fileManager.createFile(
                    atPath: historyFile.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw ControllerError.processFailed("could not create history file")
                }
            }
            chmod(historyFile.path, 0o600)
            let handle = try FileHandle(forWritingTo: historyFile)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
    }

    private func rotateHistoryFiles() throws {
        let oldest = historyArchive(historyArchives)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if historyArchives > 1 {
            for index in stride(from: historyArchives - 1, through: 1, by: -1) {
                let source = historyArchive(index)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try fileManager.moveItem(at: source, to: historyArchive(index + 1))
            }
        }
        if fileManager.fileExists(atPath: historyFile.path) {
            try fileManager.moveItem(at: historyFile, to: historyArchive(1))
        }
    }

    private func historyArchive(_ index: Int) -> URL {
        historyFile.appendingPathExtension(String(index))
    }

    private func historyFileSize(_ url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.intValue
    }

    private func retainedHistoryBytes() -> Int {
        var total = historyFileSize(historyFile)
        for index in 1...historyArchives {
            total += historyFileSize(historyArchive(index))
        }
        return total
    }

    private func fallbackLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        if !fileManager.fileExists(atPath: fallbackLogFile.path) {
            fileManager.createFile(
                atPath: fallbackLogFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: fallbackLogFile) else {
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
