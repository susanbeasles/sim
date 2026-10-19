import XCTest
@testable import AgentCore

final class GuestAuditTests: XCTestCase {
    // Exercise the emitted scripts, with only Linux process/locking tools adapted
    // on macOS. These tests do not qualify PTY capture, isolation, or concurrency.
    private func fixture(_ body: (URL, [String: String]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let adapters = [
            "flock": "#!/bin/sh\nexit 0\n",
            "runuser": "#!/bin/sh\nshift 3\nexec \"$@\"\n",
            "script": "#!/bin/bash\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = -c ]; then exec /bin/bash -c \"$2\"; fi; shift; done\nexit 1\n",
        ]
        for (name, script) in adapters {
            let file = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for (name, script) in [("session", GuestBootstrap.sessionScript), ("verify", GuestBootstrap.verifyScript)] {
            let source = script.replacingOccurrences(of: "/var/lib/agent-audit", with: root.appendingPathComponent("audit").path)
            try Data(source.utf8).write(to: root.appendingPathComponent(name))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        try body(root, environment)
    }

    @discardableResult
    private func run(_ root: URL, _ environment: [String: String], _ name: String, _ args: [String] = []) throws -> ProcessResult {
        try ProcessRunner().capture("/bin/bash", [root.appendingPathComponent(name).path] + args, environment: environment)
    }

    func testFullAuditRefusesNamespaceFallbackBeforeVendorLaunch() throws {
        try fixture { root, env in
            let setpriv = root.appendingPathComponent("bin/setpriv")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: setpriv)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setpriv.path)
            let marker = root.appendingPathComponent("vendor-ran")
            let result = try run(root, env, "session", ["worker", "--require-full", "/usr/bin/touch", marker.path])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderrString.contains("full audit unavailable"), result.stderrString)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testFullVerificationRejectsCompletedFallbackSession() throws {
        try fixture { root, env in
            let setpriv = root.appendingPathComponent("bin/setpriv")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: setpriv)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setpriv.path)
            let zero = String(repeating: "0", count: 64)
            XCTAssertEqual(try run(root, env, "session", ["worker", "--session", "fallback", "0", zero, "/usr/bin/true"]).status, 0)
            let arguments = ["--session", "worker", "fallback", "0", zero]
            XCTAssertEqual(try run(root, env, "verify", arguments).status, 0)
            let verified = try run(root, env, "verify", ["--require-full"] + arguments)
            XCTAssertNotEqual(verified.status, 0)
            XCTAssertTrue(verified.stderrString.contains("requested full audit used fallback"), verified.stderrString)
        }
    }

    func testCompletedSessionVerifies() throws {
        try fixture { root, env in
            let session = try run(root, env, "session", ["worker", "/usr/bin/true"])
            XCTAssertEqual(session.status, 0, session.stderrString)
            let verified = try run(root, env, "verify")
            XCTAssertEqual(verified.status, 0, verified.stderrString)
        }
    }

    func testOrphanSessionInvalidatesPreviouslyValidHead() throws {
        try fixture { root, env in
            XCTAssertEqual(try run(root, env, "session", ["worker", "/usr/bin/true"]).status, 0)
            XCTAssertEqual(try run(root, env, "verify").status, 0)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("audit/sessions/worker/orphan"), withIntermediateDirectories: true)
            XCTAssertNotEqual(try run(root, env, "verify").status, 0)
        }
    }

    func testInterruptedSessionLeavesStartRecordAndFailsVerification() throws {
        try fixture { root, env in
            XCTAssertEqual(try run(root, env, "session", ["worker", "/usr/bin/true"]).status, 0)
            XCTAssertEqual(try run(root, env, "verify").status, 0)
            let result = try run(root, env, "session", ["worker", "/bin/bash", "-c", "kill -KILL $PPID"])
            XCTAssertNotEqual(result.status, 0)
            let chain = (try? String(contentsOf: root.appendingPathComponent("audit/chain.log"), encoding: .utf8)) ?? ""
            XCTAssertTrue(chain.contains("\tstart\n"), "launch must leave a chained start even if the supervisor is killed")
            XCTAssertNotEqual(try run(root, env, "verify").status, 0)
        }
    }

    func testFinalizationWriteFailureInvalidatesPreviousHead() throws {
        try fixture { root, env in
            XCTAssertEqual(try run(root, env, "session", ["worker", "/usr/bin/true"]).status, 0)
            let before = try run(root, env, "verify", ["--snapshot"]).stdoutString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            XCTAssertEqual(before.count, 2)
            let end = root.appendingPathComponent("audit/sessions/worker/failure/end")
            // In this local fault fixture the child collides with a finalization
            // file. This exercises the supervisor's actual failed-write path.
            let result = try run(root, env, "session", ["worker", "--session", "failure", before[0], before[1], "/bin/mkdir", end.path])
            XCTAssertNotEqual(result.status, 0)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: end.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue, "the child must execute before finalization fails")
            XCTAssertNotEqual(try run(root, env, "verify").status, 0)
        }
    }

    func testVerificationBindsSessionAndPriorHead() throws {
        try fixture { root, env in
            let zero = String(repeating: "0", count: 64)
            let result = try run(root, env, "session", ["worker", "--session", "bound", "0", zero, "/usr/bin/true"])
            XCTAssertEqual(result.status, 0, result.stderrString)
            let verified = try run(root, env, "verify", ["--session", "worker", "bound", "0", zero])
            XCTAssertEqual(verified.status, 0, verified.stderrString)
            XCTAssertTrue(verified.stdoutString.hasPrefix("2 "))
            XCTAssertNotEqual(try run(root, env, "verify", ["--session", "worker", "other", "0", zero]).status, 0)
            XCTAssertNotEqual(try run(root, env, "verify", ["--session", "worker", "bound", "1", zero]).status, 0)
            XCTAssertNotEqual(try run(root, env, "verify", ["--session", "worker", "bound", "0", String(repeating: "a", count: 64)]).status, 0)
        }
    }

    func testOnlyPristineLedgerAllowsEmptySnapshot() throws {
        try fixture { root, env in
            let audit = root.appendingPathComponent("audit")
            try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
            let snapshot = try run(root, env, "verify", ["--snapshot"])
            XCTAssertEqual(snapshot.status, 0, snapshot.stderrString)
            XCTAssertEqual(snapshot.stdoutString, "0 \(String(repeating: "0", count: 64))\n")
            try Data().write(to: audit.appendingPathComponent("chain.log"))
            XCTAssertNotEqual(try run(root, env, "verify", ["--snapshot"]).status, 0)
        }
    }

    func testDuplicateOrMalformedChainEntriesFail() throws {
        try fixture { root, env in
            XCTAssertEqual(try run(root, env, "session", ["worker", "/usr/bin/true"]).status, 0)
            let file = root.appendingPathComponent("audit/chain.log")
            let chain = try String(contentsOf: file, encoding: .utf8)
            let first = String(chain.split(separator: "\n")[0])
            for suffix in [first + "\n", "malformed\n", "3\t\(String(repeating: "a", count: 64))\t../../escape\tcomplete\n", "\n"] {
                try Data((chain + suffix).utf8).write(to: file)
                XCTAssertNotEqual(try run(root, env, "verify").status, 0)
            }
        }
    }

    func testLegacyCompletedLedgerCanBeExtended() throws {
        for legacyWorker in ["worker", "_worker", "review worker"] {
        try fixture { root, env in
            // Hand-written v1 fixture: three columns and no phase in the digest.
            let legacy = #"""
            set -euo pipefail
            ROOT=$1
            DIR="$ROOT/sessions/worker/legacy"
            mkdir -p "$DIR"
            printf 'started\n' > "$DIR/start"
            printf 'ended\n' > "$DIR/end"
            printf '0\n' > "$DIR/exit-code"
            (cd "$DIR"; sha256sum start end exit-code > manifest.sha256)
            {
              printf 'sequence=1\nprevious=%064d\nworker=worker\nsession=legacy\n' 0
              cat "$DIR/manifest.sha256"
            } > "$DIR/chain.input"
            HEAD=$(sha256sum "$DIR/chain.input" | awk '{print $1}')
            printf '%s\n' "$HEAD" > "$DIR/HEAD"
            printf '%s\n' "$HEAD" > "$ROOT/HEAD"
            printf '1\n' > "$ROOT/sequence"
            printf '1\t%s\tsessions/worker/legacy\n' "$HEAD" > "$ROOT/chain.log"
            """#
            let source = legacy.replacingOccurrences(of: "/worker/", with: "/" + legacyWorker + "/")
                .replacingOccurrences(of: "worker=worker", with: "worker=" + legacyWorker)
            try Data(source.utf8).write(to: root.appendingPathComponent("legacy"))
            XCTAssertEqual(try run(root, env, "legacy", [root.appendingPathComponent("audit").path]).status, 0)
            let before = try run(root, env, "verify", ["--snapshot"])
            XCTAssertEqual(before.status, 0, before.stderrString)
            let fields = before.stdoutString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            XCTAssertEqual(fields.count, 2)
            XCTAssertEqual(try run(root, env, "session", ["worker", "--session", "modern", fields[0], fields[1], "/usr/bin/true"]).status, 0)
            let after = try run(root, env, "verify", ["--session", "worker", "modern", fields[0], fields[1]])
            XCTAssertEqual(after.status, 0, after.stderrString)
            XCTAssertTrue(after.stdoutString.hasPrefix("3 "))
        }
        }
    }
}
