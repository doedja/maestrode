# Changelog

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
