# Mock handshake-era server that exits (with a message on stderr) when the first request is not
# `initialize`. The probe must relaunch it once and go straight to the handshake.
IFS= read -r line
case "$line" in
  *'"method":"initialize"'*) ;;
  *) echo "fatal: expected initialize first" >&2; exit 1 ;;
esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"strict","version":"1"}}}'
while IFS= read -r line; do
  case "$line" in
    *'"method":"tools\/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"only"}]}}' ;;
  esac
done
