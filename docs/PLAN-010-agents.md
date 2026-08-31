# plan 010 -- agents beyond claude (opencode, codex, gemini, ...)

Status: **PASS 1 DONE (2026-08-31). Pass 2 not started.** csb is
agent-generic with claude as the only agent; section 8's pass-1 list is
implemented, including the HOME migration, the rename sweep and the deny-floor
rider. What shipped, against that list:

- `agent` and `token_env` are axes in csb-config, and the adapter table is
  `ocaml/lib/agent.ml` -- one row, ten fields: `bin_attr`/`bin_name`,
  `token_env`, `token_hint`, `yolo_flag`, `setenv`, `config_dir`/`config_env`,
  `hosts_file`, `ns_migrate`, and the seed/credential instructions with their
  two jq expressions. `Profile.builtin` is gone: the quiet setenv layer is now
  the adapter's, applied in `Resolve` because which knobs they are is what the
  layers above decide.
- Seeding is 6b's four generic verbs (`copy`, `keychain`, `file`,
  `json_merge`), emitted as three parallel list keys per instruction and
  executed by `seed_apply` in `bin/csb`. `seed_claude_config` and the
  platform-branching `seed_credentials` are gone; `credential_is_usable` and
  `clear_seeded_credentials` run the adapter's jq expressions against
  `cred_check`.
- Two deltas from this document, both deliberate: the platform reaches
  csb-config as `CSB_PLATFORM` (the `--seed-creds` source needs it, and
  `bin/csb` already runs `uname`), and the state-dir variable is exported for
  EVERY redirected HOME, not only a namespace, so the layout inside the launch
  HOME is uniform and a seed destination can be a static relative path.
  A launch-HOME layout note follows from the second: an `-E` HOME now keeps
  claude's state under `.claude/` like a namespace does, where it used to put
  `.claude.json` at the HOME root.
- Two smaller behaviour deltas from making the merge generic: `json_merge` is a
  plain jq deep merge with the seed winning, so `projectOnboardingSeenCount` is
  normalised to 1 on every launch instead of being preserved (cosmetic -- the
  field only gates a per-project first-run notice); and the old "jq missing AND
  the project path needs escaping" refusal is gone, because the placeholder
  substitution now JSON-escapes what it inserts, so a fresh file is safe to
  write without jq whatever the worktree path holds.
- `allowed-hosts` splits with a FALLBACK rather than a clean break (section 6
  slot 6 left this to the operator): `allowed-hosts.<agent>` when it exists,
  the unsuffixed file otherwise. `templates/allowed-hosts` is now
  `templates/allowed-hosts.claude`.
- Tests: `test/agents.bats` covers the per-repo-per-agent HOME, both
  migrations, the un-adoptable unstamped dir, the deny floor and the hosts-file
  selection; `precedence.bats` and `validation.bats` cover the two new axes.
  Goldens were edited mechanically (`.csb/claudes` -> `.csb/agents`) rather
  than regenerated, since the only shape change is that rename.

Not done, and deferred to pass 2 with the agents themselves: the
opencode/`filter_egress` loopback validation rule (there is no opencode row to
validate), and per-agent `--latest`.

Decided (operator, 2026-08-27):

- Namespaces become **per-repo-per-agent** (section 6a), with a migration of
  the existing per-repo HOMEs.
- The work lands in **two passes** (section 8): pass 1 makes csb agent-generic
  with claude as the only agent -- including the HOME migration -- and pass 2
  implements the other agents on the then-clean seam.
- Agent-specific parameter selection lives in **csb-config (OCaml), not bash**
  (section 6b): bash gains a handful of generic seed verbs and keeps zero
  per-agent branches.
- Credentials stay strict (no auto-keep; profiles opt in); the claude->agent
  rename is pass-1 scope and a clean break, with `csb` keeping its name and
  expanding to "code sandbox"; pass 2 starts with opencode and re-evaluates
  from there. Section 9 records all of these.

No decisions remain open.

External facts below (paths, env vars, hosts, versions) were researched against
upstream docs and source on 2026-08-27 and will drift; anything marked
*(unverified)* or *(medium confidence)* was not confirmed against source. csb
facts were read from `bin/csb` and `ocaml/` at the tree as of the same date.

---

## 0. The question, and the answer's shape

Can csb launch other agent CLIs -- opencode (with OpenRouter or any
OPENAI_API_KEY-style provider), OpenAI's codex, Google's gemini-cli, and the
rest of the field -- with the same worktree/devShell/scrub/sandbox treatment
claude gets?

The answer: csb is already ~90% agent-agnostic. The worktree flow, devShell
resolution, env scrub, HOME redirection, read deny-list / write allow-list,
egress proxy, janitor, and the whole config/profile layer need no changes.
Every surveyed agent keeps its state under `$HOME` or the XDG dirs -- and csb's
scrub drops `XDG_*`, so they all fall back to `$HOME`-derived defaults inside
the redirected HOME. Containment is therefore free; what is claude-specific is
a small adapter surface, enumerated exactly in section 1.

The design (section 6) is an `agent=` config key selecting a per-agent adapter
with six slots, one per coupling point, with the adapter data living in
csb-config (6b) and the default HOMEs keyed per repo x agent (6a). A zero-code
stopgap exists today (section 7) and is how each agent gets validated
empirically before its adapter row is frozen. Section 8 lays out the two
passes.

## 1. Where csb is claude-specific today -- the complete inventory

Nothing outside this table cares which agent runs.

| # | coupling | where |
|---|---|---|
| 1 | binary from `$CSB_SELF#claude` (claude-code-nix overlay); `-L/--latest` re-pins that flake's upstream rev | `bin/csb:74,2202`, `flake.nix:43` |
| 2 | credential env: `CLAUDE_CODE_OAUTH_TOKEN` in `keep_vars`; `token_cmd` stdout exported into it; the no-token warning | `bin/csb:1766,1567,343` |
| 3 | `--seed-creds` source: macOS keychain item `Claude Code-credentials` / linux `~/.claude/.credentials.json` | `bin/csb:1546` |
| 4 | onboarding seed: `.claude.json` `hasCompletedOnboarding` + per-project trust, jq-merged | `bin/csb:369` |
| 5 | `CLAUDE_CONFIG_DIR` export for the redirected HOME | `bin/csb:2001-2004` |
| 6 | `yolo` resolves to `--dangerously-skip-permissions` | `ocaml/lib/resolve.ml:163-168` |
| 7 | built-in layer setenv: `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `ocaml/lib/profile.ml:79-85` |
| 8 | `templates/allowed-hosts` is the Anthropic host set | `templates/allowed-hosts` |
| 9 | cosmetic: `~/.csb/claudes`, `claude_args`, `nix_target_claude`, help text, the name csb | throughout |

Rows 1-8 are the adapter slots. Row 9 is the pass-1 rename sweep (section 9,
decisions 2-3): everything renames, claude->agent, as a clean break.

Two host-side facts that stay true for every agent, because they are properties
of the launch rather than of claude:

- The deny-list already blocks other agents' HOST state (`~/.gemini`,
  `~/.config/github-copilot` at `bin/csb:593-594`) and must keep doing so; the
  LAUNCHED agent's own state dir lives inside the redirected HOME, untouched by
  those real-HOME denies.
- The pasta uid-remap rationale on Linux ("claude refuses
  --dangerously-skip-permissions at uid 0", `bin/csb` near 1509) is
  claude-motivated but agent-neutral in effect: none of the surveyed agents
  hard-refuses root (codex, opencode, gemini all checked -- no refusal found),
  so the remap neither helps nor hurts them; it stays because file ownership
  should read as the operator's regardless.

## 2. opencode (+ OpenRouter) -- the cheapest target

Upstream moved: `sst/opencode` -> `anomalyco/opencode`; site opencode.ai, npm
`opencode-ai` (a wrapper around per-platform Bun-compiled self-contained
binaries), v1.18.x at research time. nixpkgs attr **`opencode`**, current to
within a patch release; the repo also ships an official flake.

**Auth.** An env var alone suffices -- no state file: for every provider in the
catalog, if any env var the catalog lists is set, the provider is enabled with
that key. Verified names: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, `GOOGLE_API_KEY`/`GOOGLE_GENERATIVE_AI_API_KEY`/
`GEMINI_API_KEY`, `OPENCODE_API_KEY` (their own Zen gateway). The stored-cred
path is `~/.local/share/opencode/auth.json` (0600; newer builds also have a
sqlite credential table in `opencode.db`, `OPENCODE_DB` overrides) -- seedable,
but unnecessary when the env var is injected. Note: Anthropic's ToS (rev.
2026-02-19) prohibits Claude Pro/Max OAuth tokens in third-party tools, so
opencode-against-Anthropic means an API key, not the claude session credential.

**The OPENAI_BASE_URL caveat.** `OPENAI_BASE_URL` is NOT honored. A generic
OpenAI-compatible endpoint is configured per-provider in
`~/.config/opencode/opencode.json`:

    { "provider": { "myprovider": {
        "npm": "@ai-sdk/openai-compatible",
        "options": { "baseURL": "https://.../v1", "apiKey": "{env:MY_KEY}" } } } }

`{env:VAR}` interpolation keeps the secret out of the file. csb's existing
`seed_home=` template mechanism already delivers this file. (For a tool that
DOES honor `OPENAI_API_KEY`+`OPENAI_BASE_URL` directly, see qwen-code in
section 5.)

**OpenRouter** is a built-in provider: id `openrouter`, env
`OPENROUTER_API_KEY`, base `https://openrouter.ai/api/v1`, models addressed as
`-m openrouter/<openrouter-model-id>`. The SDK is compiled into the binary --
no runtime npm install (true for all mainstream providers; only exotic ones
trigger a runtime install into `~/.cache/opencode/packages/`, the one case that
needs `registry.npmjs.org` egress).

**First run.** No trust dialog, no telemetry consent (telemetry is OTLP-only
and off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set), no root refusal, no
internal OS sandbox -- external sandboxing is its intended containment.
Non-interactive is `opencode run "..."`; the yolo analog is `--auto`
(config `"permission": "allow"` / `OPENCODE_PERMISSION` JSON also exist).

**Quiet knobs** (env-shaped, so the builtin-setenv layer pattern extends
directly): `OPENCODE_DISABLE_AUTOUPDATE=1`; `OPENCODE_DISABLE_MODELS_FETCH=1`
(the model catalog from `models.opencode.ai` has an embedded-snapshot fallback
in the binary, so blocking the host is safe when the binary is recent).

**The one structural wrinkle: loopback.** Every invocation (TUI and `run`)
starts an internal HTTP server on 127.0.0.1 at an EPHEMERAL port (default
`--port 0`), which the client side then dials. Under `--filter-egress` the
sandbox can reach only the proxy port, so opencode's own client->server connect
is denied and it breaks. Resolution: `agent=opencode` + `filter_egress` must
require or imply `allow_loopback=true` (or a pinned `--port N` +
`allow_port=N`). Unfiltered runs are unaffected (loopback TCP is open there on
both platforms). It also `mkdir -p`s data/config/state/cache/log dirs and a
`$TMPDIR/opencode` at startup -- all inside the redirected HOME and tmp write
roots, so no policy change needed.

**Egress allowlist** (`allowed-hosts.opencode`): the provider host(s) in use
(`openrouter.ai`, `api.anthropic.com`, `api.openai.com`, ...); optionally
`models.opencode.ai`. Sharing (`opncd.ai`) and update/install hosts stay off
via the knobs above; config `"share": "disabled"` exists.

## 3. codex CLI -- upstream anticipates exactly this use

`openai/codex`, Rust, near-daily releases (rust-v0.150.1 at research time).
nixpkgs attr **`codex`** builds from source and tracks within a release or two;
npm `@openai/codex` ships prebuilt binaries. Docs live at
learn.chatgpt.com/docs (developers.openai.com/codex redirects there).

**The nested-sandbox problem, and its sanctioned answer.** Codex wraps
model-generated commands in its own sandbox: `/usr/bin/sandbox-exec` (hardcoded)
on macOS -- which fails inside csb's outer seatbelt, nested seatbelt being
impossible -- and, on Linux, a bundled bwrap + in-process seccomp, which needs
nested unprivileged userns inside csb's pasta+bwrap stack (unreliable; a legacy
Landlock mode exists via `features.use_legacy_landlock`, process-scoped and
plausibly nestable, *medium confidence*). The clean move is to disable it:
`sandbox_mode = "danger-full-access"` in the seeded `config.toml`
(`approval_policy` is a separate axis and can stay strict). The one-flag yolo
combo `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`) carries
upstream help text saying it is "intended solely for running in environments
that are externally sandboxed" -- csb's exact shape, officially anticipated.
So: csb `yolo` -> codex `--dangerously-bypass-approvals-and-sandbox`, and the
seeded config carries `danger-full-access` either way.

**Auth.** `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`, plaintext
JSON) is OFFICIALLY copyable between machines -- a direct `--seed-creds`
analog, including ChatGPT-subscription sessions. Force
`cli_auth_credentials_store = "file"` in the seeded config so the OS keyring is
never touched from the sandbox HOME. Env-only: `CODEX_API_KEY` is honored by
`codex exec` and CLI subcommands but NOT the interactive TUI; bare
`OPENAI_API_KEY` does not authenticate at all (it only prefills onboarding).
So interactive codex needs a seeded auth.json; headless codex can run on
`CODEX_API_KEY` alone. OAuth login uses `auth.openai.com` with a localhost:1455
callback; `codex login --device-auth` is the headless flow.

**Custom providers / OpenRouter** via `config.toml`:

    model = "some/model-id"
    model_provider = "openrouter"
    [model_providers.openrouter]
    name = "OpenRouter"
    base_url = "https://openrouter.ai/api/v1"
    env_key = "OPENROUTER_API_KEY"
    wire_api = "chat"

ChatGPT-plan auth cannot target third-party providers; custom providers are
API-key-only.

**First run / quiet knobs are TOML-file-shaped, not env-shaped** -- the
significant asymmetry with claude and opencode. The trust prompt writes
`[projects."/abs/path"] trust_level = "trusted"` into `$CODEX_HOME/config.toml`
(trusting a subdir applies to the repo root); update check is
`check_for_update_on_startup = false` (else it dials `api.github.com` and
`formulae.brew.sh`); analytics is `[analytics] enabled = false` (else events
POST to `chatgpt.com/backend-api/...`; the default when unset is
runtime-decided, so set it explicitly). csb's jq-merge idempotence trick does
not carry to TOML; section 6 slot 4 handles this with write-if-absent.

**Headless**: `codex exec "..."` (requires a git repo unless
`--skip-git-repo-check`; `--json`, `--output-schema`, `--ephemeral`, `-c
key=value` overrides). Runtime state under `$CODEX_HOME`: sessions/,
history.jsonl, log/, sqlite DBs, version.json.

**Egress allowlist** (`allowed-hosts.codex`): `auth.openai.com` (login AND
runtime token refresh for ChatGPT-plan sessions), `chatgpt.com` (ChatGPT-plan
backend -- uses WebSockets over 443, so verify csb-proxy's CONNECT tunnel
carries the upgrade; it should, CONNECT is opaque), `api.openai.com` (API-key
mode), plus whatever `[model_providers]` names.

## 4. gemini-cli -- works, but strategically dated

The headline: at I/O 2026 Google retired gemini-cli for individuals -- on
2026-06-18 it stopped serving free-tier, AI Pro and Ultra accounts, pointing
them at the closed-source Antigravity CLI. What still works: paid
`GEMINI_API_KEY`, Vertex AI, and enterprise Gemini Code Assist licenses. The
open-source repo still publishes (npm 0.57.0 at research time); nixpkgs
**`gemini-cli`** lags ~10 minors and its meta carries a deprecation note. Rank
it below opencode and codex unless a paid-key use case exists.

Technically it is easy: a plain Node >= 20 app, no default internal sandbox
(its opt-in `GEMINI_SANDBOX` docker/podman/sandbox-exec modes must stay off
inside csb -- the scrub already drops the var; never seed `tools.sandbox`), no
root refusal found. `GEMINI_API_KEY` alone authenticates headlessly; Vertex is
`GOOGLE_GENAI_USE_VERTEXAI=true` + project/location + ADC. The OAuth cache
(`~/.gemini/oauth_creds.json` + `google_accounts.json`, plain JSON) is
copy-seedable for the surviving enterprise path -- with the caveat that newer
versions have keychain-backed storage for MCP OAuth tokens and the main login's
migration status is *(uncertain)*. First run asks exactly two things, both
pre-seedable in `~/.gemini/settings.json`:

    { "ui": { "theme": "Default" },
      "security": { "auth": { "selectedType": "gemini-api-key" } },
      "privacy": { "usageStatisticsEnabled": false },
      "general": { "enableAutoUpdate": false,
                   "enableAutoUpdateNotification": false } }

Folder trust is off by default (no dialog). Headless: `gemini -p "..."`;
yolo: `--yolo` / `--approval-mode yolo`. `GEMINI_CLI_HOME` relocates state,
though the HOME redirect already covers it. Egress: `generativelanguage.googleapis.com`
(API key), `cloudcode-pa.googleapis.com` + `oauth2.googleapis.com` +
`accounts.google.com` *(medium confidence)* (OAuth mode),
`aiplatform.googleapis.com` (Vertex); `play.googleapis.com` is Clearcut
telemetry, silenced by the settings seed; `registry.npmjs.org` is the update
check, ditto.

## 5. The rest of the field, surveyed

Every tool below has a pure-env headless auth path and a nixpkgs attr; none
changes the design -- each is one more adapter row later.

| tool | auth (headless) | state dir / relocation | yolo | nixpkgs |
|---|---|---|---|---|
| qwen-code (gemini-cli fork) | `OPENAI_API_KEY`+`OPENAI_BASE_URL`+`OPENAI_MODEL` (any OpenAI-compatible endpoint) or `DASHSCOPE_API_KEY`; free OAuth tier discontinued 2026-04-15 | `~/.qwen`, no relocation var | `qwen -p --yolo` | `qwen-code` (lags) |
| aider | provider keys via env (litellm), no login flow at all | `~/.aider` + `.aider.conf.yml`; not XDG | `--yes-always` | `aider-chat` (current; upstream stalled) |
| goose (Block / AAIF) | `GOOSE_PROVIDER`+`GOOSE_MODEL`+provider key; `GOOSE_DISABLE_KEYRING` diverts secrets to a seedable file | XDG (`~/.config/goose`, `~/.local/share/goose`) | `goose run -t`, `GOOSE_MODE=auto` | `goose-cli` (current) |
| amp (Sourcegraph) | `AMP_API_KEY` | `~/.config/amp/settings.json`, `AMP_SETTINGS_FILE` | `amp -x`, `--dangerously-allow-all`; `AMP_SKIP_UPDATE_CHECK=1`; single egress host `ampcode.com` | `amp-cli` (rolling) |
| cursor-cli | `CURSOR_API_KEY` (login token path undocumented) | `~/.cursor`, `CURSOR_CONFIG_DIR`/XDG | `-p --force` | `cursor-cli` (fresh) |
| copilot CLI | `COPILOT_GITHUB_TOKEN` > `GH_TOKEN` > `GITHUB_TOKEN` | `~/.copilot`, `COPILOT_HOME`; deliberately not XDG | `copilot -p`, `--allow-all`/`--yolo` | `github-copilot-cli` (weeks behind) |

The pattern to notice: qwen-code is the one tool that honors the generic
`OPENAI_API_KEY`/`OPENAI_BASE_URL` pair directly, which is what the original
question asked about; opencode and codex both express "custom endpoint" as a
config-file provider block with an env-named key -- a shape csb already
delivers via seeding.

## 6. The proposal: an `agent=` key and a six-slot adapter

One new axis in csb-config -- `agent=claude|opencode|codex|gemini` (CLI flag,
config-section key, profile key; default `claude`, so existing configs resolve
unchanged) -- and a per-agent adapter filling the slots of section 1:

1. **Binary.** One flake output per agent: `#opencode = pkgs.opencode`,
   `#codex = pkgs.codex`, `#gemini-cli = pkgs.gemini-cli` -- plain nixpkgs
   attrs, no overlay. The launch tail builds `$CSB_SELF#<agent output>` instead
   of the hardcoded `#claude`. `-L/--latest` is claude-flake-specific: it
   no-ops with a warning for other agents (their currency comes from bumping
   csb's nixpkgs input); generalizing it per-agent is deferred.
2. **Credential env.** Generalize `token_cmd` with a sibling `token_env=VAR`
   (default per agent: `CLAUDE_CODE_OAUTH_TOKEN`, `OPENROUTER_API_KEY` or the
   provider key for opencode, `CODEX_API_KEY`, `GEMINI_API_KEY`); the var named
   is what `run_token_cmd` exports and what joins `keep_vars`. This keeps the
   property that secrets come from a host-side command and never sit in a
   config file -- deliberately better than auto-keeping provider keys from the
   interactive shell env, which would silently forward whatever the operator
   happens to have exported.
3. **Seed-creds source.** Per-agent copy into the launch HOME: claude keychain
   / `.credentials.json` (as today); codex `~/.codex/auth.json` (officially
   sanctioned); opencode `~/.local/share/opencode/auth.json`; gemini
   `~/.gemini/oauth_creds.json` + `google_accounts.json`.
4. **Onboarding seed.** Per-agent analog of `seed_claude_config`: codex writes
   `$HOME/.codex/config.toml` (trust table for the worktree, updates/analytics
   off, `cli_auth_credentials_store = "file"`, `sandbox_mode =
   "danger-full-access"`); gemini writes `settings.json` (the section-4 seed +
   trust); opencode needs nothing. TOML has no jq, so the codex seed is
   write-if-absent -- a template-owned file, never merged -- which also matches
   how csb treats seeded HOME files generally (`--reseed` to overwrite).
5. **Yolo spelling.** `--dangerously-skip-permissions` /
   `--auto` / `--dangerously-bypass-approvals-and-sandbox` / `--yolo`.
   Stays in resolve.ml where the current mapping lives, keyed by agent.
6. **Quiet setenv + hosts.** The builtin layer's setenv becomes per-agent
   (claude keeps its two; opencode gets `OPENCODE_DISABLE_AUTOUPDATE=1` and
   `OPENCODE_DISABLE_MODELS_FETCH=1`; codex and gemini get theirs via slot 4
   instead, being file-shaped). `templates/allowed-hosts` splits into
   `allowed-hosts.<agent>` and `hosts_file` reads the one matching the resolved
   agent (`allowed-hosts` stays the claude spelling for compatibility, or is
   renamed with a fallback -- operator's call, section 9).

Plus one validation rule, same family as the existing --no-sandbox refusals:
`agent=opencode` + `filter_egress=true` without `allow_loopback` or an
`allow_port` dies with a message naming the ephemeral-port server, rather than
launching a sandbox whose agent cannot reach itself.

### 6a. Namespaces: per-repo-per-agent -- DECIDED (2026-08-27)

The default launch HOME becomes one per repo x agent:
`repo-<basename>-<hash>-<agent>` under `$CSB_NS_ROOT` (the agent suffix sits
after the hex hash, so it cannot be confused with a repo basename that happens
to end in an agent name). The alternative -- one shared HOME per repo -- would
have worked mechanically (the agents' state dirs do not collide), but separate
HOMEs keep retirement (`rm -rf <dir>`), seeding, `--reseed`, and seeded
credentials cleanly per-agent, and one agent's sessions are never readable by
another.

Migration (pass 1), two renames, both lossless `mv`s within one filesystem:

- The ROOT: when `~/.csb/agents` does not exist and the legacy `~/.csb/claudes`
  does, move the whole root (section 9, decision 2). `@NAME` dirs ride along
  unchanged.
- The DIRS: in `setup_namespace`, when the per-agent dir does not exist and
  the legacy `repo-<key>` dir does (`.csb-ns` says `kind=repo`), rename it to
  `repo-<key>-claude` and update the stamp (`kind=repo`, `agent=claude`).

Both are one-shot and idempotent by construction (the legacy path is gone after
the first launch), and the migrated HOME is byte-identical, only addressed
differently. `--list-ns` learns the new shapes; the pre-0.3 per-branch legacy
detection stays as-is.

`@NAME` shared namespaces stay agent-UNsuffixed: naming one is already an
explicit sharing decision, and an operator who wants per-agent shared HOMEs
can name `@work-codex`.

### 6b. Placement: adapter data in csb-config, generic verbs in bash -- DECIDED (2026-08-27)

The operator asked whether keeping agent-specific parameter selection in OCaml
adds friction. Answer: very little, and it is the architecturally consistent
choice -- PLAN-009 moved resolution into csb-config precisely so bash never
re-derives a knob the two could disagree about, and a bash per-agent case
statement would reintroduce exactly that two-implementations drift. Most slots
already live naturally in OCaml: the yolo spelling is in `resolve.ml` today,
the builtin setenv layer in `profile.ml`, the hosts file read in
`hosts_file.ml`, and `token_env` resolution belongs beside `token_cmd`. The
binary slot is one emitted scalar (`agent_bin_attr`) that bash splices into
`nix build "$CSB_SELF#$attr"` verbatim.

The one genuine friction point is **seeding**, because it needs runtime facts
that do not exist at csb-config time: the resolved worktree path
(`ensure_worktree` runs after config resolution, and reuse can return an
already-registered path), the launch HOME (mktemp'd for `-E`), and the macOS
keychain. So OCaml does not write files; it emits declarative seed
INSTRUCTIONS, and bash executes them with a small set of generic verbs:

    seed_copy       <host-src> -> <dest relative to launch HOME>   (0600)
    seed_keychain   <service name> -> <dest>       (macOS security -w lookup)
    seed_file       <dest> + content               (write-if-absent; --reseed overwrites)
    seed_json_merge <dest> + content               (jq deep-merge, claude's .claude.json)

Instruction content carries `${CSB_WORKTREE}` / `${CSB_HOME}` placeholders and
bash performs one generic substitution -- the same pattern `.worktreeenv`
already applies for `${HOME}`. Wire detail for implementation: emit values are
NUL-terminated so content can hold newlines; the two-field records need either
an escape for the separator or a paired-record encoding -- decide when
building, both fit the existing repeated-list-key grammar.
`seed_json_merge` must preserve `seed_claude_config`'s jq-less fallbacks
(fresh-file direct write; warn when a merge is needed without jq).

What this buys beyond consistency: agent parameter selection becomes testable
hermetically at Tier 1 (`make ocaml-test`) and through `--dump-config`,
whereas bash branches would be reachable only through launch-path tests that
cannot run nested. The costs: the emit protocol grows one record class and
`csb_config_scalars` a few entries (the existing mismatched-versions die
already guards skew), and the verb executor is new bash (~40-60 lines) -- but
it replaces `seed_claude_config` + `seed_credentials` (~90 lines today), so
`bin/csb` likely shrinks, continuing PLAN-009's direction.

**Wire seam impact.** `csb_config_scalars` gains `agent`, `token_env`, and
`agent_bin_attr`; the seed instructions ride as list-style records; the
emit/parse tables on both sides grow the same keys; `--dump-config` prints
them all.

**What does not change at all**: worktrees, `.worktreeinclude` /
`.worktreesetup.sh` / `.worktreeenv`, devShell resolution, the scrub mechanics,
deny/write/socket policy construction, the proxy and both platform wrappers,
namespaces, the janitor, profiles/config layering and clearing semantics.

## 7. The zero-code stopgap, and why to run it first

`csb -s` already runs an arbitrary command under the identical
scrub/HOME/sandbox. A profile:

    # ~/.config/csb/profiles/oc
    keep=OPENROUTER_API_KEY
    setenv=OPENCODE_DISABLE_AUTOUPDATE=1
    setenv=OPENCODE_DISABLE_MODELS_FETCH=1
    seed_home=~/.config/csb/opencode-home     # carries .config/opencode/opencode.json
    shell=true
    args=opencode

gets sandboxed opencode today, provided the binary is on the devShell PATH (add
`pkgs.opencode` to the repo devShell, or seed it into the launch HOME's `bin/`,
which the path shim prepends). What the stopgap lacks versus real support: the
yolo mapping, seed-creds, per-agent allowed-hosts selection, and `shell=true`
skipping `token_cmd` (so the key rides `keep=` from the interactive env instead
of a host-side command). That is exactly the right fidelity for validating each
agent's runtime behavior -- the loopback server under `--filter-egress`, the
codex TOML seed, gemini's auth picker -- before freezing the adapter design.
Verification stays in-session-friendly: `--dump-config` / `--dump-sandbox` show
everything but the agent's own behavior, and the stopgap launches cover that.

## 8. The two passes -- DECIDED (2026-08-27)

**Pass 1 -- genericize. Claude is the only agent; migrate the HOMEs.** No new
agent works at the end of pass 1; the win is that nothing outside one OCaml
table knows claude exists, so pass 2 adds rows instead of mechanisms.

- The `agent` axis through `ocaml/lib/{types,cli,profile,resolve,dump,emit}.ml`
  -- one field, same one-axis-one-answer structure as `runner` and `home`;
  default and only legal value `claude`. `token_env` beside `token_cmd`.
- The claude adapter row in OCaml: bin attr, token env, yolo flag, builtin
  setenv, hosts file name, and the seed instructions (today's
  `seed_claude_config` content and both `--seed-creds` sources, expressed as
  6b's verbs).
- In `bin/csb`: the generic verb executor replaces `seed_claude_config` and
  `seed_credentials`; the launch tail consumes `agent_bin_attr`;
  `run_token_cmd` exports into `$token_env`; internal names drop their claude
  spelling where they are internal-only.
- The namespace migration (6a): the root rename `~/.csb/claudes` ->
  `~/.csb/agents` plus the per-dir move to `repo-<key>-claude`, and the
  `--list-ns` update.
- The rename sweep (section 9, decisions 2-3): user-facing keys and flags go
  generic as a clean break (`nix_target_claude` -> `nix_target_agent`, etc.);
  internal names, help text, and docs follow the claude->agent rule.
- Deny-floor rider (below), since the floor list is being touched anyway (the
  root rename edits the same list).
- Tests: goldens regenerated; migration cases where suites touch namespace
  paths; the parity guard is `--dump-config` before/after equal except the new
  and renamed keys; then a real launch on both platforms (launches cannot be
  exercised from inside a csb sandbox).

Success criterion for pass 1: existing configs resolve and behave identically
modulo the namespace root/dir names and the renamed user-facing keys -- the
rename is a clean break, and an old spelling dies with the unknown-key error
whose known-keys list names the new one. Claude-specific strings in `bin/csb`
approach zero outside comments.

**Pass 2 -- implement agents.** Per agent (opencode, then codex, then gemini
on demand): one OCaml adapter row, one `allowed-hosts.<agent>` template, one
flake output, plus the opencode/filter-egress loopback validation rule and the
README section. Each agent is preceded by its stopgap validation (section
7) on the host, converting this plan's *(medium confidence)* marks into
measured facts before its row is frozen -- opencode's loopback server under
filtering, codex `--yolo` inside the outer seatbelt on macOS and inside
pasta+bwrap on Linux, gemini's seeded auth picker.

Deferred beyond both passes: per-agent `--latest` (other agents' currency
comes from bumping csb's nixpkgs input until someone misses it).

**Deny-floor rider (pass 1)**: grow the deny-list floor with the other agents'
HOST state dirs -- `~/.codex`, `~/.local/share/opencode`, `~/.copilot`,
`~/.qwen`, `~/.aider`, `~/.config/goose`, `~/.cursor` -- the same class as the
existing `~/.gemini` entry: credentials on the real HOME that no sandboxed
agent has business reading. Worth doing regardless of the rest of this plan.

## 9. Decisions -- all closed (operator, 2026-08-27)

1. **Credentials are strict: no auto-keep.** No agent auto-keeps a provider
   key from the interactive env; credentials arrive via `token_cmd`/`token_env`
   or an explicit `keep=`. A profile is the override -- an operator who wants
   the convenient behavior writes `keep=OPENROUTER_API_KEY` into one, which is
   a deliberate, per-launch-config act rather than a silent forward of whatever
   the shell happens to export.
2. **Everything renames in pass 1, mechanically: "claude" becomes "agent" --
   and `csb` keeps its name, now expanding to "code sandbox".** The tool
   sandboxes work ON CODE, whichever agent does the working, so the expansion
   stays true across every agent this plan adds (and for `csb -s`, which is
   already a sandboxed shell with no agent at all). The expansion appears in
   exactly three places, all pass-1 targets: the `bin/csb` header comment
   ("csb (claude sandbox)"), the README title, and the flake description.
   `$CSB_NS_ROOT` moves from `~/.csb/claudes` to `~/.csb/agents`; internal
   variables and help text follow the same rule. The 6a migration carries the
   root rename (one `mv` of the root, then the per-dir agent-suffix renames);
   the deny floor lists the new root -- and may list the legacy one too for
   free, since `build_deny_paths` skips nonexistent paths. One naming note for
   implementation time: each entry under the root is a launch HOME, so
   `~/.csb/homes` reads slightly truer than `~/.csb/agents` ("agents" can
   suggest binaries); pick either, the mechanics are identical -- `agents` is
   the default per the mechanical rule.
3. **User-facing keys go generic, as a clean break -- no aliases.**
   `nix_target_claude` -> `nix_target_agent`, `--nix-target-claude` ->
   `--nix-target-agent`, and the `args=` / `keep=` doc language stops saying
   "claude". An old spelling dies loudly: csb-config's unknown-key error
   already prints the known-keys list, which names the new spelling, so the
   fix is self-describing. This intentionally narrows pass 1's compatibility
   claim -- see the success criterion in section 8.
4. **Pass-2 order: opencode first, then evaluate.** codex second (biggest
   ecosystem pull, upstream-sanctioned integration), gemini on demand only;
   whether codex/gemini happen at all is re-decided after opencode lands.

## 10. Source notes

Researched 2026-08-27 via upstream docs and source: anomalyco/opencode (global
path/flag/provider/network modules), openai/codex (login storage, seatbelt and
linux-sandbox trees, model-provider-info, config reference at
learn.chatgpt.com), google-gemini/gemini-cli docs + the Antigravity transition
announcement, nixpkgs master for every attr named. Versions and hosts in this
document are snapshots of that date.
