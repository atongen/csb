# csb — development & install
#
# Copies (not symlinks) bin/csb into a bin dir on your PATH: the target may
# itself be under version control, so it must hold real, portable content.
#
#   make install                      # copy bin/csb into ~/bin
#   make install BIN_DIR=~/.local/bin # ...or elsewhere
#   make check                        # shellcheck the shell scripts
#   make test                         # bats suite (dump-only, fast)
#   make test-escape                  # Tier 3: real launches, run OUTSIDE csb
#   make ocaml-build                  # build csb-config + csb-proxy (dune)
#   make ocaml-test                   # the bats config tests against csb-config
#   make test-parity                  # bin/csb vs csb-config on the same argv
#   make test-proxy                   # egress-proxy tests (real proxy + curl)
#   make proxy-run                    # run csb-proxy in the foreground
#
# `check`/`build` prefer a tool already on PATH and fall back to csb's own
# devShell (nix develop), so they work with only Nix installed.

BIN_DIR ?= $(HOME)/bin
DEST    := $(BIN_DIR)/csb

# Flake ref csb pulls the claude binary from; mirrors bin/csb's CSB_SELF default.
# Override to refresh a different remote: make refresh CSB_SELF=path:/path/to/csb
CSB_SELF ?= git+ssh://git@git.grandrew.com/atongen/csb.git

.DEFAULT_GOAL := help
.PHONY: help install uninstall check test test-escape test-update test-proxy test-parity \
        build update refresh ocaml-build ocaml-test proxy-run

# The OCaml config-resolution layer (docs/PLAN-008-proxy.md s9).
OCAML_DIR  := ocaml
CSB_CONFIG := $(OCAML_DIR)/_build/default/bin/csb_config_cli.exe
CSB_PROXY  := $(OCAML_DIR)/_build/default/bin/csb_proxy_cli.exe
# Egress allowlist csb-proxy serves; override to test a different set:
#   make proxy-run PROXY_ALLOW=/tmp/my-hosts
PROXY_ALLOW ?= templates/allowed-hosts
# Decision log csb-proxy also writes (stderr keeps streaming either way). A path
# the SANDBOX can read, so a denied fetch is self-diagnosable rather than an
# opaque transport error -- see docs/PLAN-008-proxy.md s7 item 4.
# TMPDIR may or may not carry a trailing slash; normalize either form.
PROXY_LOG ?= $(patsubst %/,%,$(or $(TMPDIR),/tmp))/csb-proxy.log

help: ## Show this help
	@echo "csb — targets (override BIN_DIR to change the install location):"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Copy bin/csb into BIN_DIR (default ~/bin)
	@mkdir -p "$(BIN_DIR)"
	@rm -f "$(DEST)"        # clear any pre-existing symlink
	@cp bin/csb "$(DEST)"
	@chmod +x "$(DEST)"
	@echo "install: copied -> $(DEST)"
	@case ":$$PATH:" in \
		*":$(BIN_DIR):"*) ;; \
		*) echo "install: note — $(BIN_DIR) is not on your PATH" >&2 ;; \
	esac

uninstall: ## Remove csb from BIN_DIR
	@rm -f "$(DEST)"
	@echo "uninstall: removed $(DEST)"

SHELLSCRIPTS := bin/csb templates/home/.claude/statusline.sh

check: ## Lint the shell scripts with shellcheck
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELLSCRIPTS); \
	else \
		nix develop --command shellcheck $(SHELLSCRIPTS); \
	fi
	@echo "check: shellcheck clean"

test: ## Run the bats test suite (test/)
	@if command -v bats >/dev/null 2>&1; then \
		bats test/; \
	else \
		nix develop --command bats test/; \
	fi

test-escape: ## Tier 3: real launches asserting the PLAN-007 escapes stay closed
	@echo "test-escape: real launches (needs nix + network); run OUTSIDE csb"
	@if command -v bats >/dev/null 2>&1; then \
		bats test/escape/; \
	else \
		nix develop --command bats test/escape/; \
	fi

test-update: ## Regenerate the Tier 2 snapshot goldens for THIS platform
	@if command -v bats >/dev/null 2>&1; then \
		SNAPSHOT_UPDATE=1 bats test/; \
	else \
		nix develop --command env SNAPSHOT_UPDATE=1 bats test/; \
	fi
	@echo "test-update: regenerated test/snapshots/$$(uname -s | tr 'A-Z' 'a-z')/ - review the diff"

ocaml-build: ## Build csb-config + csb-proxy (dune, ocaml/)
	@if command -v dune >/dev/null 2>&1; then \
		dune build --root $(OCAML_DIR); \
	else \
		nix develop --command dune build --root $(OCAML_DIR); \
	fi
	@echo "ocaml-build: $(CSB_CONFIG)" >&2
	@echo "ocaml-build: $(CSB_PROXY)" >&2

proxy-run: ocaml-build ## Run csb-proxy in the foreground (port on stdout, decisions on stderr)
	@echo "proxy-run: allowlist $(PROXY_ALLOW); the first line below is the port. Ctrl-C to stop." >&2
	@echo "proxy-run: decisions also logged to $(PROXY_LOG)" >&2
	@echo "proxy-run: then, in another terminal:" >&2
	@echo "  export HTTPS_PROXY=http://127.0.0.1:<port> NO_PROXY=localhost,127.0.0.1" >&2
	@echo "  claude --debug        # /status should show the Proxy row" >&2
	@exec $(CSB_PROXY) "$(PROXY_ALLOW)" --log-file "$(PROXY_LOG)"

test-proxy: ocaml-build ## Egress-proxy tests (real proxy + curl; not in `make test`)
	@if command -v bats >/dev/null 2>&1; then \
		bats test/proxy/; \
	else \
		nix develop --command bats test/proxy/; \
	fi

# Every Tier-1 test that reaches csb only through --dump-config. The
# dump-sandbox tag marks the rest: those need the profile generator, which
# lives in bin/csb.
OCAML_ORACLE := --filter-tags '!dump-sandbox' test/precedence.bats test/lists.bats test/validation.bats

ocaml-test: ocaml-build ## Config-layer oracle: the bats config tests against csb-config
	@if command -v bats >/dev/null 2>&1; then \
		CSB=$(CSB_CONFIG) bats $(OCAML_ORACLE); \
	else \
		nix develop --command env CSB=$(CSB_CONFIG) bats $(OCAML_ORACLE); \
	fi

test-parity: ocaml-build ## Differential oracle: bin/csb vs csb-config on the same argv
	@if command -v bats >/dev/null 2>&1; then \
		bats test/parity/; \
	else \
		nix develop --command bats test/parity/; \
	fi

build: ## Build the csb package from the flake (nix build .#csb)
	@nix build .#csb
	@echo "build: ./result/bin/csb"

update: ## Re-pin claude-code to its latest upstream in flake.lock
	@nix flake update claude-code
	@echo "update: claude-code re-pinned in flake.lock - review & commit it"

refresh: ## Re-fetch CSB_SELF so --latest stops diffing against a stale flake cache
	@nix flake metadata "$(CSB_SELF)" --refresh >/dev/null
	@echo "refresh: re-fetched $(CSB_SELF)"
