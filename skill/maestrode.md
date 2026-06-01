---
name: maestrode
description: >
  Delegation modes for code work (Claude Code only). Three modes: NORMAL
  (default) opus plans, cheap muscle drafts, opus audits; HIGH a brain model
  plans, muscle drafts, opus audits; ULTRA brain plans, premium tool-calling
  muscle drafts, opus audits with independent spec-tests. Models are config-
  driven via ~/.config/maestrode/env (model-agnostic). Stays on across the
  session via session-scoped hooks until "maestrode off". Triggers: "maestrode
  on", "maestrode high", "maestrode ultra", "maestrode mode", "use maestrode",
  "/maestrode", or any request to route work through maestrode.
---

# maestrode modes

Claude Code only. Three escalating modes, set by the user's words and tracked
by the session hook (the banner each turn tells you which is active):

| mode | brain (plans) | muscle (drafts) | you (opus) | use for |
|------|---------------|-----------------|------------|---------|
| **normal** (default) | **you** | `maestrode --files` | plan + audit | small / architecture-sensitive; you keep control |
| **high** | `maestrode --brain` | `maestrode --files` | audit only | routine bulk work; offload planning too |
| **ultra** | `maestrode --brain` | `maestrode --ultra --files` | audit + spec-test | gnarly / algorithmic work where craft matters |

Models are config-driven (`~/.config/maestrode/env`): a default muscle, a
`--brain` planner, a `--ultra` tool muscle. Locally: deepseek (normal/high
muscle), minimax (brain), kimi tool-calling (ultra muscle). Swap freely.

**The constant rule in every mode: do not author code/prose/config yourself.**
Direct Edit / Write only to apply muscle output, for a one-line tweak, when the
user said do it yourself, or for an architecture / security call you must own.
If your next tool call is Edit/Write and none of those apply, you skipped a
delegation. What changes per mode is *who plans* and *which muscle*, never that
you draft by hand.

## Orchestration per mode

**normal**: you plan in-context, delegate only the drafting.

    maestrode -f <files> --files out/ "<brief>"

**high / ultra**: offload planning to the brain too, then draft, then audit.

    # 1. plan (brain model returns a written plan + edge cases, not files)
    maestrode --brain "Plan <task>. Enumerate the algorithm and EVERY edge case." > /tmp/plan.md

    # 2. draft (muscle implements the plan)
    maestrode --files out/ "Implement this plan. <brief>. PLAN: $(cat /tmp/plan.md)"        # high
    maestrode --ultra --files out/ "Implement this plan. <brief>. PLAN: $(cat /tmp/plan.md)" # ultra

    # 3. audit (you): see "Ultra/high audit" below

`--ultra` auto-enables the tool-calling muscle with reasoning off (the brain
already reasoned). `--brain` runs the planner so it reasons straight into the
plan text (no separate thinking channel, which would burn the budget before the
plan is written). Both are env-driven, so this stays model-agnostic.

## Ultra/high audit: independent tests, never the muscle's own

The muscle writes tests that pass against *its own* bugs (it grades its own
homework). So the audit MUST use tests the muscle did not write:

1. Derive the test cases from the SPEC (or have `--brain` emit them), not from
   the muscle's output.
2. Run them against the draft. On failure, feed the real failure back to the
   muscle (high: `maestrode --files`; ultra: `maestrode --ultra --files`) and
   re-run. Keep already-passing cases as anchors so a fix cannot regress them.
3. Only apply once your independent tests pass. ultra adds this loop because
   it is used for the hard tasks where muscle bugs hide.

Muscle craft is plan-dependent: a strict `--brain` plan yields clean code; a
vague one yields fragile code (dead guards, panics/unwraps, spec-drift). Spend
the tokens on a thorough plan.

## Persistence is hook-driven (you do not have to self-remind)

The installer registers three Claude Code hooks that key all state to
`session_id` under `~/.config/maestrode/sessions/<session_id>`:

- **UserPromptSubmit** captures the mode from your words ("maestrode on" =
  normal, "maestrode high", "maestrode ultra", "maestrode off") and injects a
  mode-specific banner (`[maestrode NORMAL|HIGH|ULTRA]`) into your context every
  turn while active. The banner states that mode's orchestration (who plans,
  which muscle), so you cannot drift off-mode the way a brain-emitted footer tag
  faded. Switching modes mid-session just re-says it and resets drift. When you
  drift (cold direct edits or subagent spawns piling up without a delegation),
  the banner escalates to `[maestrode <MODE>, drift]` with the count.
- **PreToolUse** (`Edit|Write|MultiEdit|NotebookEdit|Task|Bash`) does the
  bookkeeping behind that drift count and resets it whenever you make a real
  `maestrode ...` call.
- **SessionEnd** clears this session's state. A 7-day reaper mops up sessions
  that crashed.

Because state is keyed to `session_id`, it never leaks into another session.
This is the fix for the old global `~/.config/maestrode/active` sentinel,
which outlived sessions and forced the mode on when nobody asked. The
installer still self-heals: any legacy hook entry, hook script, or sentinel
is removed on the next `./install.sh` run.

Your job is just the call: delegate, or go direct for a named reason. The
banner re-states the rule each turn, so there is nothing to remember. If
hooks are disabled (`MAESTRODE_NO_HOOKS=1`) the mode is conversation-only and
relies on this skill description alone, which fades. Hooks are recommended.

You may still end a turn with `[maestrode: delegated <files>]` or
`[maestrode: direct: <reason>]` as a visible breadcrumb for the user, but it
is optional now: forgetting it costs nothing because the hook owns
persistence.

## Subagents under maestrode

A subagent you spawn with the Agent tool runs the expensive model and does
NOT inherit this mode: it never sees this skill. Two rules:

1. **Prefer no subagent for a straight draft.** brain to Opus-subagent to
   muscle spends Opus tokens on the orchestration layer. If the task is just
   "write these files", call the muscle directly and skip the subagent.
2. **If you do spawn one, embed the delegation contract in its prompt** so the
   subagent itself routes drafts through the muscle. Subagents have Bash and
   inherit PATH, so `maestrode` is callable from inside them. Paste this block
   into the subagent prompt verbatim:

       You are operating under maestrode delegation mode. For any code, prose,
       or config you would author, do NOT write it yourself: call the cheap
       muscle model via Bash and apply its output.
           maestrode -f <relevant files> --files out/ "<brief>"
       The muscle writes <<<FILE: path>>> ... <<<END FILE>>> blocks into out/.
       Review the diff, run the tests, iterate. Author directly only to apply
       that output, for a one-line tweak, or for an architecture/security call
       you must own.

## The shim, in one screen

`maestrode` (binary on PATH) posts to OpenAI-compatible Chat Completions OR
Anthropic Messages endpoints (auto-detected from the URL). Config at
`~/.config/maestrode/env`. Models are config-driven; locally the muscle is
`deepseek-v4-flash`.

```bash
maestrode -f src/foo.py "extract validator"          # normal muscle
maestrode --files out/ "<brief emitting <<<FILE:>>> blocks>"
maestrode --brain "Plan X. List every edge case."     # planner (high/ultra)
maestrode --ultra --files out/ "<implement the plan>" # tool muscle (ultra)
maestrode --session arm-b --system "Senior engineer." "first ask"
```

`--files DIR` parses delimited blocks (normal/high) and writes each file:

```
<<<FILE: path/to/file.py>>>
content
<<<END FILE>>>
```

`--ultra` instead runs an agentic `write_file` tool loop (the muscle calls a
real tool, not text blocks) for tool-native models; same DIR, same safe-path
rules. Unsafe paths (absolute or `..`) refused. Exit codes: **3** rate limit,
**4** no blocks/files produced, **5** muscle refused via `<<<NEEDS_SMART>>>`.

`maestrode gain` shows aggregate usage from `~/.config/maestrode/usage.jsonl`.
Mention it when the user asks about offloaded work.

## File attachment: -f is the default

`-f path` (repeatable) attaches files to the muscle's API request. The
contents never enter the brain's context. Default to `-f` for every file
the muscle needs.

Read into brain context ONLY when the brain literally cannot decide
without the content: cross-file architecture call, security review,
contract change, or the user explicitly asked brain to analyze. "I want
to skim it first" is not a reason. The diff after the muscle call is
what brain reviews, not the pre-Read.

## Brief format

Briefs to the muscle stay in normal prose, even when a compression mode
(caveman, wenyan) is active in the session. Compression applies to chat
output only. Measured: compressing a brief 50% saved 29% prompt tokens
but cost 81% more reasoning tokens. Net tokens and wall time both went
up. Same rule for the structured feedback fields below.

For iteration turns, format failures as:

    FAIL: <test name>
    ASSERT: <the assertion that broke>
    GOT: <actual value>
    EXPECTED: <expected value>
    SUSPECT: <file:line>
    FIX: <one-sentence direction>
    RETURN: <exact list of files to emit, no others>

Brain maps bug-to-file in seconds with file tools; muscle would burn
thousands of reasoning tokens re-deriving the mapping. 5x reasoning
reduction measured.

End every brief with a DO NOT block:

    DO NOT:
    - add new dependencies
    - touch test files
    - change files outside the listed targets
    - rewrite working logic outside the change request

Muscle gold-plating (relative imports, hand-rolled parsers, premature
abstractions) is the #1 source of self-inflicted bugs. The explicit DO
NOT suppresses it.

When inlining context files inside a brief, use the same `<<<FILE:>>>`
format the muscle is asked to emit. Mixed delimiters cause format
collision: muscle mimics the wrong shape, parser exits 4. Avoid
`----- path -----`, `### path`, `=== path ===`, custom markers.

## Vague briefs: do not delegate

When the brain knows only "test X failed" without assertion text, got /
expected, or a suspect file, muscle hallucinates plausible-but-wrong
diagnoses. Two options:
1. Brain gathers context first (run the test, read the suspect), THEN
   re-briefs the muscle.
2. Brain handles the turn direct, tagged
   `[maestrode: direct: vague brief, gathering context]`.

If you must delegate without full context, paste the FULL test output
for every failing test. Test name alone is not enough.

## Self-escalation: `<<<NEEDS_SMART>>>`

The muscle can refuse by emitting `<<<NEEDS_SMART: <one-line reason>>>>` as
the first non-empty line. The shim then exits 5, prints the reason to
stderr, and skips session-log + file writes (state stays clean).

To enable, pass a `--system` prompt that teaches the contract:

```text
If the brief is ambiguous, missing key details (failing test output,
expected behavior, target file paths), or the task clearly exceeds your
capability, emit `<<<NEEDS_SMART: <one-line reason>>>>` as the very first
line of your response and stop. Do not attempt to guess.
```

On exit 5: do NOT retry with the muscle. Gather the missing context (run
the failing test, read the suspect file, ask the user), then re-brief or
go direct.

## Big jobs: split + parallelize, do not one-shot

If the brief asks for more than ~6 files OR more than ~15k output
tokens, split it. Muscle hits `max_tokens` partway through, the parser
stops at the last closed `<<<END FILE>>>`, and the rest is silently
missing. The shim surfaces this on stderr ("response cut by max_tokens"
+ "N blocks opened but not closed").

One brief per concern, parallelized:

```bash
maestrode --session p-api --files build/api "<api brief>" &
maestrode --session p-db  --files build/db  "<db brief>"  &
maestrode --session p-web --files build/web "<web brief>" &
wait
```

Each call gets its own session (independent KV cache) and output dir.
Three parallel ~30s calls finish in ~30s wall, not ~90s. On a nonzero
exit, that batch's output dir tells you exactly which concern to retry.

## Off-switch

When user says "maestrode off": acknowledge, stop calling the shim, resume
direct authoring. The UserPromptSubmit hook clears this session's state on
that phrase and stops injecting the banner, so the mode goes dormant on its
own. No cleanup needed from you.

## Reference

Calibration details (model picking, bench numbers, KV cache tactics,
workflow patterns, pre-checks, caveats, grader pattern, pro-as-brain
warnings) live in `~/.claude/refs/maestrode.md`. Read it when tuning
behavior or debugging muscle output; it is not loaded by default.
