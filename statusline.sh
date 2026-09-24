#!/bin/bash
# Claude Code status line command.
#
# Claude Code pipes a JSON document to stdin on every status line render.
# For Pro/Max accounts it includes .rate_limits.five_hour and .rate_limits.seven_day
# (used_percentage and resets_at). We save those for the ClaudeUsageBar menu bar app
# and print a short status line for Claude Code itself.

STATE_DIR="$HOME/.claude/usage-bar"
STATE_FILE="$STATE_DIR/rate-limits.json"

input=$(cat)

rate_limits=$(echo "$input" | jq -c '.rate_limits // empty')
if [ -z "$rate_limits" ]; then
  echo "✦ usage n/a"
  exit 0
fi

mkdir -p "$STATE_DIR"

# Write to a temp file and rename so the menu bar app never reads a half-written file.
temp_file=$(mktemp "$STATE_DIR/rate-limits.XXXXXX")
echo "$rate_limits" | jq -c --argjson now "$(date +%s)" \
  '{five_hour, seven_day, updated_at: $now}' > "$temp_file"
mv "$temp_file" "$STATE_FILE"

session_percent=$(echo "$rate_limits" | jq -r '.five_hour.used_percentage // empty')
week_percent=$(echo "$rate_limits" | jq -r '.seven_day.used_percentage // empty')

if [ -n "$session_percent" ]; then
  session_text=$(printf "%.0f%%" "$session_percent")
else
  session_text="–"
fi

if [ -n "$week_percent" ]; then
  week_text=$(printf "%.0f%%" "$week_percent")
else
  week_text="–"
fi

echo "✦ $session_text · $week_text"
