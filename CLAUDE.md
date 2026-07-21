* use `make check` (shellcheck) AND `make test` (bats) to verify changes prior to task completion
* the two read-only seams `bin/csb --here --dump-config` / `--dump-sandbox` inspect
  resolved config and the generated sandbox profile WITHOUT launching; prefer them
  (and the `test/` suite) to verify launch-path/precedence changes in-session, since
  nested sandbox-exec is impossible here
* any bash shell scripts written should be cross-platform and run on macos and linux
  under either gnu or bsd toolsets   (also fixes the "cross-plaform" typo)
