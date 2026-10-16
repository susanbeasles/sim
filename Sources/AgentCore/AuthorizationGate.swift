import Foundation

public struct AuthorizationGate: Sendable {
    public let runner: ProcessRunning
    public let configuration: AgentConfiguration

    public init(runner: ProcessRunning = ProcessRunner(), configuration: AgentConfiguration) {
        self.runner = runner
        self.configuration = configuration
    }

    public func authorize(operation: String, manifest: String) throws {
        _ = try sign(operation: operation, manifest: manifest)
    }

    public func sign(operation: String, manifest: String) throws -> Data {
        let material = try signingMaterial()
        try requirePinnedFingerprint(material.fingerprint)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }

        let manifestURL = temp.appendingPathComponent("manifest")
        try Data(manifest.utf8).write(to: manifestURL, options: .atomic)

        print("\nAuthorization required: \(operation)")
        print("Touch YubiKey to authorize this exact transaction…")
        _ = try runner.checked("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", material.privateOrResidentPath, "-n", "agent-control", manifestURL.path])

        let sigURL = URL(fileURLWithPath: manifestURL.path + ".sig")
        guard FileManager.default.fileExists(atPath: sigURL.path) else {
            throw AgentError.authorizationRequired("ssh-keygen did not produce a signature")
        }
        let signature = try Data(contentsOf: sigURL)
        try verify(manifest: manifest, signature: signature)
        return signature
    }

    public func verify(manifest: String, signature: Data) throws {
        let material = try signingMaterial()
        try requirePinnedFingerprint(material.fingerprint)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }

        let allowed = temp.appendingPathComponent("allowed_signers")
        let sig = temp.appendingPathComponent("manifest.sig")
        try Data("\(configuration.authorizationIdentity) \(material.publicLine)\n".utf8).write(to: allowed, options: .atomic)
        try signature.write(to: sig, options: .atomic)

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        verify.arguments = ["-Y", "verify", "-f", allowed.path, "-I", configuration.authorizationIdentity, "-n", "agent-control", "-s", sig.path]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        verify.standardInput = input
        verify.standardOutput = output
        verify.standardError = error
        try verify.run()
        try input.fileHandleForWriting.write(contentsOf: Data(manifest.utf8))
        try input.fileHandleForWriting.close()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw AgentError.trustFailure("transaction signature verification failed: \(String(decoding: stderr, as: UTF8.self))")
        }
    }

    public func configuredFingerprint() throws -> String {
        try signingMaterial().fingerprint
    }

    private struct SigningMaterial {
        let privateOrResidentPath: String
        let publicLine: String
        let fingerprint: String
    }

    private func signingMaterial() throws -> SigningMaterial {
        guard let configured = configuration.authorizationKey, !configured.isEmpty else {
            throw AgentError.authorizationRequired("YubiKey authorization key is not configured; run: agent config auth-key ~/.ssh/id_yubikey")
        }
        let key = NSString(string: configured).expandingTildeInPath
        let pub = key.hasSuffix(".pub") ? key : key + ".pub"
        let signer = key.hasSuffix(".pub") ? String(key.dropLast(4)) : key
        guard FileManager.default.fileExists(atPath: signer) || FileManager.default.fileExists(atPath: pub) else {
            throw AgentError.authorizationRequired("authorization key not found: \(key)")
        }
        guard FileManager.default.fileExists(atPath: pub) else {
            throw AgentError.authorizationRequired("authorization public key not found: \(pub)")
        }
        let publicLine = try String(contentsOfFile: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let algorithm = publicLine.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let hardwareAlgorithms: Set<String> = [
            "sk-ssh-ed25519@openssh.com",
            "sk-ecdsa-sha2-nistp256@openssh.com",
        ]
        guard hardwareAlgorithms.contains(algorithm) else {
            throw AgentError.authorizationRequired("authorization key must be an OpenSSH FIDO/security-key credential (sk-*); software private keys are not accepted")
        }
        let fingerprint = try Self.sshFingerprint(publicKeyPath: pub, runner: runner)
        return SigningMaterial(privateOrResidentPath: signer, publicLine: publicLine, fingerprint: fingerprint)
    }

    private func requirePinnedFingerprint(_ actual: String) throws {
        if BuildIdentity.releaseBuild {
            guard BuildIdentity.expectedAuthorizationKeySHA256 != "DEBUG", !BuildIdentity.expectedAuthorizationKeySHA256.isEmpty else {
                throw AgentError.trustFailure("release build has no pinned YubiKey authorization fingerprint")
            }
            guard Self.normalizeSSHFingerprint(actual) == Self.normalizeSSHFingerprint(BuildIdentity.expectedAuthorizationKeySHA256) else {
                throw AgentError.trustFailure("configured authorization key does not match the YubiKey fingerprint pinned into this signed agent build")
            }
        }
    }

    public static func sshFingerprint(publicKeyPath: String, runner: ProcessRunning = ProcessRunner()) throws -> String {
        let result = try runner.checked("/usr/bin/ssh-keygen", ["-lf", publicKeyPath, "-E", "sha256"])
        let fields = result.stdoutString.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { throw AgentError.malformed("could not parse ssh-keygen fingerprint output") }
        return String(fields[1])
    }

    public static func normalizeSSHFingerprint(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "SHA256:", with: "", options: [.caseInsensitive])
    }
}
