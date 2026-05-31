# maestrode

**Cuts your Claude usage by ~80%.** Smart model thinks, cheap model writes. Measured on real tasks, no quality loss on spec-driven work.

| your brain | Claude tokens per task | Claude usage cut |
|---|---|---|
| Claude Opus 4.7 | ~30k → ~4k | **~87%** |
| Claude Sonnet 4.7 | ~30k → ~5k | **~83%** |

If you're on a subscription tier, this means more work fits inside the same quota (or you drop a tier and stop paying for headroom you don't need). If you're on API billing, the same percentage shows up as a smaller invoice.

Claude (or any expensive frontier model) plans, reads, decides, reviews, iterates. DeepSeek V4 Flash (or any OpenAI-compatible cheap model) writes the actual file contents. A 300-line bash shim handles delegation, structured failure feedback, multi-turn sessions, multi-file output, and KV-cache reuse.

## Why I built this

I was on Claude Max 20x but never hit the ceiling. The price felt steep for headroom I wasn't using.

Claude does two jobs per turn: thinking and writing. Thinking is what frontier models are uniquely good at. Writing is interchangeable. So I wired Claude as the brain and DeepSeek V4 Flash as the muscle, benchmarked it 10 ways, and confirmed quality holds on spec-driven work. Where flash falls down, the brief was sloppy, not the model. Back on the smaller tier now, the muscle calls are basically free.

This repo is the wrapper + skill that made it work, plus the measurements.

## Quickstart

Install on macOS / Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash
```

Install on Windows (PowerShell, no admin needed):

```powershell
iwr -useb https://raw.githubusercontent.com/doedja/maestrode/main/install.ps1 | iex
```

Windows prereqs: Git for Windows (`winget install Git.Git`, provides `bash`) and Python 3 (`winget install Python.Python.3.12`). The installer drops a `maestrode.cmd` shim so the command runs from cmd / PowerShell / Windows Terminal without needing to open Git Bash.

Edit the env file with your API key:

```bash
# macOS / Linux / WSL / Git Bash
nvim ~/.config/maestrode/env
# MAESTRODE_API_KEY=sk-...
# MAESTRODE_ENDPOINT=https://api.deepseek.com/v1/chat/completions
```

```powershell
# Windows PowerShell
notepad $env:USERPROFILE\.config\maestrode\env
```

Uninstall (removes binary + config + sessions + Claude skill, and scrubs any legacy hook left over from earlier versions):

```bash
# macOS / Linux / WSL
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash -s -- --uninstall
# add --keep-config to keep ~/.config/maestrode
```

```powershell
# Windows: download then run with -Uninstall
iwr -useb https://raw.githubusercontent.com/doedja/maestrode/main/install.ps1 -OutFile install.ps1
.\install.ps1 -Uninstall
# add -KeepConfig to keep $env:USERPROFILE\.config\maestrode
```

### Use it

In Claude Code: say **`maestrode on`** or `/maestrode`. The mode stays on for the rest of the session; Claude delegates code-writing to the cheap muscle. Say `maestrode off` to drop back.

Persistence is hook-driven. The installer registers three Claude Code hooks (UserPromptSubmit, PreToolUse, SessionEnd) that key all state to `session_id`, so the mode sticks across turns without the model having to remember it, and never leaks into another session. Opt out with `MAESTRODE_NO_HOOKS=1` for conversation-only mode.

CLI direct: `maestrode "task"`. See `examples/quickstart.sh` for a 30-second runnable demo.

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

- [rtk](https://www.rtk-ai.app/) (`brew install rtk`): token-compact rewrites of `ls`, `git`, `gh`, `tree`, `read` output. Not affiliated.
- [caveman](https://github.com/JuliusBrussee/caveman) skill (Claude Code): ultra-compressed chat output to the user.

**Stack all three (rtk + caveman + maestrode)** and Claude tokens drop across every layer: shell output (rtk), chat replies (caveman), code drafting (maestrode). No config needed, the skills know how to compose.

## Feedback the shim gives you

- **`[maestrode streaming ...]`** heartbeat every ~1s while the call streams in (content + reasoning char counters). The call is wired through SSE with `--connect-timeout 10` and `--speed-time 30 --speed-limit 1`, so a wedged stream dies in ~30s instead of running the full `MAESTRODE_CURL_TIMEOUT` (600s). Retries treat the stall as transient.
- **`finish=length`** in the stderr stat line plus `response cut by max_tokens` warning when the model hit the cap. Raise `--max-tokens` (or split the brief).
- **`N <<<FILE:>>> block(s) opened but not closed`** when `--files` parsing finds a truncated response. Closed blocks still get written; reissue the missing ones.
- **Exit 5 (`NEEDS_SMART`)** when the cheap muscle decides the brief is too thin or the task exceeds its capability. Session + file writes are skipped. The brain takes over.

## Aggregate stats

Every call appends a JSONL record to `~/.config/maestrode/usage.jsonl`.

```bash
maestrode gain
```

Prints totals (tokens by kind, per-model breakdown, wall time) over the full log. No price assumptions, no settings, no model-dependent fields. You read the raw numbers and infer the brain-cost-equivalent yourself.

## Caveats

- **Cheap model hallucinates on vague briefs.** Use the smart model directly for ambiguous diagnosis, or paste the actual assertion text when iterating.
- **No streaming yet.** Responses come whole.

## License

MIT.
