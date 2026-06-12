#!/bin/bash
# ClaudeDeck statusline integration.
#
# Claude Code 2.1.x stopped writing live-session transcripts to
# ~/.claude/projects/<id>.jsonl incrementally (only on clean exit), so ClaudeDeck
# can no longer read a running session's context/model from disk. But Claude Code
# DOES pass that data to the statusLine command on every render. This helper
# captures it into a small per-session cache that ClaudeDeck reads, then delegates
# the actual status line rendering to your own command (or a built-in default).
#
# Setup (~/.claude/settings.json):
#   "statusLine": { "type": "command",
#     "command": "bash ~/.claude/claudedeck-statusline.sh [INNER_STATUSLINE_SCRIPT]" }
# Pass the path to your existing statusline script as the first argument to keep
# it; omit it for a minimal default line.
#
# Requires: jq.
set -euo pipefail

input=$(cat)
dir="$HOME/.claude/claudedeck/status"
mkdir -p "$dir"

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
if [ -n "${sid:-}" ]; then
  # current_usage sums to ClaudeDeck's context-token definition
  # (input + output + cache_creation + cache_read).
  printf '%s' "$input" | jq -c '{
    session_id: .session_id,
    cwd: (.workspace.current_dir // .cwd),
    model: .model.id,
    context_tokens: ((.context_window.current_usage // {})
      | (.input_tokens // 0) + (.output_tokens // 0)
        + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
    context_limit: (.context_window.context_window_size // 0),
    used_percentage: (.context_window.used_percentage // 0),
    ts: now
  }' > "$dir/$sid.json.tmp" 2>/dev/null && mv -f "$dir/$sid.json.tmp" "$dir/$sid.json" || true
fi

# Render: delegate to the inner statusline if given, else a minimal default.
inner="${1:-}"
if [ -n "$inner" ] && [ -f "$inner" ]; then
  printf '%s' "$input" | bash "$inner"
else
  printf '%s' "$input" | jq -r '"\(.model.display_name // "claude") · ctx \(.context_window.used_percentage // 0)%"'
fi
