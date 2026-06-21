# nxvim-diff

A Meld-style **side-by-side diff viewer** for
[nxvim](https://github.com/davidrios/nxvim) — two (or three) panes locked together,
changed/added/removed lines tinted, aligned with filler rows, navigable hunk-by-hunk.

It is built entirely on the native `nx.*` plugin API (ADR 0002): the read-only sides
are [`nx.view`](https://github.com/davidrios/nxvim) surfaces, every line tint and
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
                                  │+4      log::info!("done");
 4  }                             │ 5  }
```

(`~` a changed line — its edited chars are tinted `DiffText`; `+` an added line; the
blank left row is the alignment filler opposite it.)

## Status

A working **two-pane diff viewer**, plus the pure cores that feed it — all covered by
`nxvim --test-plugin .`:

- **Rendering** — a diff opens side-by-side in a dedicated tab, projected to equal
  height with alignment fillers and DiffAdd/DiffDelete/DiffChange line tints.
- **Scroll / cursor sync** — the panes' viewports and cursor row stay locked together.
- **Intra-line highlights** — the edited characters of a changed line are tinted with
  `DiffText` (a character-level diff).
- **Hunk navigation** — `]c` / `[c` / `]C` / `[C`, with wrap-around.
- **Git source** — `:NxDiffGit` diffs the current file against HEAD, run inside the
  file's own repo, with clear not-a-repo / no-file / not-in-HEAD messages.
- **Pure cores** — the LCS **diff engine** (alignment, hunks, projection), the
  **conflict-marker parser** (diff3 / plain-merge → sides), config merge/validation, and
  spec validation.

Still building out (see
[`docs/plans/2026-06-20-nxvim-diff.md`](docs/plans/2026-06-20-nxvim-diff.md)):

- the **3-way** layout for diff3 conflicts (`:NxDiffConflict`) — the parser is done, but
  laying out three panes is Phase 6, so a 3-pane spec currently **fails loud**;
- per-hunk gutter **signs** (`signs`) and **filler glyphs** (`fillchar`) — deferred until
  nxvim's core can paint an extmark gutter sign / filler row; the options exist but are
  inert (a changed line is conveyed by its tint + `DiffText`, a filler by a blank row).

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
diff3-style file (base section present) becomes a 3-way ours/base/theirs, a plain-merge
file a 2-way ours/theirs. **Note:** the 3-pane *layout* is still pending (Phase 6), so a
diff3 conflict fails loud at render for now; the 2-way merge case renders today.

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
  signs = false,         -- per-hunk sign-column markers (deferred — needs core support)
  fillchar = "-",        -- glyph for a filler row (deferred — fillers render blank today)
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

The **pure** specs need no editor state: `config_spec` (merge/validation), `diff_spec`
(the engine + the intra-line char-diff), `conflict_spec` (the marker parser), `nav_spec`
(hunk navigation), and `api_spec` (`validate_spec` + git helpers). The **live** specs
drive a real diff: `render_spec` (pane layout), `sync_spec` (scroll/cursor sync),
`decor_spec` (the line tints + `DiffText` spans), and `git_spec` (`:NxDiffGit`).

## License

MIT — see [LICENSE](LICENSE).
