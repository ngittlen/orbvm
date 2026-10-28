#!/usr/bin/env bash
# Claude Code status line
# Shows: current working directory, git branch, model name, context usage, rate limits

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_hour_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Format a unix-epoch reset time. Within 24h -> "3:00pm"; further out -> "thu 3pm".
# Prints nothing if absent or already elapsed (a stale window refreshes on the
# next API response, and showing a past clock time would just read as wrong).
fmt_reset() {
  local ts="${1%%.*}" now delta out
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  delta=$((ts - now))
  [ "$delta" -le 0 ] && return 0
  if [ "$delta" -lt 86400 ]; then
    out=$(date -r "$ts" '+%-I:%M%p' 2>/dev/null || date -d "@$ts" '+%-I:%M%p' 2>/dev/null)
  else
    out=$(date -r "$ts" '+%a %-I%p' 2>/dev/null || date -d "@$ts" '+%a %-I%p' 2>/dev/null)
  fi
  printf '%s' "$out" | tr 'A-Z' 'a-z'
}

# Shorten $HOME to ~ in the cwd
dir="$cwd"
if [ -n "$HOME" ] && [ "${dir#"$HOME"}" != "$dir" ]; then
  dir="~${dir#"$HOME"}"
fi

# Git branch (skip optional locks so this never blocks/writes to the repo)
branch=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
  if [ -n "$branch" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    branch="${branch}*"
  fi
fi

# Context usage
context=""
if [ -n "$used_pct" ]; then
  context=$(printf '%.0f%% used' "$used_pct")
fi

# Rate limits (subscription plans only; absent on pay-as-you-go API)
limits=""
if [ -n "$five_hour" ]; then
  limits=$(printf '5h %.0f%%' "$five_hour")
  reset=$(fmt_reset "$five_hour_at")
  [ -n "$reset" ] && limits="${limits} →${reset}"
fi
if [ -n "$seven_day" ]; then
  [ -n "$limits" ] && limits="${limits} · "
  limits=$(printf '%s7d %.0f%%' "$limits" "$seven_day")
  reset=$(fmt_reset "$seven_day_at")
  [ -n "$reset" ] && limits="${limits} →${reset}"
fi

# Colors (dim-friendly; terminal already renders dim palette)
DIR_COLOR='\033[2;36m'   # dim cyan
BRANCH_COLOR='\033[2;33m' # dim yellow
MODEL_COLOR='\033[2;35m'  # dim magenta
CTX_COLOR='\033[2;37m'    # dim white
LIMIT_COLOR='\033[2;32m'  # dim green
RESET='\033[0m'
SEP=' \033[2m|\033[0m '

parts=()
[ -n "$dir" ] && parts+=("$(printf "${DIR_COLOR}%s${RESET}" "$dir")")
[ -n "$branch" ] && parts+=("$(printf "${BRANCH_COLOR}%s${RESET}" "$branch")")
[ -n "$model" ] && parts+=("$(printf "${MODEL_COLOR}%s${RESET}" "$model")")
[ -n "$context" ] && parts+=("$(printf "${CTX_COLOR}%s${RESET}" "$context")")
[ -n "$limits" ] && parts+=("$(printf "${LIMIT_COLOR}%s${RESET}" "$limits")")

out=""
for p in "${parts[@]}"; do
  if [ -z "$out" ]; then
    out="$p"
  else
    out="${out}$(printf "$SEP")${p}"
  fi
done

printf '%s' "$out"
