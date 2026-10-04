import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct AgentMain {
    static func main() async {
        do {
            try TrustGate.requireValidSelf()
            let code = try await AgentCLI.run(Array(CommandLine.arguments.dropFirst()))
            exit(code)
        } catch {
            FileHandle.standardError.write(Data("agent: \(error)\n".utf8))
            exit(64)
        }
    }
}
