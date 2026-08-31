* use `make check` (shellcheck) AND `make test` (bats) to verify changes prior to task completion
* the two read-only seams `bin/csb --here --dump-config` / `--dump-sandbox` inspect
  resolved config and the generated sandbox profile WITHOUT launching; prefer them
  (and the `test/` suite) to verify launch-path/precedence changes in-session, since
  nested sandbox-exec is impossible here
* but the dumps UNDER-REPORT when run from inside a sandbox: the builder skips paths
  it cannot stat, so already-denied paths emit no rule, and `$HOME`-relative entries
  resolve against the namespace HOME. For "is this path reachable", probe it
  (`ls -d PATH`) instead of trusting the dump. See README `--dump-sandbox`.
* any bash shell scripts written should be cross-platform and run on macos and linux
  under either gnu or bsd toolsets   (also fixes the "cross-plaform" typo)
