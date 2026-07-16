import Foundation

/// AK/SK 存 macOS 钥匙串，经 /usr/bin/security 子进程读写。
/// 用子进程而非 Security.framework 的原因与 Claude OAuth 读取相同：
/// security 是 Apple 签名主体，用户点过「始终允许」后 ad-hoc 重签 app 也不会失效；
/// 直接 SecItem* 的 ACL 会在每次重签后重新弹窗。
/// 所有调用均阻塞（waitUntilExit），只应在后台队列上执行。
public enum KeychainStore {
    public static let service = "com.vinlee.eureka.cos"
    public static let secretIdAccount = "secret-id"
    public static let secretKeyAccount = "secret-key"

    /// 读：find-generic-password -w（密钥经 stdout 返回，不进 argv）
    public static func read(account: String) -> String? {
        let output = run(arguments: [
            "find-generic-password", "-s", service, "-a", account, "-w",
        ])
        guard let output, !output.isEmpty else { return nil }
        return output
    }

    /// 写：security -i 交互模式，命令连同密钥经 stdin 喂入（不进 argv，防 ps 窥见）。
    /// -U 更新已有项；部分系统 -U 更新失败 → 先 delete 再 add 兜底。
    @discardableResult
    public static func write(account: String, secret: String) -> Bool {
        if writeViaStdin(account: account, secret: secret) {
            return true
        }
        delete(account: account)
        return writeViaStdin(account: account, secret: secret)
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        run(arguments: ["delete-generic-password", "-s", service, "-a", account]) != nil
    }

    // MARK: - 内部

    private static func writeViaStdin(account: String, secret: String) -> Bool {
        // security 交互解析器支持双引号 + 反斜杠转义
        let escaped = secret
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(escaped)\"\n"
        return run(arguments: ["-i"], stdin: command) != nil
    }

    /// 跑 /usr/bin/security；exit 0 → 返回 stdout（trim），否则 nil
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
