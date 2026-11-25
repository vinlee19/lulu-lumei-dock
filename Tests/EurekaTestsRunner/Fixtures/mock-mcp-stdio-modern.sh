# Mock modern (2026-07-28, stateless) MCP stdio server: no handshake. `server/discover` returns a
# DiscoverResult; `initialize` is rejected naming the supported versions; a list request without
# the per-request `_meta` is malformed (-32602), exactly as the spec requires.
while IFS= read -r line; do
  case "$line" in
    *'"method":"server\/discover"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":10,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol\/serverInfo":{"name":"modern-mock","version":"2.0"}},"instructions":"Weather utilities.","ttlMs":3600000,"cacheScope":"public"}}' ;;
    *'"method":"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"initialize is not supported","data":{"supported":["2026-07-28"]}}}' ;;
    *'"method":"tools\/list"'*)
      case "$line" in
        *'io.modelcontextprotocol\/protocolVersion":"2026-07-28"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"get_weather","title":"Weather","description":"Current weather","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],"ttlMs":300000,"cacheScope":"public"}}' ;;
        *)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"missing _meta"}}' ;;
      esac ;;
  esac
done
