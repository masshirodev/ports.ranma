# ports.ranma

A plugin for [ranma](https://github.com/masshirodev/ranma), the terminal tiling window manager: the dev servers running across panes, badged with their ports, in a screen that focuses, opens or copies each one.

## Install

With [hako](https://github.com/masshirodev/hako.ranma), in `~/.config/ranma/lua/plugins/ports.lua`:

```lua
return { "masshirodev/ports.ranma" }
```

Or by hand, as ranma loads any package under `pack/*/start/`:

```sh
git clone https://github.com/masshirodev/ports.ranma ~/.config/ranma/pack/plugins/start/ports.ranma
```

Needs: `ss` (iproute2) for `ports.verify`, and `xdg-open` or another opener for `b`. Without `ss` it still badges, and says on its screen that nothing is checked.

## What it does

```text
Every pane's screen is watched for the address a dev server prints as it
starts: `http://localhost:5173/` (Vite), `127.0.0.1:3000` (cargo, axum),
`0.0.0.0:8000` and `[::]:8000` (python -m http.server, docker), and
`listening on port 3000` (express). A pane serving one gets a badge on its
border, `▸ :5173`, taken off when its command finishes or the pane closes.
With ports.verify on, `ss -ltn` says whether each port is listening on this
machine (not which process holds it): one that is not (a server
recompiling, or one that died where no shell said so) drops its badge until
it listens again, and is forgotten once a shell is back in the foreground.

leader x p (in the pane folder), `ports` in the palette, or a click on the bar module
opens a screen of every serving pane. On it:
  enter  focus the pane      b  open the URL in the browser (ports.opener;
  y      copy the URL           over ssh it is copied instead)
  d      forget it           r  look again: every screen, and ss
  o      options
Another key: ranma.bind("x", function() ranma.emit("ports_open") end).
The bar module `ports` says how many are serving, nothing when none:
`ranma.bar { right = { "ports", "clock" } }`.

Where the shell marks its commands (OSC 133, ranma's CONFIG.md, "Hooks"), a
command finishing clears its pane, and a server restarted while its old
address is still on screen is seen again. Without the marks, press r for
that. A shell, editor or pager in the foreground (ports.ignore) is never
taken for a server, so an address `cat` or `grep` printed is not one, and
neither is one inside a connection string (`postgres://u@localhost:5432`).
Options (settings panel, "ports" group): ports.verify, ports.recheck,
ports.opener, ports.badges, ports.ignore.

ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pane
handles": watch and badge, "Timers and processes", "The bar").
```

To add it to the bar:

```lua
ranma.bar { right = { "ports", "clock" } }
```

## Binds and commands

| Key / command | |
| --- | --- |
| `leader x p` (in ranma's `pane` folder) | The screen of serving panes. |
| `ports` in the palette (`leader :`) | The same screen. |
| A click on the `ports` bar module | The same screen. |

Another key, in `init.lua` after the plugin loads:

```lua
ranma.unbind("x p")
ranma.bind("<key>", function() ranma.emit("ports_open") end, { desc = "ports", exit = true })
```

## Options

In ranma's settings panel under `ports`, or with hako's `opts` (`{ "masshirodev/ports.ranma", opts = { ... } }`), or `ranma.set { ports = { ... } }`.

| Option | Default | |
| --- | --- | --- |
| `ports.verify` | `true` | Ask ss whether each port is listening; one that is not loses its badge until it does. |
| `ports.recheck` | `10` | Seconds between two looks with ss while a pane serves something; 0 looks only when a server is found. |
| `ports.opener` | `"xdg-open"` | The command a URL is opened with (`b` on the screen); the URL is its last word. |
| `ports.badges` | `true` | Mark a serving pane's border with its ports: `▸ :5173`. |
| `ports.ignore` | shells, editors, pagers | Programs whose screen is never taken for a server: an address they show was printed by something else. |

## Costs

It follows ranma's rule that Lua never runs per frame or per byte. A watch is looked at by ranma at most every 100 ms of output, over the screen only, and calls the plugin only for a new match. `ss` runs in the background through `ranma.spawn`, every `ports.recheck` seconds and only while some pane is serving; with none, the timer is off. The bar module renders once a second and only counts a table.

## License

MIT or Apache-2.0, as ranma.
