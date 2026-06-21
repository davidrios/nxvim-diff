# nxvim-diff

A Meld-style **side-by-side diff viewer** for
[nxvim](https://github.com/davidrios/nxvim) — two (or three) panes locked together,
changed/added/removed lines tinted, aligned with filler rows, navigable hunk-by-hunk.

It is built entirely on the native `nx.*` plugin API (ADR 0002): the read-only sides
are [`nx.view`](https://github.com/davidrios/nxvim) surfaces, every tint / filler /
intra-line span is an extmark, and the panes stay in lockstep through the editor's
`WinScrolled` event plus `nx.win.set_topline` / `set_leftcol` / `set_cursor`.

It's a **renderer you feed a diff to**, not a git tool. The core knows how to render
and navigate a diff; *where the sides come from* is the caller's business. So there are
only two commands — the long tail lives in the Lua API, where it belongs.

```
 HEAD — src/app.rs                │ working tree
 1  fn main() {                   │ 1  fn main() {
 2      let x = compute();        │ 2      let x = compute();
~3      println!("{}", x);        │~3      eprintln!("{}", x);
 4  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄  │+4      log::info!("done");
 5  }                             │ 5  }
```

## Status

This repo is a **scaffold with a working, tested core**. Implemented and covered by
`nxvim --test-plugin .`:

- the configuration (`config.lua`) — merge + validation,
- the pure LCS **diff engine** (`diff.lua`) — alignment, hunks, per-pane projection,
- the pure **conflict-marker parser** (`conflict.lua`) — diff3 / plain-merge → sides,
- the **public API** — `open`, `validate_spec`, and the git HEAD-spec helpers.

Two-pane **rendering works** (Phase 2): a diff opens side-by-side in a dedicated tab,
projected to equal height with alignment fillers and DiffAdd/DiffDelete/DiffChange
tints. Still building out (see
[`docs/plans/2026-06-20-nxvim-diff.md`](docs/plans/2026-06-20-nxvim-diff.md)): live
scroll/cursor **sync** (Phase 3), intra-line `DiffText` + hunk signs (Phase 4), and the
**3-way** layout for diff3 conflicts (Phase 6) — a 3-pane spec fails loud until then.

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-diff",
    config = function()
      require("nxvim-diff").setup({})
    end,
  },
})
```

Then run `:PluginSync`.

## Commands

There are exactly two — by design:

```
:NxDiffGit        diff the current file's working tree against git HEAD
:NxDiffConflict   if the current file has conflict markers, open them as a 3-way diff
```

`:NxDiffConflict` parses the file's `<<<<<<< / ||||||| / ======= / >>>>>>>` markers: a
diff3-style file (base section present) opens as a true 3-way, a plain-merge file as a
2-way ours/theirs.

Inside a diff (default, buffer-local bindings):

| Key | Action |
| --- | --- |
| `]c` / `[c` | next / previous changed hunk |
| `]C` / `[C` | last / first hunk |
| `R` | refresh |
| `q` | close |

## Extending — the Lua API

Everything beyond the two commands is the Lua API. To "send a diff for preview" from
any plugin (git, LSP rename, formatter, …), build a spec and call `open`:

```lua
require("nxvim-diff").open({
  title = "my preview",
  panes = {
    { label = "before", lines = old_lines, filetype = "lua", readonly = true },
    { label = "after",  buf = 0,           readonly = false }, -- or path = "/abs/file"
  },
})
```

A pane carries **exactly one** content source — `lines` (an array), `buf` (a bufnr),
or `path` (an absolute path) — plus optional `label`, `filetype`, and `readonly`
(default `true`). `validate_spec` enforces the shape and fails loud.

The bundled git/conflict support are themselves clients of this API, so they double as
worked examples:

```lua
local diff = require("nxvim-diff")
diff.git_head()   -- current file vs HEAD (what :NxDiffGit calls)
diff.conflict()   -- parse this buffer's conflict markers (what :NxDiffConflict calls)
diff.close()
```

For a richer git comparison than HEAD (an arbitrary rev, the index, `rev..rev`), build
the spec yourself — `require("nxvim-diff.git").to_lines(...)` is handy — and `open()`
it. That's intentionally Lua, not a forest of command flags.

## Configuration

`setup()` takes (defaults shown):

```lua
require("nxvim-diff").setup({
  sync_scroll = true,    -- lock the panes' viewports together (uses WinScrolled)
  sync_cursor = true,    -- keep the panes' cursor row aligned
  wrap = false,          -- soft-wrap inside panes (off → columns align, leftcol syncs)
  inline = true,         -- highlight the changed spans within a changed line (DiffText)
  signs = true,          -- a sign-column marker per hunk
  fillchar = "-",        -- glyph drawn on an alignment filler row ("" for blank)
  layout = "auto",       -- "auto" | "vertical" | "horizontal"
  keymaps = { ... },     -- key → action (see config.ACTIONS); false disables a key
  highlights = { ... },  -- Diff* / NxDiff* group overrides
  on_attach = nil,       -- fn(session, api, bufnr) per pane buffer
})
```

Highlights use the canonical `DiffAdd` / `DiffDelete` / `DiffChange` / `DiffText`
groups, so a ported colorscheme themes the viewer unmodified; overrides and the
plugin-private `NxDiff*` extras are in
[`highlights.lua`](lua/nxvim-diff/highlights.lua).

## Testing

The plugin carries a Lua test suite (`test/*_spec.lua`) built on nxvim's native
`nx.test` framework. Run it from the repo root:

```sh
nxvim --test-plugin .
```

`config_spec` covers merge/validation, `diff_spec` the engine, `conflict_spec` the
marker parser, and `api_spec` the public `validate_spec` + git helpers.

## License

MIT — see [LICENSE](LICENSE).
