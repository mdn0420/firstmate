#!/usr/bin/env bash
# Behavior tests for the verified claude crewmate adapter's launch posture.
#
# The contract these pin: firstmate launches a claude worker with NO
# firstmate-chosen permission override, so the sandbox and auto-mode classifier
# configured in that installation's own Claude config store govern the worker.
# A raw launch command stays the per-spawn escape hatch for a task that needs a
# different posture.
#
# These drive fm-spawn through a fake tmux pane and a real isolated git
# worktree. The fake tmux captures the literal command sent with
# `tmux send-keys -l`, so assertions pin the command firstmate would run without
# starting a real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, so drop them and let the
# configured crew harness decide.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-harness)

# Every permission override firstmate could plausibly re-add to the claude
# launch. The point of the adapter is that none of them appear.
PERMISSION_OVERRIDES=(
  --dangerously-skip-permissions
  --allow-dangerously-skip-permissions
  --permission-mode
  --allowedTools
  --allowed-tools
  --disallowedTools
  --disallowed-tools
)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"; fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id> echoes "home|proj|wt|fakebin|launchlog".
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<REC
$1
REC
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches, so pin it empty rather
  # than leaking the developer's own store into launch assertions.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

assert_no_permission_override() {
  local launch=$1 what=$2 flag
  for flag in "${PERMISSION_OVERRIDES[@]}"; do
    assert_not_contains "$launch" "$flag" \
      "$what must not carry a firstmate-chosen permission override ($flag); the installation's own configured mode governs the worker"
  done
}

test_ship_launch_carries_no_permission_override() {
  local rec id out status launch
  id=claude-ship-z1
  rec=$(make_case ship "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "claude ship spawn should succeed: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude ' \
    "claude ship launch did not invoke claude with the ghost-text control"
  assert_contains "$launch" "$HOME_DIR/data/$id/brief.md" \
    "claude ship launch did not deliver the task brief"
  assert_no_permission_override "$launch" "the claude ship launch"
  pass "a claude ship worker launches on its installation's own configured permission mode"
}

test_scout_launch_carries_no_permission_override() {
  local rec id out status launch
  id=claude-scout-z1
  rec=$(make_case scout "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn should succeed: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude ' \
    "claude scout launch did not invoke claude with the ghost-text control"
  assert_no_permission_override "$launch" "the claude scout launch"
  pass "a claude scout worker launches on its installation's own configured permission mode"
}

# The escape hatch: a task that genuinely needs the old bypass passes a raw
# launch command. It must still resolve harness=claude, so every claude-specific
# plumbing step (config-store forwarding, turn-end hook, busy source) applies.
test_raw_launch_command_restores_bypass_for_one_spawn() {
  local rec id out status launch
  id=claude-raw-z1
  rec=$(make_case raw "$id")
  read_case "$rec"

  # shellcheck disable=SC2016  # single quotes are deliberate: the placeholders
  # must reach fm-spawn unexpanded, and $(...) expands in the crewmate pane.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(__OPINPUT__ encode launch-brief < __BRIEF__)"')
  status=$?
  expect_code 0 "$status" "raw claude launch command should succeed: $out"
  assert_contains "$out" "spawned $id harness=claude" \
    "a raw claude launch command must still resolve harness=claude"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '--dangerously-skip-permissions' \
    "the raw launch command escape hatch did not preserve the requested bypass"
  assert_contains "$launch" "$HOME_DIR/data/$id/brief.md" \
    "the raw launch command did not receive the substituted brief path"
  pass "a raw launch command is the per-spawn escape hatch back to the old bypass"
}

# The escape hatch is per-spawn: using it must not change what the next ordinary
# spawn launches.
test_raw_launch_command_does_not_change_the_default() {
  local rec id out status launch
  id=claude-after-raw-z1
  rec=$(make_case after-raw "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ordinary claude spawn should succeed: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_no_permission_override "$launch" "an ordinary claude launch"
  pass "the escape hatch changes one spawn only, never the adapter default"
}

test_ship_launch_carries_no_permission_override
test_scout_launch_carries_no_permission_override
test_raw_launch_command_restores_bypass_for_one_spawn
test_raw_launch_command_does_not_change_the_default

echo "# all fm-claude-harness tests passed"
