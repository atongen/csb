# user memory (seeded into the sandbox HOME)

* a transport error on a fetch may be an egress denial; check $CSB_PROXY_LOG

This file is copied to `~/.claude/CLAUDE.md` inside the sandbox so in-sandbox
claude sees your user-level instructions (the real `~/.claude` is denied and
HOME is redirected). Replace this with your own; keep it generic and free of
secrets -- everything here crosses into every sandbox that seeds this template.
