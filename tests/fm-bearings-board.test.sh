#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
#
# Plus the one thing about the board that only a browser can answer: which of
# the two things a decision card can do with the captain's prose each of its
# actions actually queues. That check drives the real built page in headless
# Chrome and self-skips where no Chrome is installed.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: the payload extracted from the built page is byte-for-byte the
  # same JSON document, and the escaped </script> string can no longer
  # terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != poll ]; then
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

# Chrome, wherever this host keeps it. FM_TEST_CHROME overrides the search.
find_chrome() {
  local candidate
  if [ -n "${FM_TEST_CHROME:-}" ]; then
    # An operator who named a binary meant it; a bad path is an error, not a skip.
    [ -x "$FM_TEST_CHROME" ] || fail "FM_TEST_CHROME is not an executable: $FM_TEST_CHROME"
    printf '%s\n' "$FM_TEST_CHROME"
    return
  fi
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
  done
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

# The captain gets two things to do with prose on a decision card, and only one
# of them is his ruling. Everything downstream depends on the card queueing the
# right one, and no shell fixture can prove that: it is the page's own behavior.
#
# So this drives the REAL built board in a real browser. The driver replaces
# Lavish's queuePrompt with a recorder, works the cards the way the captain
# would, and writes what each action queued back into the page for --dump-dom.
test_a_card_queues_a_question_as_a_question_and_a_ruling_as_a_ruling() {
  local home chrome data board driven report rc
  chrome=$(find_chrome)
  [ -n "$chrome" ] || { pass "no Chrome installed, skipping the board's browser behavior"; return; }
  home=$(make_home card-actions)
  data="$home/payload.json"
  cat > "$data" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-24T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-account-binding",
      "type": "decision",
      "repo": "sample",
      "title": "Account binding",
      "decide": "Which validation home?",
      "options": [
        { "value": "shared", "label": "Keep the shared home" },
        { "value": "own", "label": "Give it its own home" }
      ],
      "allow_freeform": true
    },
    {
      "key": "sample-options-only",
      "type": "decision",
      "repo": "sample",
      "title": "Options only",
      "decide": "Pick one",
      "options": [
        { "value": "a", "label": "A" },
        { "value": "b", "label": "B" }
      ]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [],
  "charted_more": 0
}
EOF
  run_board "$home" build "$data" >/dev/null || fail "the card-actions board build failed"
  board="$home/.lavish/bearings-board.html"
  driven="$home/driven.html"
  cat > "$home/driver.html" <<'EOF'
<script>
(function () {
  var lines = [];
  var queued = [];
  window.lavish = { queuePrompt: function (text, opts) { queued.push(opts); } };
  function button(form, label) {
    var all = form.querySelectorAll("button");
    for (var i = 0; i < all.length; i++) {
      if (all[i].textContent.indexOf(label) === 0) return all[i];
    }
    return null;
  }
  /* A card missing the box or the action reports that, rather than throwing and
     leaving the run with nothing to read. */
  function act(name, form, prose, label, option) {
    queued = [];
    var box = form.querySelector(".bb-freeform");
    var action = button(form, label);
    if (!box) { lines.push(name + " tag=no-prose-box"); return; }
    if (!action) { lines.push(name + " tag=no-action"); return; }
    if (option) form.querySelector("input[type=radio][value=" + option + "]").checked = true;
    box.value = prose;
    action.click();
    if (!queued.length) { lines.push(name + " tag=none"); return; }
    var q = queued[queued.length - 1];
    var d = q.data || {};
    lines.push(name + " tag=" + q.tag +
      " question=" + (d.question || "-") + " answer=" + (d.answer || "-") +
      " call=" + (d.call || "-") + " ask=" + (d.ask || "-"));
  }
  try {
    var cards = document.querySelectorAll("#bb-call .bb-decision");
    var freeform = cards[0].querySelector("form");
    var optionsOnly = cards[1].querySelector("form");
    act("typed-question", freeform, "What does its own validation home entail?", "Ask");
    act("prose-ruling", freeform, "do A but skip the second step", "Queue answer");
    act("option-with-note", freeform, "but only after the migration", "Queue answer", "own");
    act("no-freeform-prose-ruling", optionsOnly, "just do whatever you think", "Queue answer");
    act("no-freeform-question", optionsOnly, "what breaks if I pick B?", "Ask");
  } catch (err) {
    lines.push("driver-error " + err);
  }
  var out = document.createElement("pre");
  out.id = "fm-probe";
  out.textContent = lines.join("\n");
  document.body.appendChild(out);
})();
</script>
EOF
  perl -e '
    my ($board, $driver, $out) = @ARGV;
    local $/;
    open my $b, "<", $board or die "board: $!";
    my $page = <$b>;
    open my $d, "<", $driver or die "driver: $!";
    my $script = <$d>;
    die "board has no single body close\n" unless 1 == ($page =~ s/<\/body>/$script<\/body>/);
    open my $o, ">", $out or die "out: $!";
    print $o $page;
  ' "$board" "$home/driver.html" "$driven" || fail "could not build the driven board page"

  set +e
  # No --user-data-dir. Pointing Chrome at a fresh profile directory here keeps
  # it alive long past the dump, so the run only ends on the bound; the default
  # headless profile handling dumps and exits in about two seconds.
  fm_run_timed 60 "$chrome" --headless --disable-gpu --no-sandbox \
    --dump-dom "file://$driven" > "$home/dump.html" 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "driving the board in Chrome failed (exit $rc)"
  report=$(perl -0777 -ne '
    if (m{<pre id="fm-probe">(.*?)</pre>}s) {
      my $t = $1;
      $t =~ s/&lt;/</g; $t =~ s/&gt;/>/g; $t =~ s/&quot;/"/g;
      $t =~ s/&#0?39;/'"'"'/g; $t =~ s/&amp;/&/g;
      print $t;
    }' "$home/dump.html")
  [ -n "$report" ] || fail "the driven board produced no record of what its actions queued"

  # The reproduction: the captain types a question instead of picking. It must
  # reach firstmate as a question and carry no answer key at all, because the
  # keyed-answer intake is what closes his call.
  assert_contains "$report" \
    "typed-question tag=question question=- answer=- call=sample-account-binding ask=What does its own validation home entail?" \
    "a typed question was not queued as a question: $report"
  # And prose the captain does offer as his ruling still closes the call.
  assert_contains "$report" \
    "prose-ruling tag=choice question=sample-account-binding answer=do A but skip the second step call=- ask=-" \
    "a prose ruling was not queued as the captain's answer: $report"
  assert_contains "$report" \
    "option-with-note tag=choice question=sample-account-binding answer=own - but only after the migration call=- ask=-" \
    "an annotated option was not queued as the captain's answer: $report"
  # A card that never invited prose as a ruling refuses to treat it as one, and
  # still lets the captain ask.
  assert_contains "$report" "no-freeform-prose-ruling tag=none" \
    "prose became a ruling on a card that allows no freeform answer: $report"
  assert_contains "$report" \
    "no-freeform-question tag=question question=- answer=- call=sample-options-only ask=what breaks if I pick B?" \
    "a card that allows no freeform answer could not carry a question: $report"
  pass "a decision card queues a question as a question and a ruling as a ruling"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_a_card_queues_a_question_as_a_question_and_a_ruling_as_a_ruling
