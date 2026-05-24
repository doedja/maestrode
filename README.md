# maestrode

**Cuts your Claude bill 5-7x.** Smart model thinks, cheap model writes. Measured on real tasks, no quality loss on spec-driven work.

| spend per 100 medium coding tasks | without maestrode | with maestrode |
|---|---|---|
| Claude Opus 4.7 brain | ~$45 | ~$6 |
| Claude Sonnet 4.6 brain | ~$27 | ~$5 |
| Claude Haiku 4.5 brain | ~$9 | ~$4 |

Claude (or any expensive frontier model) plans, reads, decides, reviews, iterates. DeepSeek V4 Flash (or any OpenAI-compatible cheap model) writes the actual file contents. A 300-line bash shim handles delegation, structured failure feedback, multi-turn sessions, multi-file output, and KV-cache reuse.

## Why I built this

I was on Claude Max 5x and kept brushing against the quota. Bumped up to Max 20x but never actually hit the ceiling there. The price gap felt steep for headroom I wasn't using. So I experimented.

Hypothesis: most of what Claude does turn-by-turn is writing code, not thinking about what code to write. The thinking part is what frontier models are uniquely good at. The writing part is interchangeable.

So I wired up Claude as the brain (it still reads, plans, reviews, runs tests) and DeepSeek V4 Flash as the muscle (writes the actual file contents). Then I benchmarked it 10 ways to make sure quality held up. It does. Back on the smaller tier, the muscle calls are basically free.

This repo is the wrapper + skill that made it work, plus the measurements.

## Side note: flash is amazing, just needs clearer direction

Honestly, this was my hypothesis going in. Flash isn't actually worse at writing code, it just needs the brain to hand it a clearer brief. After 10 benchmarks, that held up.

On clean spec-driven tasks (the surgical edit, the Go bugfix, the multi-file FastAPI build), flash and Opus produced near-identical code. The differences were stylistic. `Optional[str]` vs `str | None`. Explicit alias vs convention. Both pass the same tests, both pass mypy strict, both ship.

Where flash falls down is exactly where the brief is sloppy. The tricky-rules test, flash got the case-sensitive scheme bug wrong because the spec didn't emphasize case. The vague brief test, flash hallucinated a bug that wasn't even there. Both cases, a structured FAIL/SUSPECT/FIX follow-up fixed it in one round.

The takeaway: don't blame the cheap model. Tighten the brief first.

## Cost math

Current API rates (Anthropic, DeepSeek), 50/50 input/output split, no KV cache discount applied. Worst-case numbers for maestrode. Real-world is cheaper.

| task | smart-only | smart + maestrode | save |
|---|---|---|---|
| 30k-token task, Opus 4.7 brain | ~$0.45 | ~$0.06 | ~87% |
| 30k-token task, Sonnet 4.6 brain | ~$0.27 | ~$0.05 | ~80% |
| 30k-token task, Haiku 4.5 brain | ~$0.09 | ~$0.04 | ~62% |

A few measured highlights from the 10-bench run:

- **Structured FAIL/SUSPECT/FIX feedback cuts reasoning tokens 5x** vs unstructured "tests fail, fix them"
- **Multi-round structured iteration is cheaper than one-shot unstructured** (4x faster wall, 2x cheaper tokens)
- **DeepSeek hallucinates on vague briefs.** Paste the actual assertion text, not just "test X failed". Or use the smart model directly.

## Quickstart

One-liner install (downloads the shim to `~/.local/bin/maestrode`, seeds `~/.config/maestrode/env`):

```bash
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash
```

Then edit the env file with your API key:

```bash
nvim ~/.config/maestrode/env
# MAESTRODE_API_KEY=sk-...
# MAESTRODE_ENDPOINT=https://api.deepseek.com/v1/chat/completions
```

Use it:

```bash
# one-shot
maestrode "write a function that validates an email"

# multi-file output, the shim parses <<<FILE: ...>>> blocks and writes each
maestrode --files out/ "write 3 files: a.py, b.py, c.py. Use <<<FILE: path>>>...<<<END FILE>>>"

# attach existing files as context
maestrode -f api.py -f models.py "extract validation into a separate module"

# multi-turn session, KV cache hits accumulate across calls
maestrode --session refactor -f src/foo.py "first pass: spot redundancies"
maestrode --session refactor --files out/ "propose the refactor as <<<FILE: ...>>> blocks"

# see it work end-to-end in 30 seconds
./examples/quickstart.sh
```

## Where to get the cheap model

If you don't already have a key, [OpenCode Go](https://opencode.ai/go?ref=RYMKY9AQS9) is the cheapest path I've found. $10/mo gets you ~$60 of DeepSeek V4 Flash + Pro + a bunch of other open-source models (GLM, Kimi, Qwen, MiniMax). That's what I used for all 10 benchmarks. (That's my referral link, fair warning. The non-ref URL is `opencode.ai/go`.)

Other endpoints work too:

| provider | endpoint | notes |
|---|---|---|
| DeepSeek direct | `https://api.deepseek.com/v1/chat/completions` | pay per token |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | model = `deepseek/deepseek-chat` |
| OpenCode Zen Go | `https://opencode.ai/zen/go/v1/chat/completions` | subscription, what I use |
| ollama / lmstudio | `http://localhost:11434/v1/chat/completions` | local, free, slow |

Set `MAESTRODE_API_KEY` and `MAESTRODE_ENDPOINT` in `~/.config/maestrode/env`.

## When to use what

| task shape | use |
|---|---|
| clear spec, multi-file, well-defined | DS flash muscle + smart brain (default) |
| vague brief, need exploration | smart model directly, skip the cheap muscle |
| ambiguous diagnosis without a clear failure signal | smart model directly |
| cross-cutting refactor with API constraints | smart brain + DS muscle, watch the muscle output |

## SKILL.md for Claude Code

Drop `skill/maestrode.md` into `~/.claude/skills/maestrode/SKILL.md`. The skill teaches Claude to use the shim by default with structured failure feedback and the iteration rules.

## Pairs well with

[rtk](https://www.rtk-ai.app/) (`brew install rtk`) is a CLI proxy that rewrites your `ls`, `git`, `gh`, `tree`, `read` commands into token-compact output before they reach Claude. Different layer than maestrode (bash vs code-writing). Stacks cleanly. Not affiliated, just complementary.

## Caveats

- **Cheap model hallucinates on vague briefs.** Always include assertion text + suspect file when iterating.
- **Reasoning-mode flags** (`--reasoning-effort`, `--thinking-budget`) pass through to any model that supports them. The cost was not worth the benefit on spec work; default to flash without them.
- **Secret-scan refuses prompts** containing `sk-`, `AKIA`, `BEGIN PRIVATE KEY`, etc. Override with `MAESTRODE_ALLOW_SECRETS=1`.
- **KV cache crystallizes after 2-3 requests.** Use `--warmup` on a fresh session if the first real call is expensive.
- **Tested up to 13k prompt tokens / 100 files inlined.** Larger codebases work better with brain-led context selection.
- **429 rate limits auto-retry** up to 3 times with exponential backoff. `MAESTRODE_NO_RETRY=1` disables.
- **No streaming yet.** Responses come whole.

## License

MIT.
