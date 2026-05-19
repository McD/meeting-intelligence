#!/bin/bash
# Verify `python -m briefings_mcp` writes nothing to stdout before the first MCP request,
# and that an MCP `tools/list` over stdio returns the three tools we registered.
#
# stdio MCP protocol = JSON-RPC framed on stdout. A stray print() corrupts the channel; this
# script is the trip-wire for that regression.

set -euo pipefail

cd "$(dirname "$0")/.."

VENV_PY=".venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
  echo "FAIL: $VENV_PY not found — venv not provisioned" >&2
  exit 1
fi

tmp_stdout=$(mktemp)
tmp_stderr=$(mktemp)
trap 'rm -f "$tmp_stdout" "$tmp_stderr"' EXIT

# JSON-RPC: initialize, then tools/list. One newline-delimited frame per request.
{
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.0"}}}\n'
  printf '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}\n'
  printf '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n'
  # Hold the pipe open long enough for the server to finish initialising and respond
  # to tools/list. FastMCP boots a docket worker which takes ~1s on a cold start.
  sleep 4
} | "$VENV_PY" -m briefings_mcp >"$tmp_stdout" 2>"$tmp_stderr" &
server_pid=$!

# Give the server time to write its responses, then terminate.
sleep 5
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true

fail=0

# 1. stdout must contain ONLY valid JSON-RPC lines (no stray prints).
non_json_lines=$(grep -vE '^\{.*\}$' "$tmp_stdout" | grep -v '^$' || true)
if [ -n "$non_json_lines" ]; then
  echo "FAIL: stdout contains non-JSON lines:"
  echo "$non_json_lines"
  fail=1
else
  echo "PASS: stdout contains only JSON-RPC frames"
fi

# 2. tools/list response must list our three tools.
for tool in search_decisions get_decision_by_id list_attendees; do
  if grep -q "\"$tool\"" "$tmp_stdout"; then
    echo "PASS: tools/list advertises $tool"
  else
    echo "FAIL: tools/list missing $tool"
    fail=1
  fi
done

# 3. stderr should look like Python logging output, not panic.
if grep -qE 'Traceback|Error' "$tmp_stderr"; then
  echo "FAIL: stderr contains traceback or error:"
  cat "$tmp_stderr"
  fail=1
else
  echo "PASS: stderr is clean (no traceback)"
fi

exit "$fail"
