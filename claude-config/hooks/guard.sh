#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
# the tool call arrives as JSON on stdin
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
command=$(echo "$input" | jq -r '.tool_input.command // ""')
# file-based tools (Read/Write/Edit/MultiEdit) carry a path instead of a command
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# small helper: returns 0 on match, 1 on no match
matches() { echo "$1" | grep -qE -- "$2" 2>/dev/null; }

# Deny the tool call; the reason is shown to both Claude and the user in the CLI.
# Usage: deny <rule-name> <explanation>
# The message also names the tool and echoes the exact command or file path that
# tripped the rule, so the denial says what was actually attempted, not just why.
deny() {
  rule="$1"
  explanation="$2"

  reason="BLOCKED by guard.sh (rule: $rule)"
  if [ -n "$command" ]; then
    # keep the message readable if the command is enormous
    shown="$command"
    if [ "${#shown}" -gt 400 ]; then
      shown="${shown:0:400}... [truncated, ${#command} chars total]"
    fi
    reason="$reason"$'\n\nAttempted '"$tool_name"$' command:\n  '"$shown"
  elif [ -n "$file_path" ]; then
    reason="$reason"$'\n\nAttempted '"$tool_name"$' on file:\n  '"$file_path"
  else
    reason="$reason"$'\n\nAttempted tool: '"${tool_name:-unknown}"
  fi
  reason="$reason"$'\n\n'"$explanation"

  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if matches "$command" 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
  deny "no-rm-rf" "rm -rf risks catastrophic, irreversible data loss. Safer: remove specific files by name, or use rm -ri for confirmation."
fi

if matches "$command" 'git\s+push\s+.*(--force\b|-f\b)'; then
  if ! matches "$command" '--force-with-lease'; then
    deny "no-force-push" "git push --force can overwrite a collaborator's history. Safer: use git push --force-with-lease."
  fi
fi

dotenv_advice="these usually hold secrets. If you need a specific non-secret key, ask the user, or use a .env.example/.env.template instead."

if matches "$command" '(cat|head|tail|less|more)\s+.*\.env'; then
  if ! matches "$command" '\.env\.(example|template|sample)'; then
    deny "no-dotenv-read" "Reading a .env file via shell is blocked because $dotenv_advice"
  fi
fi

# Same protection for the file tools, which take a path rather than a command.
# Matches .env, .env.local, .env.production, dev.env — but not .envrc.
if [ "$tool_name" = "Read" ] && matches "$file_path" '\.env(\.[^/]*)?$'; then
  if ! matches "$file_path" '\.env\.(example|template|sample)$'; then
    deny "no-dotenv-read" "Reading a .env file is blocked because $dotenv_advice"
  fi
fi
