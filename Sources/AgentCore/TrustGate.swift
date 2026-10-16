import Foundation

public enum TrustGate {
    public static func requireValidSelf() throws {
        #if os(macOS)
        guard BuildIdentity.releaseBuild else { return }
        guard BuildIdentity.expectedTeamID != "DEBUG", !BuildIdentity.expectedTeamID.isEmpty else {
            throw AgentError.trustFailure("release build has no pinned Team ID")
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
        guard let app = enclosingApp(for: executable) else {
            throw AgentError.trustFailure("agent must execute from its sealed Agent.app bundle")
        }

        let req = "anchor apple generic and identifier \"\(BuildIdentity.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(BuildIdentity.expectedTeamID)\""
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

    #if os(macOS)
    private static func enclosingApp(for executable: URL) -> URL? {
        var cursor = executable.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
    #endif
}
