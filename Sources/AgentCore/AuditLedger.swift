import Foundation

public struct AuditEvent: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var timestamp: Date
    public var workspace: String?
    public var worker: String?
    public var kind: String
    public var direction: String?
    public var detail: String
    public var payloadSHA256: String?
    public var previous: String
    public var digest: String
}

private struct AuditCanonical: Codable {
    var sequence: UInt64
    var timestamp: Date
    var workspace: String?
    var worker: String?
    var kind: String
    var direction: String?
    var detail: String
    var payloadSHA256: String?
    var previous: String
}

public actor AuditLedger {
    private let file: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(file: URL) {
        self.file = file
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(
        workspace: String? = nil,
        worker: String? = nil,
        kind: String,
        direction: String? = nil,
        detail: String,
        payload: Data? = nil
    ) throws -> AuditEvent {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o750]
        )

        let existing = try loadAll()
        let previous = existing.last?.digest ?? String(repeating: "0", count: 64)
        let canonical = AuditCanonical(
            sequence: UInt64(existing.count + 1),
            timestamp: Date(),
            workspace: workspace,
            worker: worker,
            kind: kind,
            direction: direction,
            detail: detail,
            payloadSHA256: payload.map(Digest.sha256),
            previous: previous
        )
        let canonicalData = try encoder.encode(canonical)
        let event = AuditEvent(
            sequence: canonical.sequence,
            timestamp: canonical.timestamp,
            workspace: canonical.workspace,
            worker: canonical.worker,
            kind: canonical.kind,
            direction: canonical.direction,
            detail: canonical.detail,
            payloadSHA256: canonical.payloadSHA256,
            previous: canonical.previous,
            digest: Digest.sha256(canonicalData)
        )
        let line = try encoder.encode(event) + Data([0x0A])

        if !FileManager.default.fileExists(atPath: file.path) {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        try handle.close()
        return event
    }

    public func loadAll() throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        return try data.split(separator: 0x0A).filter { !$0.isEmpty }.map { try decoder.decode(AuditEvent.self, from: Data($0)) }
    }

    @discardableResult
    public func verify() throws -> AuditEvent? {
        let events = try loadAll()
        var previous = String(repeating: "0", count: 64)
        for (index, event) in events.enumerated() {
            guard event.sequence == UInt64(index + 1) else {
                throw AgentError.malformed("audit sequence break at event \(event.sequence)")
            }
            guard event.previous == previous else {
                throw AgentError.malformed("audit previous-digest break at event \(event.sequence)")
            }
            let canonical = AuditCanonical(
                sequence: event.sequence,
                timestamp: event.timestamp,
                workspace: event.workspace,
                worker: event.worker,
                kind: event.kind,
                direction: event.direction,
                detail: event.detail,
                payloadSHA256: event.payloadSHA256,
                previous: event.previous
            )
            let expected = Digest.sha256(try encoder.encode(canonical))
            guard expected == event.digest else {
                throw AgentError.malformed("audit digest mismatch at event \(event.sequence)")
            }
            previous = event.digest
        }
        return events.last
    }
}
