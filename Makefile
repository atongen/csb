# csb — development & install
#
# Copies (not symlinks) bin/csb into a bin dir on your PATH: the target may
# itself be under version control, so it must hold real, portable content.
#
#   make install                      # copy bin/csb into ~/bin
#   make install BIN_DIR=~/.local/bin # ...or elsewhere
#   make check                        # shellcheck the shell scripts
#
# `check`/`build` prefer a tool already on PATH and fall back to csb's own
# devShell (nix develop), so they work with only Nix installed.

BIN_DIR ?= $(HOME)/bin
DEST    := $(BIN_DIR)/csb

# Flake ref csb pulls the claude binary from; mirrors bin/csb's CSB_SELF default.
# Override to refresh a different remote: make refresh CSB_SELF=path:/path/to/csb
CSB_SELF ?= git+ssh://git@git.grandrew.com/atongen/csb.git

.DEFAULT_GOAL := help
.PHONY: help install uninstall check build update refresh

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

build: ## Build the csb package from the flake (nix build .#csb)
	@nix build .#csb
	@echo "build: ./result/bin/csb"

update: ## Re-pin claude-code to its latest upstream in flake.lock
	@nix flake update claude-code
	@echo "update: claude-code re-pinned in flake.lock - review & commit it"

refresh: ## Re-fetch CSB_SELF so --latest stops diffing against a stale flake cache
	@nix flake metadata "$(CSB_SELF)" --refresh >/dev/null
	@echo "refresh: re-fetched $(CSB_SELF)"
