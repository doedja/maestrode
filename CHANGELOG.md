# Changelog

## Unreleased

Feedback-loop improvements (lessons borrowed from Reasonix's Pillar 3):

- **`<<<NEEDS_SMART>>>` self-escalation.** The muscle can refuse a brief
  it judges too vague or beyond its capability by emitting
  `<<<NEEDS_SMART>>>` (optionally `<<<NEEDS_SMART: reason>>>`) as the
  first non-empty line. Shim exits **5**, prints the rationale, and skips
  session + `--files` writes so state stays clean. Pair with a `--system`
  prompt that teaches the contract.
- **Truncation diagnostic.** Detects `finish_reason=length` and unbalanced
  `<<<FILE:>>>` blocks; surfaces clear warnings to stderr. Closed blocks
  still get written so partial progress is recoverable.
- **Higher defaults.** `MAESTRODE_MAX_TOKENS` 32768 → 65536,
  `MAESTRODE_CURL_TIMEOUT` 300 → 600.
- **Parallel-dispatch pattern** documented in skill + README for
  multi-module builds (shell `&` + `wait` with per-session, per-output-dir
  calls).

Skill (so the mode stops silently fading mid-session):

- **Per-turn footer tag.** Every assistant turn ends with
  `[maestrode: delegated <files>]` or `[maestrode: direct: <reason>]`.
  Continuous self-trigger that re-instantiates the rule on every reply,
  the same mechanism that makes caveman stick.
- **State file + PreToolUse hook.** Activation touches
  `~/.config/maestrode/active`. An installer-dropped hook at
  `~/.claude/hooks/maestrode-reminder.sh` fires soft reminders on
  direct Edit/Write while the file exists. No block.
- **Slimmer body.** SKILL.md trimmed from 350 to 200 lines. Front-loaded
  the one-line delegation rule; killed the `-f` vs Read branching in
  favor of "default `-f`". Calibration detail (bench numbers, KV cache,
  pre-checks) moved to personal refs.

Install:

- **Windows native installer (`install.ps1`).** Mirrors `install.sh`,
  drops a `maestrode.cmd` shim so the command runs from cmd / PowerShell
  / Windows Terminal without opening Git Bash. Requires Git for Windows
  (`bash.exe`) and Python 3 at runtime.
- **`--uninstall` flag** on both installers (`--keep-config` to preserve
  the env file).
- **Hook wiring.** `install.sh` and `install.ps1` copy
  `hooks/maestrode-reminder.sh` to `~/.claude/hooks/` and idempotently
  patch `~/.claude/settings.json` to register the PreToolUse entry.
  Uninstall reverses both. Opt out with `MAESTRODE_NO_HOOK=1`; override
  paths with `MAESTRODE_HOOK_DIR` / `MAESTRODE_SETTINGS_FILE`.

13 new test cases (total 36, all passing, still no network).

## v0.1.0 (initial release)

First public version. 10 benchmarks of measurement, 23 unit tests, runnable quickstart.

Features:
- OpenAI-compatible Chat Completions shim (`maestrode` binary, ~300 LoC bash + embedded python3)
- Multi-file output via `<<<FILE: ...>>>` block parsing
- Multi-turn sessions at `~/.config/maestrode/sessions/<name>.json` for KV-cache reuse
- Secret-pattern scan (`sk-`, `AKIA`, GitHub PATs, private keys, etc); override with `MAESTRODE_ALLOW_SECRETS=1`
- 429 / 502 / 503 auto-retry with exponential backoff + jitter (cap 3 retries; override with `MAESTRODE_NO_RETRY=1`)
- KV-cache warmup flag (`--warmup`)
- Auto-strip of leading/trailing markdown fences and em/en dashes; bypass with `--raw`
- Reasoning-mode flags (`--reasoning-effort`, `--thinking-budget`) pass-through for compatible models
- `--dry-run` payload size estimate without network call
- `--files`, `-f`, `--session`, `--system`, `--model`, `--max-tokens`, `--full` flags

Skill (`skill/maestrode.md`): the brain-side rules for using the shim from
Claude Code (or any agent), backed by measurements from 10 benchmarks.

Examples (`examples/`): one recipe + one runnable end-to-end demo
(`quickstart.sh`).

Measured baseline: 5-7x cost reduction vs smart-model-only on spec-driven
multi-file code work.
