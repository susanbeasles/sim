import Foundation
import AgentCore

enum FleetCLI {
    static func run(_ arguments: [String]) async throws -> Int32 {
        if arguments.first == "sign" {
            let parsed = try SimpleParser.parse(Array(arguments.dropFirst()), valueOptions: ["--manifest", "--out"])
            guard let input = parsed.one("--manifest"), let output = parsed.one("--out") else {
                throw CLIError.usage("sim fleet sign --manifest FILE --out SIGNATURE")
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: input))
            guard bytes.count <= 1_048_576,
                  let manifest = String(data: bytes, encoding: .utf8),
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object["schema"] as? Int == 1 else {
                throw CLIError.usage("fleet manifest must be a version 1 JSON object under 1 MiB")
            }
            let store = try StateStore(paths: AgentPaths())
            let configuration = try await store.loadConfiguration()
            let signature = try AuthorizationGate(configuration: configuration).sign(operation: "remote fleet transaction", manifest: manifest)
            try signature.write(to: URL(fileURLWithPath: output), options: .atomic)
            return 0
        }
        if arguments.first == "unwrap-key" {
            let parsed = try SimpleParser.parse(Array(arguments.dropFirst()), valueOptions: ["--wrapped", "--certificate"])
            guard let wrapped = parsed.one("--wrapped"), let certificate = parsed.one("--certificate"),
                  let data = Data(base64Encoded: wrapped), data.count <= 1024 else {
                throw CLIError.usage("sim fleet unwrap-key --wrapped BASE64 --certificate SHA256")
            }
            let store = try StateStore(paths: AgentPaths())
            let configuration = try await store.loadConfiguration()
            guard let pinned = configuration.pivCertificateSHA256,
                  HardwareVaultCrypto.normalizeFingerprint(pinned) == HardwareVaultCrypto.normalizeFingerprint(certificate) else {
                throw CLIError.usage("fleet key recipient must match the configured hardware PIV identity")
            }
            let key = try HardwareVaultCrypto().unwrapDataKey(wrapped: data, recipientCertificateSHA256: certificate)
            // This pipe is consumed by the local fleet client; never send the
            // PIV private key or hardware device to a remote host.
            FileHandle.standardOutput.write(Data((key.base64EncodedString() + "\n").utf8))
            return 0
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let entry: URL
        if BuildIdentity.releaseBuild {
            entry = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/fleet/bin/sim-fleet.mjs")
        } else {
            entry = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fleet/bin/sim-fleet.mjs")
        }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw CLIError.usage("fleet client is missing from the verified installation")
        }
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CLIError.usage("install Node 24 LTS in /usr/local/bin or /opt/homebrew/bin")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [entry.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        environment["SIM_FLEET_SIGNER"] = executable.path
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
