---
name: maestrode
description: >
  Delegation mode for code work. Claude (brain) plans, reads, decides,
  reviews, applies, runs tests, iterates. DeepSeek V4 Flash (muscle, via
  the `maestrode` shim) drafts code, prose, configs, multi-file patches.
  Stays on across the session until "maestrode off". Triggers: "maestrode
  on", "maestrode mode", "use maestrode", "/maestrode", or any user
  request to route work through the cheap muscle model.
---

# maestrode mode

**Default action for any code, prose, or config draft: delegate to muscle.**

    maestrode -f <files> --files out/ "<brief>"

Direct Edit / Write only for: applying muscle's output, one-line tweaks,
the user said do it yourself, or an architecture / security call the
brain must own. If your next tool call is Edit or Write and none of those
apply, you skipped a delegation.

State lives in this conversation only. **On** after "maestrode on" /
"use maestrode" / invoke this skill. **Off** after "maestrode off" /
"normal mode" / new session. There is no on-disk flag and no hook; the
mode is whatever the footer tag below says it is.

Earlier versions wrote `~/.config/maestrode/active` and ran a PreToolUse
reminder hook. That state was global and outlived sessions, so a session
that ended without "maestrode off" leaked the mode into every future
session. The installer self-heals: any prior hook entry, hook script,
and sentinel file are removed on the next `./install.sh` run.

## Required per-turn footer tag (keeps the mode live)

While maestrode is on, end every assistant turn with one of:

    [maestrode: delegated <comma-separated files written by muscle>]
    [maestrode: direct: <one-line reason>]

This is the continuous trigger. The skill description fires once when matched, then conversation churn buries it. The footer is what re-instantiates the rule on every turn, the same mechanism that makes caveman stick. Without it the mode silently fades after a few turns and brain reverts to direct Edit/Write by default.

Use `direct:` only with a real reason from the list above. "I forgot" is not a reason; if that happens, the next turn should be `delegated` to course-correct.

Skip the tag ONLY on pure-conversation turns that produced no code or prose work (a clarifying question, a one-sentence status answer). When in doubt, tag.

## The shim, in one screen

`maestrode` (binary on PATH) posts to any OpenAI-compatible Chat
Completions endpoint. Config at `~/.config/maestrode/env`. Default model
`deepseek-v4-flash`.

```bash
maestrode -f src/foo.py "extract validator"
{ echo "task:"; cat spec.md; } | maestrode
maestrode --session arm-b --system "Senior engineer." "first ask"
maestrode --files out/ "<brief that emits <<<FILE:>>> blocks>"
```

`--files DIR` parses delimited blocks and writes each file:

```
<<<FILE: path/to/file.py>>>
content
<<<END FILE>>>
```

Unsafe paths (absolute or `..`) refused. Exit codes: **3** rate limit,
**4** no blocks parsed (often format collision), **5** muscle refused
via `<<<NEEDS_SMART>>>`.

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

When user says "maestrode off": acknowledge, stop calling the shim, drop
the footer tag, resume direct authoring. Skill goes dormant until
reactivated.

## Reference

Calibration details (model picking, bench numbers, KV cache tactics,
workflow patterns, pre-checks, caveats, grader pattern, pro-as-brain
warnings) live in `~/.claude/refs/maestrode.md`. Read it when tuning
behavior or debugging muscle output; it is not loaded by default.
