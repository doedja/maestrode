---
name: maestrode
description: >
  Delegation mode for code work. Claude (the brain) plans, reads, decides,
  reviews, applies, runs tests, iterates. DeepSeek V4 Flash (the muscle,
  via the `maestrode` shim) drafts code, prose, configs, multi-file
  patches. Once activated, stays on for the rest of the session until
  "maestrode off". Triggers: "maestrode on", "maestrode mode",
  "use maestrode", "/maestrode", or any user request to route work
  through the cheap muscle model.
---

# maestrode mode

Brain (Claude) plans, reads, decides, reviews, applies, runs tests, iterates.
Muscle (DeepSeek flash via the `maestrode` shim) drafts the bulk of code and
prose. Stays on across the session once activated.

State: **on** after "maestrode on" / "use maestrode" / invoke this skill.
**off** after "maestrode off" / "normal mode".

## The shim

`maestrode` (binary on PATH) posts to any OpenAI-compatible Chat Completions
endpoint. Config at `~/.config/maestrode/env`. Default model `deepseek-v4-flash`.

```bash
# single shot
maestrode "task"
maestrode -f src/foo.py "extract validator"

# multi-turn (session preserves history, KV cache hits accumulate)
maestrode --session arm-b --system "Senior engineer." "first ask"
maestrode --session arm-b "follow-up"

# multi-file output
maestrode --files out/ "<brief that tells muscle to emit <<<FILE:>>> blocks>"
```

`--files DIR` parses delimited blocks from the response and writes each file:

```
<<<FILE: path/to/file.py>>>
content
<<<END FILE>>>
```

Unsafe paths (absolute or `..`) refused. Exit 4 if no blocks parsed.

## Routing rules

### Delegate to maestrode

- Code authoring: gather context (Read the relevant files), brief the task
  with paths + constraints, ask for delimited output, apply what comes back.
- Drafting: prose, configs, SQL, regex, scripts. First draft is muscle's.
- File analysis: when you would burn many Reads, gather contents and ask
  muscle to summarize / find a bug / map dependencies.
- Decomposition: hand it a goal, get a numbered plan back, execute yourself.

### Keep for the brain

- Tool calls: Read, Write, Edit, Bash. Muscle has no tools.
- Final review: spot hallucinated APIs, missing imports, wrong types.
- Risky / destructive ops: always brain judgment.
- Anything the user tells you to do yourself.

## Brief tactics (the rules that move the numbers)

### Structured failure feedback (5x reasoning reduction, measured)

For every iteration turn, format the failure as:

    FAIL: <test name>
    ASSERT: <the assertion that broke>
    GOT: <actual value>
    EXPECTED: <expected value>
    SUSPECT: <file:line range>
    FIX: <one-sentence direction>
    RETURN: <exact list of files to emit, no others>

Muscle scans the structure faster than prose. Brain maps bug-to-file in
seconds with its file tools; muscle would spend thousands of reasoning
tokens re-deriving the mapping.

### Negative-constraint block at the end of every brief

    DO NOT:
    - add new dependencies
    - touch test files
    - change files outside the listed targets
    - rewrite working logic outside the change request

Muscle gold-plating (relative imports, hand-rolled parsers, premature
abstractions) is the #1 source of self-inflicted bugs. Explicit DO NOT
suppresses it.

### Format collision (footgun)

When showing context files inline in a brief, DO NOT use a visual delimiter
that LOOKS like a delimiter but is NOT the output contract. Muscle will
mimic the wrong format and the parser will fail. Use the same `<<<FILE:>>>`
format for context too, OR markdown fenced blocks with `# file: path`.

Avoid: `----- path -----`, `### path`, `=== path ===`, custom markers.

### Few-shot example when format is critical

For format-critical work include one example in the brief showing the EXACT
output format. The example USES the actual output contract.

### Multi-round iteration is cheaper than one-shot (measured)

Splitting fixes across rounds with structured FAIL/SUSPECT/FIX feedback
beats stuffing all failures into one prompt. Session prefix is KV-cached so
later rounds are nearly free on prompt processing. Default cap: 3 rounds.
Raise to 5 if genuinely multi-step.

### Long context: tested to 13k prompt tokens

100 source files inlined work flawlessly when the SUSPECT field points at
relevant files. For codebases above ~13k prompt tokens, prefer brain-led
context selection rather than inlining everything.

### KV cache: stable prefix, changes at the end

The cache crystallizes after 2-3 requests through the same prefix. To
maximize hits:
- Use `--session NAME` for related calls
- Keep system message stable across turns
- Put stable context (file contents) early in the prompt
- Put changing instructions (failure description) at the end
- Use `--warmup` on a fresh session if the first real call is expensive

### Decompose-then-execute (optional)

For multi-file briefs add a "first emit a `<<<PLAN>>>` block, then file
blocks" instruction. The muscle articulates intent before generating code.
No measurable benefit on clear briefs; use when ambiguity is real.

## Big jobs: split + parallelize, do not one-shot

For multi-module builds (e.g. 8+ files across 3+ concerns), do not stuff
everything into one brief. The muscle hits `max_tokens` partway through,
the parser stops at the last closed `<<<END FILE>>>`, and the rest of the
work is silently missing. The shim now surfaces this as a stderr line
("response cut by max_tokens" + "N blocks opened but not closed") but
the fix is upstream: split the brief.

Pattern: one brief per concern, run in parallel with shell `&` + `wait`:

```bash
maestrode --session p-api --files build/api "<api-layer brief>" &
maestrode --session p-db  --files build/db  "<db-layer brief>"  &
maestrode --session p-web --files build/web "<web-layer brief>" &
wait
```

Each call has its own session (independent KV cache, no cross-contamination)
and its own output dir. Three parallel ~30s calls finish in ~30s wall, not
~90s; you also stay under each call's `max_tokens` budget. The brain then
reviews and stitches as usual.

Rule of thumb: if your brief asks for more than ~6 files OR more than ~15k
output tokens, split it. Default `MAESTRODE_MAX_TOKENS=65536` covers most
single-shot jobs, but timeouts grow with output size and big single-shot
calls have a long tail.

When the shim exits nonzero on one of the parallel calls, that batch's
output dir tells you exactly which concern to retry. The rest already
landed.

## Self-escalation: `<<<NEEDS_SMART>>>`

The muscle can refuse a brief it judges too vague or beyond its capability
by emitting `<<<NEEDS_SMART>>>` (optionally with a one-line reason:
`<<<NEEDS_SMART: brief omits the failing assertion text>>>`) as the FIRST
non-empty line. The shim then:

- Exits **5** (distinct from any other error code).
- Prints the rationale to stderr.
- Skips the session-log write and `--files` writes, so state stays clean.

To enable this, pass a `--system` prompt that teaches the muscle the
contract. Recommended boilerplate:

```text
If the brief is ambiguous, missing key details (failing test output,
expected behavior, target file paths), or the task clearly exceeds
your capability, emit `<<<NEEDS_SMART: <one-line reason>>>>` as the
very first line of your response and stop. Do not attempt to guess.
```

Brain-side: on exit 5, do NOT retry with the muscle. Read the rationale,
gather the missing context (run the failing test, read the suspect file,
ask the user for clarification), then either re-brief the muscle with the
gap closed or do the turn directly.

This is the cheap-model equivalent of "I do not know" and is strictly
better than hallucinated output: ~$0.001 to learn "this brief is too thin"
versus ~$0.01 + a fix round to discover the muscle invented a function.

## Vague briefs: use smart model directly, not maestrode

When the brain knows only "test X failed" without assertion text, got/
expected values, or a suspect file, DS muscles hallucinate plausible-but-
wrong root causes. The smart model with tools can run tests itself, see
the actual assertion, localize correctly.

Rule: if the brief is vague, do NOT delegate to maestrode. Use the smart
model directly. If you must delegate, paste the FULL test output for
every failing test. Test name alone is not enough.

## Caveman / compressed briefs to the muscle: do not

If you have a token-compression mode active (caveman, wenyan, etc), apply
it to **chat output only**. Briefs to the muscle stay prose-clear. Measured:
compressing the brief 50% saved 29% prompt tokens but cost 81% MORE
reasoning tokens (muscle decompresses by reasoning harder). Net tokens
and wall went UP. Same applies to structured failure feedback.

## Watch for muscle over-engineering

Muscle sometimes adds structure the spec did not require (relative imports,
__init__.py files, hand-rolled IPv6 parsing, premature indexes). When
reviewing muscle output, ask: "Did it add anything the spec did not ask
for?" If yes, scrutinize that surface first when tests fail.

## Workflow patterns

### Greenfield multi-file build

1. Write a short brief, list target files, mention the delimited-block contract.
2. Call shim with `--session <name> --files <workdir>`.
3. Skim every returned file.
4. Run the test/build command.
5. If failures, send a targeted follow-up with structured FAIL/SUSPECT/FIX feedback.
6. Cap 3 rounds. Report: files written, tests passed, anything you fixed by hand.

### Targeted patch on existing code

1. Read the file(s) yourself.
2. `maestrode -f path/to/foo.py "refactor X to Y, keep tests passing"`.
3. Apply via `Edit` so the diff stays small.
4. Re-run tests.

### Research / spec summary

1. Find candidate files (`grep`, `find`).
2. `maestrode -f a.py -f b.py "trace where X is validated; one sentence per call site"`.
3. Use the summary to decide next move.

## Iteration loop on test failures

When muscle output fails tests, do not dump the entire log. Trim to:
failing assertion line, file path, traceback head, expected vs got.

### Grader pattern (catch infra before tests)

Two-step grade:
1. **Collect step**: `pytest --collect-only -q` (or equivalent). If this
   fails, the muscle output has import/wiring bugs that mask all test
   signal. Fix that first.
2. **Run step**: only after collect is clean, run the full suite.

## Pre-checks (run BEFORE delegating)

- `MAESTRODE_API_KEY` configured.
- Pytest workspace wired: `tests/__init__.py` OR `conftest.py` with
  `sys.path.insert(0, ...)` OR `pyproject.toml` with
  `[tool.pytest.ini_options] pythonpath = ["."]`. Seed it before the muscle call.
- Frontend infra: `package.json`, `tsconfig.json`, `node_modules` in place
  if delegating frontend code.
- Test files visible to the muscle: paste exact contents in the brief or
  attach via `-f`. The shim has no tool access.
- Spec review: count files asked vs files described before sending.

## Reporting to the user

One line per turn when it matters:
`[maestrode wrote app.py + models.py + store.py; 1 fix round; pytest 9/9]`.

## Caveats

- Rate limit (429): exit 3 after auto-retry. Back off or write it yourself.
- Reasoning tokens eat budget. If `out=0` and `reason=32768`, raise `--max-tokens`.
- Truthfulness: muscle can confidently reference functions that do not
  exist. Always check against the real file.
- Reasoning-mode flags (`--reasoning-effort`, `--thinking-budget`) pass
  through to any model that supports them. Cost not worth the benefit on
  spec work; default to flash without them.

## Off-switch

When user says "maestrode off": acknowledge, stop calling the shim, resume
direct authoring. Skill goes dormant until reactivated.
