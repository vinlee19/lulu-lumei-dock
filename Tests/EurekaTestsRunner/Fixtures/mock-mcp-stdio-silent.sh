# Mock handshake-era server that stays silent on anything before `initialize` (legal: the spec
# says such servers answer unknown pre-initialize requests "or not at all"), and whose tools/list
# fails. Covers the discover-timeout fallback and the "connected but no tool list" case.
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"silent","version":"0.0.1"}}}' ;;
    *'"method":"tools\/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"backend unavailable"}}' ;;
  esac
done
