# maestrode

**Claude Code delegation modes. Claude plans and audits, cheaper models do the drafting.** Cuts your Claude usage ~80% on spec-driven code work, no quality loss.

| your brain | Claude tokens per task | usage cut |
|---|---|---|
| Claude Opus | ~30k → ~4k | **~87%** |
| Claude Sonnet | ~30k → ~5k | **~83%** |

Claude is uniquely good at one of the two jobs per turn: thinking. Writing file contents is interchangeable. maestrode keeps Claude as the brain (plan, review, iterate) and routes the drafting to a cheap OpenAI-compatible or Anthropic-compatible model via a bash shim. A session-scoped hook keeps the mode on across turns so it never silently fades.

## Four modes

Set by what you say in Claude Code. The hook re-injects a banner each turn so the mode sticks.

| mode | brain (plans) | muscle (drafts) | Claude does | use for |
|------|---------------|-----------------|-------------|---------|
| **normal** (default) | Claude | cheap muscle | plan + audit | small / architecture-sensitive work |
| **high** | brain model | cheap muscle | audit only | routine bulk work; offload planning too |
| **ultra** | brain model | tool-calling muscle | audit + spec-test | gnarly / algorithmic work where craft matters |
| **workflow** | Claude (as a script) | cheap-tier Claude subagents | audit + spec-test | wide work: 3+ independent files/tasks, parallel |

Only **normal** spends Claude tokens on planning. **high** and **ultra** hand planning to a cheaper "brain" model too, so Claude only reviews. **ultra** adds a tool-calling muscle (the model writes files through a real `write_file` tool, not text blocks) and an independent spec-test loop for the hard tasks.

**workflow** is the odd one. It does not use the shim and does not cut Claude tokens: the muscle is cheap-tier Claude subagents (set each draft agent to haiku/sonnet) fanned out by Claude Code's built-in Workflow tool. You trade the token savings for parallel drafting and deterministic, in-harness orchestration. Use it only when the work splits into 3+ independent files or tasks; for one or two files the orchestration overhead loses, so use normal.

Models are config-driven, so it stays model-agnostic. A sensible local setup:

```bash
# ~/.config/maestrode/env
MAESTRODE_API_KEY=sk-...
MAESTRODE_MODEL=deepseek-v4-flash                                 # normal/high muscle
MAESTRODE_ENDPOINT=https://opencode.ai/zen/go/v1/chat/completions
MAESTRODE_BRAIN_MODEL=minimax-m3                                  # high/ultra planner
MAESTRODE_BRAIN_ENDPOINT=https://opencode.ai/zen/go/v1/messages
MAESTRODE_ULTRA_MODEL=kimi-k2.6                                   # ultra tool muscle
MAESTRODE_ULTRA_ENDPOINT=https://opencode.ai/zen/go/v1/chat/completions
```

Swap any model for whatever your endpoint serves. The shim auto-detects OpenAI Chat Completions vs Anthropic Messages from the endpoint path.

## Quickstart

Install on macOS / Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash
```

Install on Windows (PowerShell, no admin needed):

```powershell
iwr -useb https://raw.githubusercontent.com/doedja/maestrode/main/install.ps1 | iex
```

Windows prereqs: Git for Windows (`winget install Git.Git`, provides `bash`) and Python 3 (`winget install Python.Python.3.12`). The installer drops a `maestrode.cmd` shim so it runs from cmd / PowerShell without opening Git Bash.

Then edit `~/.config/maestrode/env` (see above) and you're set.

### Use it

In Claude Code, say **`maestrode on`** (normal), **`maestrode high`**, **`maestrode ultra`**, or **`maestrode workflow`**. The mode stays on for the rest of the session and Claude routes drafting to the muscle. Say **`maestrode off`** to drop back to direct authoring.

Persistence is hook-driven: the installer registers three Claude Code hooks (UserPromptSubmit, PreToolUse, SessionEnd) that key all state to `session_id`, so the active mode sticks across turns without the model remembering it and never leaks into another session. Opt out with `MAESTRODE_NO_HOOKS=1`.

CLI direct (any harness): `maestrode --files out/ "<brief>"`, `maestrode --ultra --files out/ "<brief>"`, `maestrode --brain "<plan request>"`.

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/doedja/maestrode/main/install.sh | bash -s -- --uninstall
# add --keep-config to keep ~/.config/maestrode
```

## Where to get the cheap models

[OpenCode Zen Go](https://opencode.ai/go?ref=RYMKY9AQS9) is the cheapest path I've found: $10/mo gets ~$60 of DeepSeek, MiniMax, Kimi, Qwen, GLM, all behind one key, on both the OpenAI and Anthropic endpoints maestrode uses. (Referral link; non-ref is `opencode.ai/go`.) Any OpenAI-compatible or Anthropic-compatible endpoint also works (DeepSeek direct, OpenRouter, ollama, the official Anthropic API).

## Aggregate stats (via ccusage)

Every muscle/brain call appends a record in [ccusage](https://github.com/ryoppippi/ccusage)'s Claude-transcript shape to `<claude>/projects/maestrode/usage.jsonl`, where `<claude>` is the first `CLAUDE_CONFIG_DIR` entry (a path ending in `/projects` normalizes to its parent) or `~/.claude`. ccusage scans that directory by default, so:

```bash
ccusage               # maestrode shows up as a `maestrode` project
ccusage --breakdown   # per-model token + cost breakdown
```

Cost comes from ccusage's bundled LiteLLM pricing keyed on the model name the provider returns (deepseek, minimax, kimi, qwen, etc. are covered; models it does not know show tokens with `$0` and a "missing pricing" flag). Override the file location with `MAESTRODE_USAGE_LOG`. Each record also carries `wall`, `files`, and `exit` keys (ignored by ccusage) for `jq` forensics, e.g. escalations are `exit:5`.

## Pairs well with

- [rtk](https://www.rtk-ai.app/) (`brew install rtk`): token-compact rewrites of `ls`, `git`, `gh`, `tree`, `read` output.
- [caveman](https://github.com/JuliusBrussee/caveman) skill: ultra-compressed chat output.

Stack all three and Claude tokens drop at every layer: shell output (rtk), chat replies (caveman), code drafting (maestrode).

## Notes

- **Cheap models hallucinate on vague briefs.** Plan first (Claude in normal, the brain model in high/ultra), then delegate the draft. Garbage plan in, garbage code out.
- **The muscle's own tests aren't a real check** (it grades its own homework). high/ultra audit with tests derived from the spec, not from the muscle's output.

## License

MIT.
