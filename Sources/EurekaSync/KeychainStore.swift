import Foundation

/// Stores AK/SK in the macOS keychain, read and written through the /usr/bin/security subprocess.
/// A subprocess instead of Security.framework for the same reason as the Claude OAuth read:
/// security is an Apple-signed principal, so once the user clicks "Always Allow" it survives
/// ad-hoc re-signing of the app;
/// direct SecItem* ACLs re-prompt after every re-sign.
/// Every call blocks (waitUntilExit) and must only run on a background queue.
public enum KeychainStore {
    public static let service = "com.vinlee.eureka.cos"
    public static let secretIdAccount = "secret-id"
    public static let secretKeyAccount = "secret-key"

    /// Read: find-generic-password -w (the secret comes back via stdout, never via argv).
    /// service is configurable (COS by default; MCP OAuth uses "com.vinlee.eureka.mcp")
    public static func read(account: String, service: String = KeychainStore.service) -> String? {
        let output = run(arguments: [
            "find-generic-password", "-s", service, "-a", account, "-w",
        ])
        guard let output, !output.isEmpty else { return nil }
        return output
    }

    /// Write: security -i interactive mode; the command and the secret are fed via stdin (never
    /// argv, so ps can't see them).
    /// -U updates an existing item; on some systems the -U update fails → fall back to delete then
    /// add.
    @discardableResult
    public static func write(
        account: String, secret: String, service: String = KeychainStore.service
    ) -> Bool {
        if writeViaStdin(account: account, secret: secret, service: service) {
            return true
        }
        delete(account: account, service: service)
        return writeViaStdin(account: account, secret: secret, service: service)
    }

    @discardableResult
    public static func delete(account: String, service: String = KeychainStore.service) -> Bool {
        run(arguments: ["delete-generic-password", "-s", service, "-a", account]) != nil
    }

    // MARK: - Internal

    private static func writeViaStdin(
        account: String, secret: String, service: String = KeychainStore.service
    ) -> Bool {
        // security's interactive parser supports double quotes + backslash escapes
        let escaped = secret
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(escaped)\"\n"
        return run(arguments: ["-i"], stdin: command) != nil
    }

    /// Runs /usr/bin/security; exit 0 → returns stdout (trimmed), otherwise nil
    private static func run(arguments: [String], stdin: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        if let stdin {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            do {
                try process.run()
            } catch {
                return nil
            }
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inputPipe.fileHandleForWriting.closeFile()
        } else {
            do {
                try process.run()
            } catch {
                return nil
            }
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
