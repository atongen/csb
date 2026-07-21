# plan 005

Status: steps 1-2 implemented (the `--dump-config`/`--dump-sandbox` seams +
`CSB_BWRAP_BIN`, and the Tier 1 bats suite under `test/` wired to `make test`).
Steps 3 (Tier 2 snapshot goldens) and 4 (`docs/SMOKE.md` + `make smoke`) remain
proposed.

## A test suite for csb

`bin/csb` is ~1700 lines of bash that has grown a lot: layered flag/profile/env
precedence, per-platform sandbox-profile generation (seatbelt and bwrap), git
worktree management, env scrubbing, and HOME redirection. The failure mode we
are guarding against is the *silent regression*: a refactor drops or reorders a
sandbox rule, or breaks a precedence rule, and the script still runs, still
passes `make check` (shellcheck), and nobody notices until a secret leaks or a
launch misbehaves. shellcheck catches syntax and a class of bugs; it cannot
catch "this profile no longer denies `~/.ssh`" or "`--no-paranoid` stopped
overriding a profile's `paranoid=true`".

The hard constraint that shapes everything below: **the guarantee that actually
matters -- that seatbelt/bwrap *enforces* the generated profile -- cannot be
tested automatically.** `sandbox-exec` will not nest, so enforcement cannot be
exercised from inside a csb session or a CI sandbox; it needs a real host with
real privileges (see docs/PARANOID.md). So we do not chase one monolithic
"test suite". We split by what is automatable, and we are honest about the seam
between "the profile text is correct" (testable) and "the OS enforces it"
(not automatable, must be a human checklist).

## The three tiers

1. **Black-box logic tests (bats).** Automatable, cheap, high value. Assert on
   csb's resolved *decisions* and its validation/error behavior by running the
   real binary as a subprocess. Catches precedence and validation regressions.
2. **Sandbox-spec snapshot tests (bats + golden files).** Automatable, guards
   the scariest regression class -- a dropped or reordered deny/allow rule in
   the generated profile. Requires a small read-only dry-run seam in csb.
3. **Enforcement smoke checklist (manual, on-host).** Not automatable. The
   read/write/sibling probes we run by hand, formalized as a documented,
   repeatable checklist run outside csb on each platform before a release.

Tiers 1 and 2 share one enabling idea: **read-only dry-run seams** that let a
test observe what csb decided without launching anything.

## Enabling seams: two dry-run flags

Both are read-only, both exit 0 before any launch, credential seeding, or
`token_cmd` execution, and both are useful to a human debugging a config. They
add no security surface: they never print secrets (a `token_cmd` is reported as
present/absent, never run; seeded credentials are never touched).

### `--dump-config`

Resolves flags + profile (+ `.local`) + env to final values and prints them as
stable `KEY=VALUE` lines, then exits. This is the seam for Tier 1: it exposes
every knob directly, including scalars that never appear in a sandbox profile
(`yolo`, `latest`, `accent`, `args`, keeps). Sketch of the output:

```
mode=launch
here=true
paranoid=false
yolo=false
latest=false
namespace=@work
ephemeral=false
seed_creds=false
accent=magenta
token_cmd=present            # never the value
claude_args=--model|opus     # delimited, never shell-eval'd
keep=COLORTERM|DIRENV_LOG_FORMAT
deny_read=/Users/x/notes
allow_write=/Users/x/scratch
paranoid_deny_read=
paranoid_allow_read=
```

Emitted after `load_profile` and all precedence resolution, so a test sees
exactly what a real launch would use. No worktree, namespace dir, or nix build
is required for `--dump-config` -- it prints and exits before any of that.

### `--dump-sandbox`

Runs the real resolution path far enough to call `build_deny_wrapper`, then
prints the generated artifact -- the seatbelt profile text on macOS, the `bwrap`
argv (one token per line) on Linux -- and exits before launch. This is the seam
for Tier 2, and it deliberately exercises `build_deny_paths`,
`build_write_roots`, and `build_deny_wrapper` including their validations, so
Tier 1's build-time error cases (quote/backslash rejection, the
`paranoid_allow_read` overlap check) are reachable through it too.

Notes and caveats:
- To keep it faithful without provisioning a worktree, tests drive it with
  `--here` inside a throwaway git repo: `--here` uses the current dir as the
  worktree and derives the namespace from HEAD, so no `.worktrees/` checkout is
  created.
- On Linux, `build_deny_wrapper` resolves the `bwrap` binary via
  `nix build "$CSB_SELF#bwrap"`. To keep Linux dumps/tests hermetic and give
  the snapshot a stable path, add an optional `CSB_BWRAP_BIN` override: if set,
  csb uses it verbatim instead of building. Tests set it to a placeholder; the
  Linux code path is otherwise unchanged.
- `--dump-sandbox` must not run `.worktreesetup.sh` (unlike `-n/--no-launch`),
  seed credentials, or run `token_cmd`. It resolves, prints, exits.

## Tier 1 -- black-box logic tests

### Harness

- Tests live under `test/` as `*.bats`. A shared `test/helpers.bash` provides
  `setup`/`teardown` that create a temp dir and point `HOME` and
  `XDG_CONFIG_HOME` at it, plus a `fake_repo` helper that `git init`s a temp
  repo, makes one commit, and checks out a branch (so `--here` works). All csb
  runs use this isolated HOME, so nothing touches the real `~/.config/csb` or
  `~/.csb/claudes`.
- Assertions use `bats-assert`/`bats-support` (in nixpkgs) for readable
  `assert_output`, `assert_line`, `assert_failure`.
- Every case runs `csb ... --dump-config` (or `--dump-sandbox` for build-time
  validations) so nothing launches.

### Cases

Precedence (the `*_cli` tracking is subtle and easy to break):
- `--paranoid` beats profile `paranoid=false`; `--no-paranoid` beats profile
  `paranoid=true`.
- `CSB_LATEST=1` defaults latest on; `--no-latest` overrides it; `-L` overrides
  a profile `latest=false`.
- `CSB_VERBOSE` vs `--no-verbose`, same shape.
- `--ns NAME` beats profile `ns=`; `--no-ns` clears a profile `ns=`.
- profile `.local` overlay: a scalar in `.local` wins over the base; list keys
  (`keep`, `setenv`, `deny_read`, `allow_write`, `paranoid_deny_read`,
  `paranoid_allow_read`) accumulate base + `.local`.
- `-- ARGS` on the CLI replaces a profile `args=`.
- bare `-p NAME` (no BRANCH) resolves to `--here` launch mode; `--no-here` or a
  profile `here=false` suppresses it.

Lists and normalization:
- each of the four lists accumulates from CLI flags, from profile vars, and from
  both together, in the right final set.
- a relative path to any of `--deny-read`, `--allow-write`,
  `--paranoid-deny-read`, `--paranoid-allow-read` (and their profile keys) dies
  with a clear message; a leading `~/` expands to `$HOME`.

Validation / die paths (all should exit non-zero with a specific message):
- empty value to `--ns` / `--seed-home` / `--accent`.
- mutually exclusive: `--ns` + `-E`; `--here` + BRANCH; profile `ns=` +
  `ephemeral=true`.
- unknown CLI flag; unknown profile key; a profile bool key with a non-bool
  value.
- `CSB_TMPDIR` pointing at a nonexistent dir.
- (via `--dump-sandbox`) a path containing `"` or `\` is refused; a
  `--paranoid-allow-read` that overlaps a deny root (floor, `deny_read`, or
  `paranoid_deny_read`) is refused, while a non-overlapping one is accepted.

Path helpers (`paths_overlap`, `normalize_list_path`) are covered indirectly
here (overlap rejection exercises `paths_overlap`; the relative-path die
exercises `normalize_list_path`). Direct unit tests of these are deferred to the
refactor below.

## Tier 2 -- sandbox-spec snapshot tests

### Mechanism

For a fixed set of inputs, run `csb ... --dump-sandbox`, pass the output through
a normalizer, and compare against a committed golden file under
`test/snapshots/`. A mismatch fails the test and prints a diff; an intentional
change is accepted by regenerating goldens (`make test-update`, or
`SNAPSHOT_UPDATE=1 make test`). The value is that a diff makes *every* change to
the generated profile visible and reviewable -- reordering the floor deny below
a re-allow, dropping the namespace read re-allow, widening a write root -- the
exact regressions shellcheck and a human skim miss.

### Normalization

The raw dump contains volatile, host-specific strings that must be replaced with
stable placeholders before comparison, or every run diffs:
- realpath'd `$HOME` -> `<HOME>`
- the throwaway repo path -> `<REPO>`
- `$TMPDIR` and the macOS `/var/folders/...` per-user dir -> `<TMP>`
- the namespace dir under `~/.csb/claudes/...` -> `<NS>`
- the nix-store `bwrap` path (Linux) -> `<BWRAP>` (pinned via `CSB_BWRAP_BIN`)

The normalizer is a small `sed` pass in `test/helpers.bash`, fed the concrete
values the harness already knows (it created HOME, the repo, and TMPDIR).

### Matrix (representative, per platform)

- normal mode, `--here`, a branch-derived namespace (the baseline)
- `--paranoid`
- `--paranoid --paranoid-allow-read <dir>` (asserts the read re-allow lands
  after the HOME deny, read-only, with ancestor metadata on macOS)
- `--paranoid --paranoid-deny-read <dir>`
- `--deny-read <p> --allow-write <p>` in normal mode
- `-E` ephemeral (no namespace)
- an `@unscoped` namespace

### Platform handling

`--dump-sandbox` emits seatbelt text on macOS and bwrap argv on Linux, so
goldens are per-platform (`test/snapshots/darwin/`, `test/snapshots/linux/`).
A test skips (bats `skip`) the branch that does not match `uname -s`. Full
coverage therefore needs both a macOS and a Linux runner; the flake already
builds on `aarch64-darwin` and NixOS, so CI can run both. See "Wiring" for the
`nix flake check` vs `make test` split (the Linux bwrap build complicates the
former).

## Tier 3 -- enforcement smoke checklist (manual, on-host)

The only thing that proves the guarantee is running the probes against a real
kernel-enforced sandbox. This cannot be automated in CI or run inside csb, so it
is a documented checklist: `docs/SMOKE.md`, with an optional `make smoke` that
prints it (and refuses to run if it detects it is already inside a csb session,
e.g. via the `CSB_MODE`/`CSB_NS` env markers csb sets in the launched process).

Each probe is run outside csb, on the host, once per platform before a release:
- under `--paranoid --paranoid-allow-read <dir>`: the dir and its nested
  subtree are readable; a write into it is denied; a sibling real-HOME path
  (`~/.ssh`, `~/.zshrc`) is denied. (This is exactly what we verified by hand
  for this feature.)
- `--deny-read <p>` hides `<p>` in normal mode.
- `--allow-write <p>` makes `<p>` writable, and readable under `--paranoid`.
- a `--paranoid-allow-read` overlapping a deny aborts before launch.
- the macOS keychain caveat probe already documented in the README
  (`security find-generic-password ...` fails closed in-sandbox).

`docs/SMOKE.md` records, per probe, the exact command and the expected result,
so the checklist is mechanical rather than from-memory.

## Wiring

- **devShell (flake.nix):** add `bats`, `bats-support`, `bats-assert` from
  nixpkgs to the csb devShell so `make test` works out of the box. Verify
  availability: `nix eval nixpkgs#bats.name`.
- **Makefile:** `test` (run `bats test/`), `test-update` (regenerate goldens),
  `smoke` (print/guard the manual checklist). Keep `check` (shellcheck) as-is;
  `test` depends on nothing that `check` does not already assume.
- **flake checks:** expose `checks.test`. Caveat: a `nix flake check` runs
  hermetically, and the Linux `--dump-sandbox` path wants a `bwrap` binary --
  building it inside a check is nested nix. Resolution: Tier 1 (`--dump-config`,
  no bwrap) and the macOS snapshots run fine under `nix flake check`; Linux
  snapshots either run via `make test` in the devShell, or use `CSB_BWRAP_BIN`
  pointed at the already-built `.#bwrap` output so the check does no nested
  build. Pick this when implementing.
- **CI:** a GitHub Actions matrix (macOS + Ubuntu), install Nix, `nix develop
  --command make check test`. Aspirational until the repo is published
  (`CSB_SELF` still needs a reachable ref; see PLAN-004 / TODO), but the plan
  targets it.

## Implementation order

1. Add `--dump-config` and `--dump-sandbox` (with `CSB_BWRAP_BIN`), plus
   `--help` and README entries. Smallest, unblocks everything.
2. Tier 1 harness (`test/helpers.bash`, `fake_repo`) + the precedence,
   list, and validation cases. Add `make test` and devShell bats.
3. Tier 2 normalizer + goldens for the matrix on the dev platform; wire
   `checks.test`; add the second-platform goldens when a runner is available.
4. `docs/SMOKE.md` + `make smoke`; run it once per platform to seed the
   expected results.

Ship 1--2 first; that alone converts the highest-risk regression classes
(precedence, validation) from invisible to caught. 3 adds the profile-drift
guard. 4 formalizes what is already a manual habit.

## Deferred (future): unit-test refactor for in-process function tests

Everything above is black-box -- it runs `bin/csb` as a subprocess. That is
deliberate (it tests the real code path and needs no structural change), but it
cannot call an internal function in isolation, because the script is not
sourceable: top-level execution (the `while [[ $# -gt 0 ]]` arg loop at
`bin/csb:1224`, the `load_profile` call, the launch flow) is interleaved with
the function definitions, so `source bin/csb` runs the whole thing. Verified:

```
grep -nE 'BASH_SOURCE|\[\[ "\$\{BASH_SOURCE' bin/csb   # -> no source guard
```

The future refactor: hoist all top-level execution into a `main()` and end the
file with

```
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

so `source bin/csb` yields functions only. Then bats can call
`normalize_list_path`, `paths_overlap`, `build_deny_paths`, `build_write_roots`,
and `build_deny_wrapper` directly with crafted globals and assert on their
outputs -- faster, finer-grained, and no throwaway git repo needed.

Why deferred, not now:
- The black-box suite must exist first, so the refactor itself is done under a
  safety net (the whole point is not to regress silently while restructuring the
  launch flow).
- `build_deny_wrapper` writes to a `mktemp`, sets a global, and installs an EXIT
  trap; testing it in-process needs care (or a further split of "compute the
  profile text" from "write it and set the wrapper argv"). That split is a
  reasonable follow-on but is more than a mechanical hoist.

This is tracked as a future item; the plan above delivers full value without it.

## Risks and limitations

- **Snapshot noise / rubber-stamping.** Golden tests fail on every intentional
  profile change, and `make test-update` makes it easy to accept a diff without
  reading it. Mitigation: keep the matrix small and the normalized output
  readable, and treat a snapshot diff in review as a real change to scrutinize.
- **False confidence.** Green Tier 1/2 means "csb decided correctly and emitted
  the right text", not "the OS enforced it". A new macOS release could change
  seatbelt semantics with the profile text unchanged. Tier 3 is the only guard
  against that, and it is manual -- SMOKE.md must actually be run.
- **Platform coverage.** Without a Linux runner, Linux goldens and smoke go
  stale. Until CI exists, note in SMOKE.md which platform each golden was last
  regenerated on.
- **Two new debug flags are surface.** `--dump-config`/`--dump-sandbox` are
  read-only and secret-free by construction, but they must stay that way -- any
  future field added to the dump must be checked against leaking a secret.
