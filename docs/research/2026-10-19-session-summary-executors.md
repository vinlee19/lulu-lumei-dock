# Session summary executors: verified CLI contracts

Date: 2026-10-19 · Issue #12 · Machine: macOS 26.6 (arm64)

Everything below was observed with real, deliberately tiny runs ("Reply with the word OK"),
plus one ~89 KB stdin run per streaming CLI and one cancellation probe. Help text alone was not
trusted; every flag listed here was exercised. Credential files were never read; only CLI
behaviour and the session stores the CLIs write were observed.

| CLI | Version | Path (login-shell `command -v`) | Binary |
|---|---|---|---|
| Claude Code | 2.1.303 | `~/.local/bin/claude` | native Mach-O |
| Codex CLI | 0.162.1 | `/opt/homebrew/bin/codex` | native Mach-O |
| OpenCode | 1.18.35 | `/opt/homebrew/bin/opencode` | native Mach-O |

A GUI app does not inherit the login PATH, so the app resolves each executable once with
`/bin/zsh -lc 'command -v <name>'` (the name is a constant, never user input) and captures the
login shell's `PATH` for the child environment. The process itself is then started with
`posix_spawn` (executable path + argument array, no shell), in its own process group.

## Claude Code

```
claude -p --output-format stream-json --verbose --include-partial-messages \
  --no-session-persistence --tools "" --strict-mcp-config --disable-slash-commands \
  --settings '{"disableAllHooks":true}'
env: CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
stdin: the whole prompt
```

- **Input:** with `-p` and no prompt argument the prompt is read from stdin. An 89 KB prompt
  (3000 numbered lines) was answered correctly (needle on line 2999), so stdin delivery is
  complete.
- **Events (JSONL on stdout):** `system/init` (`session_id`, `model`, `tools: []`,
  `mcp_servers: []`), `system/status`, `stream_event` wrapping the Anthropic stream
  (`content_block_delta` with `delta.type == "text_delta"` carries incremental text; only with
  `--include-partial-messages`), `assistant` (complete message, `message.model`), a
  `rate_limit_event`, and finally `result` with `subtype`, `is_error`, `result` (final text),
  `usage`, `modelUsage` (per-model tokens and cost), `api_error_status`, `terminal_reason`.
- **Errors:** an unknown model produced `result.subtype == "success"` **and**
  `is_error == true`, `api_error_status: 404`, `terminal_reason: "api_error"`, an `assistant`
  message whose model is `<synthetic>`, and exit code 1. Success therefore requires exit 0,
  a `result` event, `is_error == false` and non-empty text — `subtype` alone is not enough.
- **Isolation:** `--tools ""` leaves zero tools; `--strict-mcp-config` with no `--mcp-config`
  leaves zero MCP servers; `disableAllHooks` stops the user's hooks (including Eureka's own
  relay — the spool stayed empty during every run). Plugins still load but cannot run hooks or
  tools.
- **Persistence:** `--no-session-persistence` writes no transcript. Without
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` an empty `~/.claude/projects/<encoded cwd>/memory/`
  directory was still created; with it nothing is written under `~/.claude/projects`.
- **Cancellation:** `SIGTERM` to the process group ended the run promptly with exit status 0
  and a truncated stream (no `result`), and no process of the group survived. Exit status is
  therefore meaningless after a cancel; the service records "cancelled" from its own state.
- **Usage:** reported in `result.usage` / `modelUsage`. Because nothing is persisted, these
  tokens never reach Eureka's ledger (no double counting); they are stored on the summary run.

## Codex CLI

```
codex exec --json --ephemeral --skip-git-repo-check --sandbox read-only --cd <workdir> \
  --disable hooks --disable plugins --disable memories --disable apps \
  --disable multi_agent --disable shell_tool --disable image_generation \
  -c notify=[] -c mcp_servers.<name>.enabled=false (one per configured server) -
stdin: the whole prompt ("-" = read instructions from stdin)
```

- **Input:** `-` reads the prompt from stdin; the 89 KB needle test passed.
- **Events:** `thread.started` (`thread_id`), `turn.started`,
  `item.completed` with `item.type == "agent_message"` (complete text, no token deltas),
  `turn.completed` (`usage.input_tokens`, `cached_input_tokens`, `output_tokens`,
  `reasoning_output_tokens`). The model name is not reported.
- **Errors:** a top-level `error` event and `turn.failed.error.message` (the message is itself
  a JSON string with a nested `error.message`), exit code 1. `item.completed` with
  `item.type == "error"` is a non-fatal warning (e.g. unknown model metadata).
- **Isolation:** `--disable hooks` keeps Codex hooks (Eureka's relay is installed in
  `~/.codex/hooks.json`) from firing; `-c notify=[]` empties the single notify slot.
  `-c mcp_servers={}` does **not** clear configured servers (the override merges); each
  server has to be disabled by name. Names come from the existing `MCPConfigIndexer`, which
  reads only section headers. With them disabled stderr was empty; without, it carried
  OAuth refresh errors and resource URLs, which is why diagnostics are redacted and bounded.
- **Persistence:** `--ephemeral` wrote no rollout under `~/.codex/sessions`.
- **Streaming:** none — the UI shows "waiting for response" with elapsed time and the last
  event time instead of inventing progress.

## OpenCode

```
opencode run --format json --pure --dir <workdir> [-m provider/model]
stdin: the whole prompt (no positional message)
```

- **Events:** `step_start`, `text` (a complete text part: `part.id`, `part.text`), `tool_use`
  when tools run, `step_finish` (`part.tokens`, `part.cost`, `part.reason`), and `error`
  (`error.name`, `error.data.message`). No token deltas.
- **Errors:** this machine's configured default model (`coding-plan/glm-5.2`) no longer
  exists; the run exits 1 with `error.data.message == "Model not found: …"`, which the app
  surfaces verbatim (bounded). With `-m coding-plan/ark-code-latest` the run succeeded. A
  per-executor model override is therefore part of the MVP.
- **`--pure`** (no external plugins) worked and avoids third-party plugin side effects; the
  provider configuration is still loaded.
- **Persistence:** OpenCode has **no ephemeral mode**. Each run creates a top-level session in
  `opencode.db` whose `directory` is the `--dir` value. The app therefore runs every summary
  in the app-managed directory `~/Library/Application Support/Eureka/summaries/<runId>/` and
  excludes sessions in that tree from the session browser, prompt extraction, project-root
  discovery and live island events. Usage stays accurate through the single existing path:
  the OpenCode usage scanner still counts those tokens once, and the adapter's own token
  report is stored on the run only.
- **Tool restriction:** there is no flag to turn tools off; an inline
  `OPENCODE_CONFIG_CONTENT` denying permissions made the server fail ("Unexpected server
  error"), so it is not used. The prompt states that the transcript is the only input, and the
  run's working directory is an empty app-owned folder.

## Decisions

- Availability = binary resolved through the login shell **and** the flags the adapter needs
  are present in its `--help`. Authentication cannot be verified without a model call, so an
  auth failure is classified at run time from the CLI's own error text (exit status, result
  error, "login"/"401"/"unauthorized") and shown with a recovery hint.
- Success = clean exit, the adapter's terminal success event, and non-empty output. Partial
  output from a failed or cancelled run is kept as a draft and never replaces the last
  successful summary.
- Diagnostics (stderr tail) are bounded to 8 KB, redacted with `AuditRedactor`, and never
  become summary content.
- Cancellation sends `SIGTERM` to the process group, then `SIGKILL` after a grace period.
- Trae (encrypted DB) and Antigravity (protobuf) have no readable bodies and are disabled with
  an explanation.
