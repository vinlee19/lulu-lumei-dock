import Foundation

// eureka-relay：被 Claude Code hooks / Codex notify 调用的转发器。
// 硬约束：永远 exit 0；stdout 绝对静默（UserPromptSubmit 的 stdout 会注入模型上下文）；
// 全程 <50ms；stdin 限读 1MB。M1 实现三个子命令：claude-hook / codex-notify / inject。

exit(0)
