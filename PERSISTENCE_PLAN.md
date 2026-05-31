# maestrode persistence plan

Goal: make maestrode mode stick for the whole session once activated, and make
the brain (Claude Code) honor it without relying on memory. Cover the gap where
spawned subagents bypass the mode entirely.

This is a plan, not an implementation. It is sequenced so each phase ships and
is verifiable on its own.

---

## 1. The problem, stated precisely

maestrode is an action-replacer mode: "when about to author code, prose, or a
config, call the cheap muscle via the `maestrode` shim instead of editing
directly." Today the mode lives only in the conversation: the skill description
fires once on activation, plus a per-turn footer tag the brain is asked to emit.

It fades after a few turns. Observed and logged in memory
(`feedback_maestrode_drift.md`). Three reasons:

1. The trigger is brain-emitted, not harness-pushed. The skill description fires
   once, then conversation churn buries it. The footer tag depends on the brain
   remembering to write it, and the brain forgets.
2. Drift is silent. A direct `Edit` looks identical to normal work. Nothing in
   the output flags it as a violation. Contrast caveman, where a normal-prose
   paragraph in a caveman session is obviously wrong on sight.
3. The constraint and the output are decoupled. Caveman sticks because every
   token the brain writes IS the trigger: you cannot produce output without
   honoring the mode. maestrode's constraint (delegate) and its output (chat)
   are separate, so there is no natural forcing function.

There is also a fourth hole, raised by the user: **subagents spawned via the
Agent tool do not inherit the mode at all.** A subagent runs with the full
expensive model, never sees the skill, and authors code directly. Brain reaching
for the Agent tool is itself a bypass of the cheap muscle.

## 2. Why the previous hook was removed (and why that does not kill the idea)

An earlier version did the right instinct: a `PreToolUse` reminder hook plus a
sentinel file at `~/.config/maestrode/active`. It was pulled (commits 427c72e to
024b293) because the sentinel was **global** filesystem state. A session that
ended without "maestrode off" left the file behind, and every future session
then saw the mode as active and fired the reminder when the user never asked for
it. The fix at the time was to drop hooks entirely and go conversation-only.

The lesson was mis-drawn. The hook was not the problem. The **global, un-keyed
state** was the problem. A hook is exactly the deterministic forcing function
the mode needs, the same way every-token-is-the-trigger is what makes caveman
stick. The engineering task is to bring the hook back with state that cannot
leak across sessions.

## 3. The unlock: every hook receives `session_id`

Verified against current Claude Code docs (code.claude.com/docs/en/hooks.md):

- Every hook event (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`,
  `SessionStart`, `SessionEnd`, `Stop`) receives `session_id` on stdin.
- `UserPromptSubmit` can inject text into the model's context for the turn via
  `hookSpecificOutput.additionalContext`. This is the harness-pushed analog of
  the footer tag: it fires every turn, deterministically, and the brain cannot
  forget it.
- `PreToolUse` matcher accepts pipe lists like `Edit|Write|MultiEdit|NotebookEdit|Task`
  and can return `permissionDecision: "allow"` with `additionalContext`, which
  shows the model a reminder without blocking the call. `Task` is the tool name
  for Agent spawns, so subagent creation is catchable.
- `SessionEnd` fires best-effort on normal termination and can run a cleanup
  command. It does not fire reliably on crash or kill.

Keying all state to `session_id` makes the old leak impossible: session B reads
its own id, never sees session A's state, and a new session always has a new id.

There is no public API to register a hook scoped to one session at runtime
(`/goal` does it internally and is not exposed). So the hooks are registered
globally in `settings.json`, but they are **gated on a per-session sentinel**:
the hook is always present and is a no-op unless `sessions/<session_id>` exists.
Global hook, per-session state. That combination is what fixes the original bug.

## 4. Design principle

Move persistence from brain-emitted to harness-injected. The brain's only job
becomes the actual decision (delegate or, for a named reason, go direct). The
"is the mode still on, and what does it require" signal is pushed by hooks every
turn and at every authoring tool call, so it cannot fade.

Activation and deactivation are also moved into the hook, captured from the
user's own words, so there is no brain step that can be skipped.

## 5. Architecture

Four pieces: one state directory, two hooks, one shim helper, plus the skill
rewrite.

### 5.1 State: per-session sentinel

```
~/.config/maestrode/sessions/<session_id>          # exists => mode active
~/.config/maestrode/sessions/<session_id>.lastcall # mtime = last muscle call
~/.config/maestrode/sessions/<session_id>.direct   # count of direct authoring calls since last delegation
```

All keyed by `session_id`. Nothing global. A reaper (run on each
`UserPromptSubmit` and on install) deletes entries older than 7 days to mop up
sessions that crashed before `SessionEnd`.

### 5.2 Hook A: `UserPromptSubmit` (activation + per-turn banner)

One script handles activation, deactivation, and the standing reminder, because
it sees both `prompt` and `session_id`:

1. Read `session_id` and `prompt`.
2. If `prompt` matches an activation phrase (`maestrode on`, `use maestrode`,
   `maestrode mode`, `/maestrode`, `turn on maestrode`): create
   `sessions/<id>`, inject a short "maestrode ON" confirmation banner.
3. If `prompt` matches a deactivation phrase (`maestrode off`, `normal mode`,
   `stop maestrode`): remove `sessions/<id>` and its sidecars, inject "OFF".
4. Else if `sessions/<id>` exists: inject the standing banner (see below).
5. Else: no-op.
6. Always: reap stale session files.

Standing banner, injected as `additionalContext` every turn while active:

```
[maestrode ON] Default for any code, prose, or config draft this turn:
delegate to the muscle:  maestrode -f <files> --files out/ "<brief>"
Direct Edit/Write only to apply muscle output, for a one-line tweak, or for an
architecture/security call you must own (say which). Spawning a subagent? It will
NOT inherit this mode: put the delegation contract in its prompt or let the muscle
do the work directly.
```

When the `.direct` counter is at or above 2, the banner escalates:

```
[maestrode ON, drift] You have authored directly N times since the last
delegation. Route the next draft through the muscle unless there is a named
reason.
```

This is the deterministic replacement for the footer tag. The brain no longer
has to emit anything; the rule re-instantiates itself on every prompt.

### 5.3 Hook B: `PreToolUse` on `Edit|Write|MultiEdit|NotebookEdit|Task` and `Bash`

Point-of-action nudge, fired at the exact moment of drift. Always returns
`permissionDecision: "allow"` (never blocks, because applying muscle output and
legitimate one-liners also use Edit/Write).

- On `Bash` whose command starts with `maestrode ` (a real delegation): touch
  `sessions/<id>.lastcall`, reset `sessions/<id>.direct` to 0. No message.
- On `Edit|Write|MultiEdit|NotebookEdit`: if mode active and the last muscle
  call was more than ~120s ago (cold edit, likely real drift, not output
  application), increment `.direct` and inject:
  ```
  [maestrode] Direct edit while mode is ON and no recent muscle call. If this is
  applying muscle output or a one-line tweak, proceed. Otherwise this looks like
  a draft the muscle should write: maestrode -f <file> --files out/ "<brief>".
  ```
  If a muscle call happened within the window, stay silent (this Edit is almost
  certainly applying its output).
- On `Task` (Agent spawn): if mode active, inject:
  ```
  [maestrode] You are spawning a subagent. It runs the expensive model and will
  NOT see maestrode. Either (a) embed the delegation contract in its prompt so it
  routes drafts through `maestrode` via Bash, or (b) skip the subagent and let the
  muscle do the drafting directly. Prefer (b) when the task is a straight draft.
  ```

The 120s window removes nag on the legitimate apply-output path and only speaks
up on cold authoring, which is the real drift signal. This automates the memory
note's rule ("if 2+ code turns in a row went direct, surface it") with no brain
bookkeeping.

### 5.4 Hook C: `SessionEnd` (cleanup)

Remove `sessions/<session_id>` and sidecars. Best-effort. The reaper in Hook A
covers the crash case.

### 5.5 Shim helper: `maestrode hook <event>`

Rather than ship three standalone hook scripts, add a `hook` subcommand to the
shim so all logic lives in one installed binary and the `settings.json` entries
are one-liners:

```json
"UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "maestrode hook user-prompt" }]}],
"PreToolUse":       [{ "matcher": "Edit|Write|MultiEdit|NotebookEdit|Task|Bash",
                       "hooks": [{ "type": "command", "command": "maestrode hook pre-tool" }]}],
"SessionEnd":       [{ "hooks": [{ "type": "command", "command": "maestrode hook session-end" }]}]
```

`maestrode hook <event>` reads the hook JSON from stdin, does the
session-keyed state work, and writes the hook output JSON to stdout. Keeping it
in the shim means one file to install, one place to version, and the existing
installer download path already covers it.

It also makes the mode auditable: `maestrode hook` reuses the same
`~/.config/maestrode` directory the shim already owns, so `maestrode gain` can
later report per-session delegate-vs-direct ratio from the `.direct` counters.

### 5.6 Skill rewrite

The skill drops the "required per-turn footer tag" section (the hook now owns
persistence) and gains:

- A short note that persistence is hook-driven and session-scoped, so the brain
  does not need to self-remind. The brain's job is the delegate-or-direct call.
- A new section, "Subagents under maestrode," with a copy-paste block to embed
  in any Agent prompt, mirroring the existing global rule that subagents inherit
  prose constraints. The block teaches the subagent that Bash is available, that
  `maestrode -f ... --files ...` is the default for drafts, and gives the output
  contract. Plus the bias: prefer letting the muscle draft directly over
  spawning an Opus subagent that then delegates.

The footer tag can stay as an optional visible breadcrumb for the user, but it
is no longer the persistence mechanism, so forgetting it costs nothing.

## 6. The subagent gap, addressed in full

Two independent fixes, because the gap has two halves:

1. Brain reaching for `Task` while in mode: Hook B nudges at spawn time toward
   either embedding the contract or skipping the subagent. (5.3)
2. A subagent that IS spawned: the skill's copy-paste block, embedded in the
   subagent prompt by the brain, makes the subagent itself route drafts through
   the muscle. Subagents have Bash and inherit PATH, so `maestrode` is callable
   from inside them. (5.6)

Honest caveat to document: brain to Opus-subagent to muscle spends Opus tokens
on the orchestration layer. When the task is a straight draft, the cheaper path
is brain to muscle directly, no subagent. The nudge says so.

## 7. Tiers (pick at implementation time)

- **Minimal:** Hook A only (per-turn banner + activation capture) and
  `SessionEnd` cleanup. Fixes fade with the least surface. No point-of-action
  nudge, no Task coverage.
- **Recommended:** Minimal plus Hook B (point-of-action nudge with the 120s
  window and the `Task` branch). This is the full fix for both fade and the
  subagent gap, and it is the smallest design that covers everything the user
  named.
- **Max:** Recommended plus `maestrode gain` per-session drift reporting and an
  optional `--strict` that flips the `Task`/cold-edit nudge from `allow` to
  `ask` so the user confirms each bypass. Strict is opt-in only; default stays
  non-blocking so the apply-output path is never interrupted.

## 8. Risks and mitigations

- **Re-introducing a hook that was deliberately removed.** Mitigation: the
  central change versus last time is session-id keying, which removes the leak
  that caused the removal. The installer's existing legacy-hook cleanup logic
  stays (it still removes the old global `active` sentinel and the two old hook
  scripts by name) and gains the new entries. CHANGELOG must explain the
  difference so future-me does not "fix" it by ripping hooks out again.
- **Activation phrase matching is narrower than the skill's fuzzy trigger.**
  A user who says "let's lean on maestrode here" will trip the skill but maybe
  not the hook regex. Mitigation: keep the skill description as the fuzzy
  acknowledger, and have the brain, on any activation it recognizes, run
  `maestrode hook arm` once (a brain-initiated path that the next
  `UserPromptSubmit` promotes to a real `sessions/<id>` entry using the id it
  has). Belt and suspenders; the common phrases are matched directly.
- **Banner noise.** Mitigation: the standing banner is short and only escalates
  on real drift. The PreToolUse nudge is silenced within 120s of a muscle call,
  so the apply-output path is quiet.
- **Concurrent sessions.** Handled by session-id keying. Two windows never share
  or clobber state.
- **Crash leaves a sentinel.** Handled by the 7-day reaper plus `SessionEnd`.

## 9. Install and migration

- Extend `settings.json` wiring in `install.sh` to add the three hook entries
  (idempotent, keyed by the `maestrode hook` command string so re-runs do not
  duplicate).
- Keep `cleanup_legacy_hooks` and `cleanup_legacy_sentinel` as-is; they target
  the old global `active` file and the two old script names, which the new
  design does not recreate.
- `mkdir -p ~/.config/maestrode/sessions` on install.
- Uninstall removes the three new hook entries and the `sessions/` dir.
- CHANGELOG entry: "persistence via session-id-keyed hooks; supersedes the
  conversation-only footer; explains why this does not repeat the global-sentinel
  leak."

## 10. Success criteria (verify each after build)

- `[code]` `maestrode hook user-prompt` given stdin with a fresh `session_id`
  and `prompt: "maestrode on"` creates `~/.config/maestrode/sessions/<id>` and
  prints JSON containing `additionalContext` with "maestrode ON".
- `[code]` Same command with `prompt: "maestrode off"` removes the file.
- `[code]` `maestrode hook pre-tool` with `tool_name: "Edit"` and an active
  session and no recent `.lastcall` prints `permissionDecision: "allow"` plus a
  nudge in `additionalContext`; with a `.lastcall` touched < 120s ago, prints
  `allow` and NO nudge.
- `[code]` `maestrode hook pre-tool` with `tool_name: "Task"` and an active
  session prints the subagent nudge.
- `[code]` `maestrode hook pre-tool` with `tool_name: "Bash"`,
  `tool_input.command` starting `maestrode `, resets `.direct` to 0 and touches
  `.lastcall`.
- `[code]` A second `session_id` with no sentinel gets a no-op from every hook
  (leak test: prove session B never sees session A's active flag).
- `[code]` `maestrode hook session-end` removes the session's files.
- `[behavioral]` Over a real multi-turn coding session with mode on, the banner
  appears every turn (check transcript), and `maestrode gain` (max tier) shows a
  delegate-vs-direct ratio.
- `[test]` A bats or shell test fixture drives `maestrode hook` with canned
  stdin JSON for each branch and asserts the stdout JSON and the filesystem
  side effects.

## 11. Phased steps

1. **Shim:** add `maestrode hook <event>` with the three branches and the
   session-keyed state directory. Pure stdin to stdout, no network. Add bats
   tests for every branch (this is the bulk of the testable surface and runs
   with no API key).
2. **Install:** wire the three hook entries into `settings.json`, create
   `sessions/`, extend uninstall. Re-run `./install.sh` and confirm the entries
   land once.
3. **Skill:** rewrite per 5.6. Drop footer-as-mechanism, add the subagents
   block and the hook-driven-persistence note.
4. **Docs:** CHANGELOG entry and a short README line. Personal calibration notes
   (bench numbers, tuning of the 120s window) go to `~/.claude/refs/maestrode.md`,
   not the public skill.
5. **Live check:** run a real maestrode session, confirm the banner fires every
   turn and the Task nudge fires on an Agent spawn. Tune the 120s window if the
   apply-output path nags.
