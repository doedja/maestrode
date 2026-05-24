# maestrode

**Cuts your Claude bill 5-7x.** Smart model thinks, cheap model writes. Measured on real tasks, no quality loss on spec-driven work.

| spend per 100 medium coding tasks | without maestrode | with maestrode |
|---|---|---|
| Claude Opus 4.7 brain | ~$45 | ~$6 |
| Claude Sonnet 4.7 brain | ~$27 | ~$5 |

Claude (or any expensive frontier model) plans, reads, decides, reviews, iterates. DeepSeek V4 Flash (or any OpenAI-compatible cheap model) writes the actual file contents. A 300-line bash shim handles delegation, structured failure feedback, multi-turn sessions, multi-file output, and KV-cache reuse.

## Why I built this

I was on Claude Max 5x and kept brushing against the quota. Bumped up to Max 20x but never actually hit the ceiling there. The price gap felt steep for headroom I wasn't using. So I experimented.

Hypothesis: most of what Claude does turn-by-turn is writing code, not thinking about what code to write. The thinking part is what frontier models are uniquely good at. The writing part is interchangeable.

Wired up Claude as the brain (still reads, plans, reviews, runs tests) and DeepSeek V4 Flash as the muscle (writes the actual file contents). Then I benchmarked it 10 ways to make sure quality held up. It does.

Honestly the hypothesis held up better than I expected. Flash isn't worse at writing code, it just needs the brain to hand it a clearer brief. On clean spec-driven tasks (the surgical edit, the Go bugfix, the multi-file FastAPI build), flash and Opus produced near-identical code. The differences were stylistic, `Optional[str]` vs `str | None`, explicit alias vs convention. Both pass the same tests, both pass mypy strict, both ship.

Where flash falls down is exactly where the brief is sloppy. The tricky-rules test, flash got the case-sensitive scheme bug wrong because the spec didn't emphasize case. The vague brief test, flash hallucinated a bug that wasn't even there. Both cases, a structured FAIL/SUSPECT/FIX follow-up fixed it in one round. Takeaway: don't blame the cheap model. Tighten the brief first.

Back on the smaller tier now, the muscle calls are basically free. This repo is the wrapper + skill that made it work, plus the measurements.

## Quickstart

Install:

```bash
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash
```

Edit the env file with your API key:

```bash
nvim ~/.config/maestrode/env
# MAESTRODE_API_KEY=sk-...
# MAESTRODE_ENDPOINT=https://api.deepseek.com/v1/chat/completions
```

### If you use Claude Code

Drop the skill in:

```bash
mkdir -p ~/.claude/skills/maestrode
cp skill/maestrode.md ~/.claude/skills/maestrode/SKILL.md
```

Then in any Claude Code session, say **`maestrode on`** (or `/maestrode`). The skill activates and Claude starts delegating code-writing to the cheap muscle for the rest of the session.

### If you use the CLI directly

```bash
maestrode "write a function that validates an email"
./examples/quickstart.sh    # runnable end-to-end demo, ~30 seconds
```

## Where to get the cheap model

If you don't already have a key, [OpenCode Go](https://opencode.ai/go?ref=RYMKY9AQS9) is the cheapest path I've found. $10/mo gets you ~$60 of DeepSeek V4 Flash + Pro + a bunch of other open-source models (GLM, Kimi, Qwen, MiniMax). That's what I used for all 10 benchmarks. (That's my referral link, fair warning. The non-ref URL is `opencode.ai/go`.)

Or any OpenAI-compatible endpoint works:

| provider | endpoint |
|---|---|
| DeepSeek direct | `https://api.deepseek.com/v1/chat/completions` |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` |
| OpenCode Zen Go | `https://opencode.ai/zen/go/v1/chat/completions` |
| ollama (local) | `http://localhost:11434/v1/chat/completions` |

Set `MAESTRODE_API_KEY` and `MAESTRODE_ENDPOINT` in `~/.config/maestrode/env`.

## When to use what

| task shape | use |
|---|---|
| clear spec, multi-file, well-defined | maestrode (default) |
| vague brief, ambiguous diagnosis | smart model directly, skip the cheap muscle |
| cross-cutting refactor with API constraints | maestrode but review the muscle output |

## Pairs well with

[rtk](https://www.rtk-ai.app/) (`brew install rtk`): rewrites your `ls`, `git`, `gh`, `tree`, `read` commands into token-compact output. Different layer than maestrode. Stacks cleanly. Not affiliated.

## Caveats

- **Cheap model hallucinates on vague briefs.** Use the smart model directly for ambiguous diagnosis, or paste the actual assertion text when iterating.
- **No streaming yet.** Responses come whole.

## License

MIT.
