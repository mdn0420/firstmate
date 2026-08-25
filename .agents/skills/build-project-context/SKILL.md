---
name: build-project-context
description: >-
  Agent-only procedure for building orientation context on a registered project.
  Use before scoping, routing, or estimating a task against a project, before acting on a reported bug or diagnosis for one, and before answering a captain question about one, whenever firstmate is not dispatching a scout or worker immediately.
  Owns the bounded read list, claude-mem project-id resolution, the orientation digest contract, and the read-only boundary.
user-invocable: false
metadata:
  internal: true
---

# build-project-context

Use this procedure when firstmate needs to understand a registered project well enough to act, and is not about to dispatch a scout or worker immediately.
This skill is the single owner of firstmate's project-orientation read.
It produces orientation, never investigation, and never a durable deliverable.

## When this applies

Gather orientation context before scoping, routing, or estimating work against a project.
Gather it before scoping a reported bug or acting on a diagnostic report, alongside `diagnostic-reasoning`.
Gather it before answering a captain question about a project from firstmate's own knowledge.
Gather it before classifying a task's surface for delivery mode or judging its risk, where the registry gives the standing posture but not enough about the project to apply it.

Skip it entirely in these cases:

- Firstmate is dispatching now, because the worker gathers its own context in its own copy and the brief carries the task-specific detail.
- Established evidence, an existing scout report, or the session-start digest already answers the question.
- The question turns on a single fact firstmate already holds.
- The project is not registered, which is `project-management` intake rather than orientation.

Run one pass per project actually in play.
Never sweep the whole registry, and never gather for a project the current task does not touch.

## The bounded read list

Read in this order and stop as soon as the current task's question is answered.
The point is a digest firstmate can hold, not a survey.
Start from the project's own material, because the session-start digest already supplied the registry entry and firstmate holds it.

1. The project's own committed `AGENTS.md`, or `CLAUDE.md` when there is no `AGENTS.md`, at the clone root.
   Read it in full.
   It is the project's own instruction surface, written to be read, and it outranks anything inferred from the code.
2. The `README` for purpose and setup, plus the top-level directory layout.
3. Recent direction, from the default branch name and a bounded log such as `git -C <clone> log --oneline -20`.
4. Stored observations from claude-mem when that plugin is installed, per the section below.

Every one of these is a read.
Never run a state-changing command in the clone, and never let a gather turn into an exploratory crawl of the source tree.

## Supplementing with claude-mem

Do this only when the claude-mem plugin is installed in the running harness.
Its absence is not an error, and firstmate proceeds on the rest of the read list without comment.

### Resolve the project ids before querying

claude-mem keys each observation by a project id derived from the basename of the session's working directory, and it matches that id exactly with no prefix expansion.
One repository therefore accumulates several ids, so a single-id query silently returns a fraction of what is stored.

- A session running inside a git worktree files under `<repo>/<worktree-dir>`.
  Every crewmate that ever worked in an isolated copy filed its learning under a sibling id that a plain `<repo>` query never returns.
- Renaming, re-cloning, or moving a checkout strands the previous id, which stays populated and stays invisible.

This is the normal shape for any project firstmate has dispatched crewmates into, not an edge case.
A project whose main id holds thousands of observations routinely carries hundreds more across sibling ids, and an exact query on the main id returns none of them.

So enumerate candidates first, then query each and merge the results.
Take the clone directory's basename as the primary candidate, add every id that begins `<basename>/`, and add any earlier name the captain or the registry records.
Prefer the plugin's own search and timeline tools, passing each candidate id explicitly.
When those tools cannot enumerate ids, discover them read-only from the plugin's store, treating its location and schema as plugin-owned and verifying the shape before relying on it rather than assuming it:

```sh
sqlite3 -readonly "${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}/claude-mem.db" \
  "SELECT project, COUNT(*) FROM observations
   WHERE project = 'NAME' OR project LIKE 'NAME/%' GROUP BY project;"
```

### What to ask it

Query the current task's subject, not the project in general.
Ask for prior decisions in the same area, previous fixes and what they changed, stated gotchas, and the reasoning behind a convention that looks surprising.

Treat every observation as dated evidence rather than current truth.
An observation records what one session believed at one moment, and the code may have moved since.
Verify any claim that would materially change scoping against the project's current code or its committed instruction file before acting on it, and carry the observation's date whenever it is relayed.

## The orientation digest

Reduce everything gathered to a digest and discard the rest.
Carry only what firstmate did not already hold.
The session-start digest supplies the registry entry, standing delivery posture, merge authority, secondmate routing, captain preferences, and fleet-local learnings, so none of that belongs in the orientation digest and none of it needs restating to the captain.
Hold these, and no transcript:

- What the project is and what it is for, beyond the registry's one-line entry.
- The architecture and entry points that bear on the current task.
- The conventions the project states about itself.
- Its recent direction.
- Known gotchas and open threads, each carrying its date and source.
- What remains unknown.

That last item is the one that changes what firstmate does next.
When a gap could materially change whether or what to build, that is the trigger to commission a scout under the `AGENTS.md` task-lifecycle contract, not to proceed on a guess.

## Boundaries

Orientation is a read.
Firstmate reads projects and crewmates change them, so this procedure never edits a clone and never runs a state-changing command inside one.

Orientation is ephemeral.
Do not write a report artifact for it.
Route anything durable that surfaces during a gather to its owner under the `AGENTS.md` knowledge-routing contract instead.

Orientation is not authorization.
Context gathered here never authorizes a code change, and implementation still requires the captain's request or another existing lifecycle authority.

## Doing the gather

Firstmate performs this read itself.
That is deliberate and settled, so do not re-derive it per task.

Delegating the gather to a harness-native subagent would isolate the context cost, but the delegation guard in [`subagent-guard.md`](../../../docs/subagent-guard.md) denies delegation-shaped tools in a primary home, and several supported harnesses expose no such tool at all.
Treat the direct read as the normal path, and never write a procedure that depends on delegation being available.

Never use a scout for orientation.
A scout is the durable-deliverable path, so using one here inverts the trigger that brought firstmate to this skill, spends an isolated copy and a supervision commitment on a bounded read, and files the scout's own observations under a worktree-shaped claude-mem id that fragments the project memory this procedure exists to read.
