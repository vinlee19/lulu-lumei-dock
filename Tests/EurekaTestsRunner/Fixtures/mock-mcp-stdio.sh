# Mock MCP stdio server (for tests, launched via /bin/sh - bundle resources don't keep the exec bit).
# Replies in MCPStdioProbe's request order: initialize(id1) → initialized notification (no reply)
# → tools/list(id2) → prompts/list(id4) → resources/list(id3).
read line1
echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"prompts":{},"resources":{}},"serverInfo":{"name":"mock","version":"0.1"}}}'
read line2
read line3
echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"回显输入文本","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}'
read line4
echo '{"jsonrpc":"2.0","id":4,"result":{"prompts":[{"name":"review","description":"评审提示"}]}}'
read line5
echo '{"jsonrpc":"2.0","id":3,"result":{"resources":[{"name":"readme"}]}}'
