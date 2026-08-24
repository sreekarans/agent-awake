import CryptoKit
import Darwin
import Foundation

let sessionMinutes = 9_999
let sessionSeconds = Double(sessionMinutes * 60)
let sessionToleranceSeconds = 180
let historySchemaVersion = 1
let defaultHistoryFileBytes = 10 * 1_024 * 1_024
let defaultHistoryArchives = 4
let defaultHistoryHourlyBytes = 10 * 1_024 * 1_024
let defaultHeartbeatSummarySeconds = 5 * 60

struct Owner: Codable {
    var pid: Int32
    var started: String
}

struct Lease: Codable {
    var source: String
    var sessionHash: String
    var turnHash: String?
    var createdAt: Double
    var refreshedAt: Double
    var expiresAt: Double
    var owner: Owner?
}

struct OwnedSession: Codable {
    var startedAt: Double
}

struct PendingHeartbeat: Codable {
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

struct ControllerState: Codable {
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

struct HistoryEvent: Codable {
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

struct HistoryOutputRecord {
    var raw: String
    var values: [String: Any]
}

struct ProcessRecord: Codable {
    var pid: Int32
    var parentPID: Int32
    var started: String
    var command: String
}

struct HookPayload {
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

enum HookAction: String {
    case start
    case heartbeat
    case stop
    case stopSession = "stop-session"
}

enum Source: String {
    case codex
    case cursor
    case claude
}

enum ControllerError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidHistoryArguments(String)
    case invalidPayload(String)
    case missingIdentity(String)
    case processFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "invalid arguments"
        case let .invalidHistoryArguments(message):
            return message
        case let .invalidPayload(message):
            return message
        case let .missingIdentity(source):
            return "missing session identity for \(source)"
        case let .processFailed(message):
            return message
        }
    }
}
