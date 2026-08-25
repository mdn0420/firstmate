#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the launch-line settings
# handoff that bin/fm-spawn.sh uses instead of writing the task worktree's
# .claude/settings.local.json.
#
# Three facts here are harness-dependent - only the real binary can answer them,
# and a stub would only confirm the assumption written into the stub:
#   1. `--settings <file>` actually puts firstmate's lifecycle hooks in force.
#   2. It is an ADDITIONAL source: the project's own settings stay loaded, so a
#      hook the project registers still fires alongside firstmate's. If claude
#      ever made --settings replace the project scope, firstmate would silently
#      disarm every project's own hooks for the life of a task.
#   3. Passing it leaves the project's .claude/settings.local.json byte-identical.
#
# The project and the settings file are isolated under a scratch lab; Claude
# keeps using its existing managed authentication. No live fleet home, worktree,
# or session is touched. Refresh docs/verification/runtime-backends.md from this
# guard after every Claude upgrade.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude settings-handoff regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v claude >/dev/null 2>&1 \
  || fail "claude not found on PATH; this guard must not pass without exercising the real harness"
CLAUDE_VERSION=$(claude --version 2>&1) \
  || fail "claude --version failed; cannot attribute a result to a version"

LAB="$ROOT/.claude-settings-handoff-live-e2e.$$"
PROJECT="$LAB/project"
SETTINGS="$LAB/fm-settings.json"
MARKERS="$LAB/markers"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude" "$MARKERS"

# The project's own settings: permissions firstmate has no business rewriting,
# plus a hook of the project's own on the same event firstmate uses.
cat > "$PROJECT/.claude/settings.local.json" <<JSON
{
  "permissions": {
    "allow": ["Bash(echo:*)"],
    "deny": []
  },
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "touch $MARKERS/project-stop"}]}
    ]
  }
}
JSON
BEFORE=$(shasum -a 256 "$PROJECT/.claude/settings.local.json" | awk '{print $1}')

# Firstmate's own hooks, shaped like the ones bin/fm-spawn.sh writes: one opening
# event and the three closing events, all outside the project.
cat > "$SETTINGS" <<JSON
{"hooks":{
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"touch $MARKERS/fm-submit"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"touch $MARKERS/fm-stop"}]}]
}}
JSON

( cd "$PROJECT" && claude -p 'Reply with exactly: OK' --settings "$SETTINGS" ) \
  </dev/null >"$LAB/out" 2>"$LAB/err" \
  || fail "claude $CLAUDE_VERSION refused the --settings launch: $(cat "$LAB/err")"

# 1. firstmate's hooks are in force.
[ -f "$MARKERS/fm-submit" ] \
  || fail "claude $CLAUDE_VERSION did not run the UserPromptSubmit hook from --settings"
[ -f "$MARKERS/fm-stop" ] \
  || fail "claude $CLAUDE_VERSION did not run the Stop hook from --settings"
pass "claude $CLAUDE_VERSION puts firstmate's lifecycle hooks in force from --settings"

# 2. --settings ADDS to the project scope instead of replacing it.
[ -f "$MARKERS/project-stop" ] \
  || fail "claude $CLAUDE_VERSION suppressed the project's own Stop hook when --settings was passed; the handoff would disarm every project's hooks"
pass "claude $CLAUDE_VERSION merges --settings with the project's own settings rather than replacing them"

# 3. the project's file is untouched.
AFTER=$(shasum -a 256 "$PROJECT/.claude/settings.local.json" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] \
  || fail "claude $CLAUDE_VERSION rewrote the project's .claude/settings.local.json ($BEFORE -> $AFTER)"
pass "claude $CLAUDE_VERSION leaves the project's .claude/settings.local.json byte-identical"

echo "all fm-claude-settings-handoff-live-e2e checks passed against claude $CLAUDE_VERSION"
