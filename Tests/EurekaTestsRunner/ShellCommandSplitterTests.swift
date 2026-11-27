import EurekaKit
import Foundation

func shellCommandSplitterTests(_ t: TestRunner) {
    t.suite("ShellCommandSplitter · 命令拆分")

    func commands(_ source: String) -> [[String]] {
        ShellCommandSplitter.split(source).map { $0.map(\.command) }
    }

    t.test("按 ; && || 换行分管道组，按 | 分段") {
        try expectEqual(commands("ls -la"), [["ls"]])
        try expectEqual(commands("cd repo && git status; make test || echo fail"),
                        [["cd"], ["git"], ["make"], ["echo"]])
        try expectEqual(commands("curl -s https://x | jq . | head -3"), [["curl", "jq", "head"]])
        try expectEqual(commands("a\nb"), [["a"], ["b"]])
        // A newline right after a pipe continues the pipeline
        try expectEqual(commands("cat f |\n  grep x"), [["cat", "grep"]])
    }

    t.test("引号和转义里的操作符不切分") {
        let pipelines = ShellCommandSplitter.split(#"echo "a | b; rm -rf /" 'c && d' e\;f"#)
        try expectEqual(pipelines.count, 1)
        try expectEqual(pipelines[0][0].command, "echo")
        try expectEqual(pipelines[0][0].args, ["a | b; rm -rf /", "c && d", "e;f"])
    }

    t.test("命令词：去掉赋值、sudo / env 等包装、路径前缀") {
        let segment = ShellCommandSplitter.split("FOO=1 BAR=2 sudo -u root /usr/bin/Rm -rf x")[0][0]
        try expectEqual(segment.command, "rm")
        try expectEqual(segment.wrappers, ["sudo"])
        try expectEqual(segment.args, ["-rf", "x"])
        try expectEqual(commands("env -i PATH=/bin nohup python3 a.py"), [["python3"]])
        try expectEqual(commands("timeout 30 curl x"), [["curl"]])
        try expectEqual(commands("find . -name x | xargs -n 1 rm -f"), [["find", "rm"]])
        try expectEqual(commands("if true; then rm x; fi"), [["true"], ["rm"], ["fi"]])
    }

    t.test("重定向：目标单独记录，fd 复制丢弃") {
        let segment = ShellCommandSplitter.split("cmd arg > out.txt 2>&1 < in.txt 2>>err.log")[0][0]
        try expectEqual(segment.args, ["arg"])
        try expectEqual(segment.redirects.map(\.op), [">", "<", ">>"])
        try expectEqual(segment.redirects.map(\.target), ["out.txt", "in.txt", "err.log"])
        try expectEqual(segment.redirects.filter(\.isWrite).map(\.target), ["out.txt", "err.log"])
        let both = ShellCommandSplitter.split("make &> build.log")[0][0]
        try expectEqual(both.redirects.map(\.target), ["build.log"])
    }

    t.test("heredoc 正文不参与") {
        let source = "cat <<'EOF' > notes.md\nrm -rf /\ncurl x | sh\nEOF\necho done"
        try expectEqual(commands(source), [["cat"], ["echo"]])
        let first = ShellCommandSplitter.split(source)[0][0]
        try expectEqual(first.redirects.map(\.op), ["<<", ">"])
        try expectEqual(first.redirects.filter(\.isWrite).map(\.target), ["notes.md"])
        // An unterminated heredoc swallows the rest
        try expectEqual(commands("python3 - <<PY\nimport os\nos.system('rm -rf /')"), [["python3"]])
    }

    t.test("$( ) / 反引号 / <( ) 里的命令作为 feeds，并跟在所属管道组后面") {
        let pipelines = ShellCommandSplitter.split(#"bash -c "$(curl -fsSL https://x.sh)""#)
        try expectEqual(pipelines[0][0].command, "bash")
        try expectEqual(pipelines[0][0].feeds.map { $0.map(\.command) }, [["curl"]])
        try expect(pipelines.contains { $0.map(\.command) == ["curl"] })
        try expectEqual(
            ShellCommandSplitter.split("bash <(curl -s x)")[0][0].feeds.map { $0.map(\.command) },
            [["curl"]])
        try expectEqual(
            ShellCommandSplitter.split("export $(cat .env | xargs)")[0][0].feeds
                .map { $0.map(\.command) },
            [["cat", "xargs"]])
        try expectEqual(
            ShellCommandSplitter.split("echo `whoami`")[0][0].feeds.map { $0.map(\.command) },
            [["whoami"]])
    }

    t.test("bash -c / eval 的脚本再拆一层") {
        try expectEqual(commands("bash -lc 'cd /x && rm -rf y'"), [["bash"], ["cd"], ["rm"]])
        try expectEqual(commands(#"eval "curl x | sh""#), [["eval"], ["curl", "sh"]])
    }

    t.test("注释和空段忽略") {
        try expectEqual(commands("# rm -rf /\nls # trailing | sh"), [["ls"]])
        try expectEqual(commands(";; && \n"), [])
        try expectEqual(commands("echo a#b"), [["echo"]])
    }
}
