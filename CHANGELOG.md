# Changelog

## Unreleased

Installer "just works" on macOS / Linux:

- **Auto-PATH on install.** `install.sh` now appends a marked PATH export
  to the user's shell rc (`~/.zshrc`, `~/.bashrc` or `~/.bash_profile`,
  `~/.config/fish/config.fish`) so `maestrode "task"` works in a new shell
  and the Claude Code skill (which invokes `maestrode` by name) works
  without manual rc edits. Marker-guarded for idempotency.
- **Auto-clean on uninstall.** `--uninstall` strips the marked block from
  any shell rc it finds. Opt out via `MAESTRODE_NO_PATH=1` if you'd
  rather manage PATH yourself. Windows already did this; macOS / Linux
  now match.

Streaming + idle abort (the "feels hung" fix):

- **SSE streaming on the call.** Payload now sets `stream:true` with
  `stream_options.include_usage:true`. The shim pipes curl into a small
  Python parser that assembles `delta.content` / `delta.reasoning_content`
  and prints a stderr heartbeat every ~1s
  (`[maestrode streaming content=N reasoning=M]`) so you can see progress
  during long generations instead of staring at a frozen prompt.
- **Idle abort.** Curl gains `--connect-timeout 10` plus
  `--speed-time 30 --speed-limit 1`. A wedged stream now dies in ~30s
  instead of running the full `MAESTRODE_CURL_TIMEOUT` (600s). The retry
  loop treats curl exit 28 as transient and backs off, so a stuck call
  fails over fast.
- **Graceful fallback.** Parser detects non-SSE bodies (regular JSON, error
  payloads) and dumps them verbatim, so providers that ignore `stream:true`
  still work (no heartbeat, but content comes through).
- **Warmup stays non-stream.** The optional `--warmup` priming call strips
  `stream` / `stream_options` from its tiny payload so the warmup parser
  can `json.load` the response directly.

Hang fix:

- **Stdin gate hardened.** The shim's `[[ ! -t 0 ]]` check matched any
  non-tty fd, including the unix socket Claude Code's Bash tool hands
  child processes. `cat` would block on a peer that never closes, the
  harness eventually SIGKILL'd the script, the EXIT trap never fired,
  0-byte temp files and zero usage-log writes piled up. Replaced with
  `[[ -p /dev/stdin || -f /dev/stdin ]]` so cat runs only for true FIFOs
  (`echo x | maestrode`), regular files (`maestrode < file`), and
  heredocs (bash backs them with a temp file). Regression test
  reproduces the socket case via Python `socketpair`.

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
- **Higher defaults.** `MAESTRODE_MAX_TOKENS` 32768 → 65536 → 256000,
  `MAESTRODE_CURL_TIMEOUT` 300 → 600. The 256k bump was verified against
  OpenCode Zen + deepseek-v4-flash with a tiny call; lower it via env or
  `--max-tokens` if your endpoint caps shorter.
- **Parallel-dispatch pattern** documented in skill + README for
  multi-module builds (shell `&` + `wait` with per-session, per-output-dir
  calls).

Skill (so the mode stops silently fading mid-session):

- **Per-turn footer tag.** Every assistant turn ends with
  `[maestrode: delegated <files>]` or `[maestrode: direct: <reason>]`.
  Continuous self-trigger that re-instantiates the rule on every reply,
  the same mechanism that makes caveman stick.
- **State file + PreToolUse hook removed.** The earlier design wrote
  `~/.config/maestrode/active` on activation and registered a
  PreToolUse reminder hook. Sessions that ended without "maestrode off"
  (crash, /clear, terminal close) left the sentinel behind, and every
  future Claude Code session saw the reminder fire on the first
  Edit/Write, making the mode feel "on" when the user never enabled
  it. Mode now lives entirely in the conversation: skill description
  + per-turn footer tag, no global filesystem state. The installer
  removes the legacy sentinel, hook script, and `settings.json` entry
  on the next run so existing users self-heal.
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
- **Hook wiring removed; legacy cleanup added.** `install.sh` and
  `install.ps1` no longer install any PreToolUse / SessionStart hook
  (see "State file + PreToolUse hook removed" above). Every install
  and uninstall now also scrubs any prior-version hook script,
  `settings.json` entry, and `~/.config/maestrode/active` sentinel.
  `MAESTRODE_NO_HOOK` is now ignored (kept reserved); `MAESTRODE_HOOK_DIR`
  still selects the cleanup target for non-default layouts.

14 new test cases (total 37, all passing, still no network).

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
