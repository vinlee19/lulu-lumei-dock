# Mock MCP stdio server（测试用，经 /bin/sh 调起——Bundle 资源不保执行位）。
# 按 MCPStdioProbe 的请求顺序应答：initialize(id1) → initialized 通知（不应答）
# → tools/list(id2) → prompts/list(id4) → resources/list(id3)。
read line1
echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"prompts":{},"resources":{}},"serverInfo":{"name":"mock","version":"0.1"}}}'
read line2
read line3
echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"回显输入文本","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}'
read line4
echo '{"jsonrpc":"2.0","id":4,"result":{"prompts":[{"name":"review","description":"评审提示"}]}}'
read line5
echo '{"jsonrpc":"2.0","id":3,"result":{"resources":[{"name":"readme"}]}}'
