import Foundation
#if os(macOS)
import Security
#endif

public enum TrustGate {
    public static func requireValidSelf() throws {
        #if os(macOS)
        guard BuildIdentity.releaseBuild else { return }
        guard BuildIdentity.expectedTeamID != "DEBUG", !BuildIdentity.expectedTeamID.isEmpty else {
            throw AgentError.trustFailure("release build has no pinned Team ID")
        }

        // Bind trust to the running code object, never launcher-controlled argv[0].
        let flags = SecCSFlags(rawValue: 0)
        var code: SecCode?
        guard SecCodeCopySelf(flags, &code) == errSecSuccess, let code else {
            throw AgentError.trustFailure("cannot identify running agent code")
        }
        let req = "anchor apple generic and identifier \"\(BuildIdentity.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(BuildIdentity.expectedTeamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, flags, &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AgentError.trustFailure("running agent signature/identity verification failed")
        }

        var diskCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(code, flags, &diskCode) == errSecSuccess, let diskCode,
              SecCodeCopyPath(diskCode, flags, &path) == errSecSuccess, let path else {
            throw AgentError.trustFailure("cannot locate running agent bundle")
        }
        let app = (path as URL).resolvingSymlinksInPath().standardizedFileURL
        guard app.pathExtension == "app" else {
            throw AgentError.trustFailure("agent must execute from its sealed Agent.app bundle")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", "--verbose=2", "-R", "=\(req)", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AgentError.trustFailure("agent signature/seal/identity verification failed")
        }
        #endif
    }
}
