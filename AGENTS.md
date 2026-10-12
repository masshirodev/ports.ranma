# AGENTS.md

ports.ranma is a ranma plugin in Lua: `plugin/ports.lua` is all of it, and
its header comment is the reference that `README.md` repeats. ranma's API is
https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md (`ranma --dump-types` prints it as LuaLS annotations).

- Push to `main`.
- A change to what it does changes the header comment and `README.md` in the
  same commit, and an option goes in the README's table.
- Keep to the API of the latest ranma release, which CI loads it into: a
  newer core function makes the plugin fail to load for everyone on the
  release.
- `pane:watch` fires for a row it did not see at its last look, by the row's
  text: a restarted server printing the same line is missed unless the watch
  is re-armed (`rearm`). Do not "fix" that by scanning screens from a timer.
- Check it loads: `ranma --check-config` lists every plugin and why one failed;
  `ranma lua` runs code in the live server. Test behaviour in a private server
  (its own `RANMA_CONFIG_DIR`, `XDG_RUNTIME_DIR` and tmux socket, with
  `RANMA_SOCKET RANMA RANMA_PANE TMUX` unset), never the one you are typing in:
  `python3 -m http.server <port> --bind 127.0.0.1` in one of its panes.
  CI (`.github/workflows/ci.yml`) loads it into the latest ranma release on
  every push and fails if it does not.
- `AGENTS.local.md` (gitignored) carries what is true of one checkout on one
  machine. Never commit it.
