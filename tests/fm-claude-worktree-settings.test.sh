#!/usr/bin/env bash
# Behavior tests for the claude adapter's launch-line settings handoff in
# bin/fm-spawn.sh.
#
# Firstmate used to write its lifecycle hooks straight into the task worktree's
# .claude/settings.local.json, truncating whatever the project had seeded there
# (permissions, plugins, MCP servers) for the whole life of the task, and to
# append an ignore entry for that path into the project's shared
# $GIT_DIR/info/exclude. Both were unasked writes into a repo firstmate only
# reads. The hooks now live in state/<id>.claude-settings.json and reach the
# agent through claude's `--settings` argument instead.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated git
# worktree, then take the settings path OUT OF THE LAUNCH LINE the pane received
# and drive those hooks against the real bin/fm-busy-event.sh writer and the real
# classifier. That is what proves the hooks are in force: the assertions are on
# the lifecycle the agent's own settings produce, never on the launch line
# carrying a flag.
#
# claude's own merge semantics for --settings (an ADDITIONAL source that leaves
# user/project/local settings loaded) are harness-dependent and cannot be proven
# without the real binary; tests/fm-claude-settings-handoff-live-e2e.test.sh is
# the opt-in guard that proves them, and docs/verification/runtime-backends.md
# records the result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-worktree-settings)

# The captain's own settings for the repo: permissions, a plugin, and a hook of
# the project's own. Every one of these was destroyed by the truncating write.
PROJECT_SETTINGS='{"permissions":{"allow":["Bash(npm run build:*)","Bash(pnpm test:*)","WebFetch(domain:example.invalid)"],"deny":[]},"enabledPlugins":{"captains-plugin@local":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}'

make_case() {  # <name> <id> [seed-project-settings]
  local name=$1 id=$2 seed=${3:-seed} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$case_dir/capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_FAKE_CAPTURE/literal"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  if [ "$seed" = seed ]; then
    mkdir -p "$wt/.claude"
    printf '%s\n' "$PROJECT_SETTINGS" > "$wt/.claude/settings.local.json"
  fi
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <case-dir> <home> <wt> <fakebin> <spawn-args...>
  local case_dir=$1 home=$2 wt=$3 fakebin=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_CAPTURE="$case_dir/capture" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The settings file the AGENT was actually handed, read back out of the launch
# line the pane received. Everything downstream drives this file, so a spawn that
# wrote good hooks somewhere the agent never sees them fails these tests.
launch_settings_path() {  # <case-dir>
  local line literal="$1/capture/literal"
  [ -f "$literal" ] || return 1
  line=$(grep -m1 -- ' --settings ' "$literal") || return 1
  printf '%s' "$line" | sed -n "s/.* --settings '\\([^']*\\)'.*/\\1/p"
}

hook_command() {  # <settings.json> <event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  printf '%s' "$cmd"
}

run_hook() {  # <settings.json> <event>
  sh -c "$(hook_command "$1" "$2")"
}

classify() {  # <id> <state-dir>
  fm_busy_classify tmux fake:w claude "$1" "$2" ''
}

exclude_file() {  # <worktree>
  git -C "$1" rev-parse --git-path info/exclude
}

sha() {  # <path>
  shasum -a 256 "$1" | awk '{print $1}'
}

# --- 1. the project's own settings survive a spawn untouched -----------------

test_spawn_leaves_a_seeded_settings_file_byte_identical() {
  local rec id=cws-1 out settings before after excl excl_before excl_after
  rec=$(make_case seeded "$id")
  read_case "$rec"
  settings="$WT_DIR/.claude/settings.local.json"
  excl=$(exclude_file "$WT_DIR")
  before=$(sha "$settings")
  excl_before=$(sha "$excl")

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"

  after=$(sha "$settings")
  [ "$before" = "$after" ] \
    || fail "spawn rewrote the project's .claude/settings.local.json ($before -> $after)"

  excl_after=$(sha "$excl")
  [ "$excl_before" = "$excl_after" ] \
    || fail "spawn wrote into the project's shared \$GIT_DIR/info/exclude"
  grep -qF '.claude/settings.local.json' "$excl" \
    && fail "spawn appended an ignore entry for the project's settings file"

  pass "a spawn leaves a seeded .claude/settings.local.json and \$GIT_DIR/info/exclude byte-identical"
}

# --- 2. a worktree with no settings file still gets none ---------------------

test_spawn_creates_no_settings_file_when_the_repo_has_none() {
  local rec id=cws-2 out excl
  rec=$(make_case unseeded "$id" no-seed)
  read_case "$rec"
  excl=$(exclude_file "$WT_DIR")

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"

  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "spawn created a settings file in a repo that had none"
  assert_absent "$WT_DIR/.claude" \
    "spawn created a .claude directory in a repo that had none"
  grep -qF '.claude/settings.local.json' "$excl" \
    && fail "spawn appended an ignore entry for a file it no longer writes"

  pass "a spawn into a repo with no settings file creates neither the file nor its directory"
}

# --- 3. every hook firstmate installs is still in force ----------------------
#
# Driven through the settings path taken from the launch line, so this asserts
# the agent's own lifecycle wiring rather than the presence of a flag.

test_the_handed_settings_drive_the_full_lifecycle() {
  local rec id=cws-3 out settings state
  rec=$(make_case lifecycle "$id")
  read_case "$rec"
  state="$HOME_DIR/state"

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"

  settings=$(launch_settings_path "$CASE_DIR") \
    || fail "the launch line handed the agent no --settings file"
  [ -n "$settings" ] || fail "could not read the settings path out of the launch line"
  assert_present "$settings" "the launch line names a settings file that does not exist"
  case "$settings" in
    "$WT_DIR"/*) fail "the settings handed to the agent live inside the task worktree: $settings" ;;
  esac
  jq -e . "$settings" >/dev/null || fail "the handed settings are not valid JSON"
  grep -qF '__CLAUDESETTINGS__' "$CASE_DIR/capture/literal" \
    && fail "an unsubstituted placeholder reached the launch line"

  out=$(classify "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify "$id" "$state")
  [ "$out" = "idle claude-hook" ] \
    || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_hook "$settings" UserPromptSubmit
  run_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"

  pass "the settings handed on the launch line open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

# --- 4. each close event stays distinguishable -------------------------------
#
# All three closing hooks record idle, so a copy-paste slip between them is
# invisible to a state assertion alone. The recorded event is what tells a
# supervisor an abnormal end apart from a clean one, so pin it directly.

test_each_lifecycle_hook_records_its_own_event() {
  local rec id=cws-4 out settings ev
  rec=$(make_case events "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"
  settings=$(launch_settings_path "$CASE_DIR") \
    || fail "the launch line handed the agent no --settings file"

  while IFS='|' read -r event expected; do
    [ -n "$event" ] || continue
    ev=$(hook_command "$settings" "$event" | sed -n 's/.*--event \([a-z-]*\).*/\1/p')
    [ "$ev" = "$expected" ] \
      || fail "the $event hook records event '$ev', expected '$expected'"
  done <<'EOF'
UserPromptSubmit|user-prompt-submit
Stop|stop
StopFailure|stop-failure
SessionEnd|session-end
EOF

  pass "each lifecycle hook records its own distinct event, so an abnormal end stays distinguishable"
}

# --- 5. a secondmate resolves the placeholder away ---------------------------
#
# A secondmate installs no per-task lifecycle hooks, so it has no settings file
# to hand over. The placeholder has to disappear rather than leave a bare
# --settings with no argument, which would swallow the brief.

test_a_secondmate_launch_carries_no_settings_flag() {
  local rec id=cws-5 out literal sub
  rec=$(make_case secondmate "$id" no-seed)
  read_case "$rec"
  sub="$CASE_DIR/submate"
  seed_secondmate_home_marker "$sub" "$id"
  mkdir -p "$sub/state" "$sub/config" "$sub/projects"
  # make_case leaves a plain crewmate brief; a secondmate launches from a charter.
  rm -f "$HOME_DIR/data/$id/brief.md"
  scaffold_secondmate_charter "$HOME_DIR" "$id" "test scope" --no-projects

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$sub" --secondmate)
  expect_code 0 $? "secondmate spawn should succeed: $out"

  literal="$CASE_DIR/capture/literal"
  assert_present "$literal" "the secondmate launch was never delivered"
  grep -qF '__CLAUDESETTINGS__' "$literal" \
    && fail "an unsubstituted placeholder reached the launch line"
  grep -qF -- ' --settings ' "$literal" \
    && fail "a secondmate installs no per-task hooks, so it must carry no --settings"

  pass "a secondmate launch resolves the settings placeholder away instead of passing an empty flag"
}

test_spawn_leaves_a_seeded_settings_file_byte_identical
test_spawn_creates_no_settings_file_when_the_repo_has_none
test_the_handed_settings_drive_the_full_lifecycle
test_each_lifecycle_hook_records_its_own_event
test_a_secondmate_launch_carries_no_settings_flag

echo "all fm-claude-worktree-settings tests passed"
