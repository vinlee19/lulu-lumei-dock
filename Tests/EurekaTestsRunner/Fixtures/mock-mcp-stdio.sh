# Mock handshake-era MCP stdio server (for tests, launched via /bin/sh - bundle resources don't
# keep the exec bit). Speaks 2025-11-25: answers `initialize`, rejects the modern
# `server/discover` probe as an unknown method, then serves the three lists.
# JSONSerialization escapes "/" in method names, hence the "\/" in the patterns.
while IFS= read -r line; do
  case "$line" in
    *'"method":"server\/discover"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":10,"error":{"code":-32601,"message":"Method not found"}}' ;;
    *'"method":"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"prompts":{},"resources":{}},"serverInfo":{"name":"mock","title":"Mock Server","version":"0.1"},"instructions":"# Mock\nEchoes text back."}}' ;;
    *'"method":"tools\/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"回显输入文本","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"要回显的文本"}},"required":["text"]}}]}}' ;;
    *'"method":"prompts\/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"prompts":[{"name":"review","description":"评审提示"}]}}' ;;
    *'"method":"resources\/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"resources":[{"name":"readme"}]}}' ;;
  esac
done
