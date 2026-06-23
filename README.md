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

A working **two- and three-pane diff viewer**, plus the pure cores that feed it — all
covered by `nxvim --test-plugin .`:

- **Rendering** — a diff opens side-by-side in a dedicated tab, projected to equal
  height with alignment fillers and DiffAdd/DiffDelete/DiffChange line tints. A **3-pane
  diff3** (`:NxDiffConflict` on a diff3-style conflict) lays out ours | base | theirs,
  center-anchored on the middle (base) pane.
- **Scroll / cursor sync** — the panes' viewports and cursor row stay locked together.
- **Intra-line highlights** — the edited characters of a changed line are tinted with
  `DiffText` (a character-level diff).
- **Hunk navigation** — `]c` / `[c` / `]C` / `[C`, with wrap-around.
- **Conflict resolution** — `:NxDiffConflict` shows every conflict in the file at once;
  `co` / `ct` / `cb` write the chosen side (ours / theirs / both) of the conflict **under
  the cursor** back into the live buffer, replacing its marker block as one undoable edit,
  then close the diff. When neither whole side fits, `cp` stages the selected lines from a
  pane (normal or visual mode) — only the conflict's own lines, marked with a `▶` gutter
  sign and a background tint — and `ca` applies the hand-built composition (`cx` clears). Built on the editor's
  `nx.buf.set_lines` (the async buffer-text write); guarded so a moved marker aborts loud.
- **Gutter signs & fillchar** — `signs` puts a `+`/`~`/`-` gutter sign on each changed
  line (opt-in; every pane reserves the column so they stay aligned), and `fillchar`
  paints a rule across the blank alignment rows (vim's diff-filler style). Both ride
  new core extmark decorations (`sign_text` / `line_fill`).
- **Git source** — `:NxDiffGit` diffs the current file against HEAD, run inside the
  file's own repo, with clear not-a-repo / no-file / not-in-HEAD messages.
- **Pure cores** — the LCS **diff engine** (2-way alignment + the center-anchored 3-way
  merge, hunks, projection), the **conflict-marker parser** (diff3 / plain-merge →
  sides), config merge/validation, and spec validation.

All planned phases are complete (see
[`docs/plans/2026-06-20-nxvim-diff.md`](docs/plans/2026-06-20-nxvim-diff.md)), including
whole-file conflict diffs with a cursor→region resolve (`co`/`ct`/`cb` and the
`cp`/`ca`/`cx` line-picker act on the conflict the cursor is in).

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

`:NxDiffConflict` parses the file's `<<<<<<< / ||||||| / ======= / >>>>>>>` markers and
opens the **whole file** with every conflict in context: a diff3-style file (base section
present) as a 3-way ours | base | theirs (the two outer panes center-anchored against the
base), a plain-merge file as a 2-way ours/theirs. Step between conflicts with `]c`/`[c`
and resolve the one under the cursor with `co`/`ct`/`cb`, or hand-build it with
`cp`/`ca`.

Inside a diff (default, buffer-local bindings):

| Key | Action |
| --- | --- |
| `]c` / `[c` | next / previous changed hunk |
| `]C` / `[C` | last / first hunk |
| `co` / `ct` / `cb` | resolve conflict to ours / theirs / both (`:NxDiffConflict` diffs only) |
| `cp` | stage selected conflict line(s) from this pane (normal or visual mode; `▶` sign) |
| `ca` / `cx` | apply / clear the staged lines |
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

A worked example — a **formatter preview** (this buffer vs its formatted output) is a
one-screen plugin on top of `open`:

```lua
vim.keymap.set("n", "<leader>fp", function()
  local src = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local out = vim.fn.systemlist("prettier --stdin-filepath " .. vim.fn.expand("%"), src)
  require("nxvim-diff").open({
    title = "format preview",
    panes = {
      { label = "buffer",    lines = src, filetype = vim.bo.filetype },
      { label = "formatted", lines = out, filetype = vim.bo.filetype },
    },
  })
end, { desc = "preview formatting as a diff" })
```

The bundled git/conflict support are themselves clients of this API too:

```lua
local diff = require("nxvim-diff")
diff.git_head()   -- current file vs HEAD (what :NxDiffGit calls)
diff.conflict()   -- parse this buffer's conflict markers (what :NxDiffConflict calls)
diff.close()
```

For a richer git comparison than HEAD (an arbitrary rev, the index, `rev..rev`), build
the spec yourself — `require("nxvim-diff.git").to_lines(...)` is handy — and `open()`
it. That's intentionally Lua, not a forest of command flags.

> A 3-pane spec is a 3-way diff: the **middle** pane is the common base, the outer two
> are center-anchored against it.

## Configuration

`setup()` takes (defaults shown):

```lua
require("nxvim-diff").setup({
  sync_scroll = true,    -- lock the panes' viewports together (uses WinScrolled)
  sync_cursor = true,    -- keep the panes' cursor row aligned
  wrap = false,          -- soft-wrap inside panes (off → columns align, leftcol syncs)
  inline = true,         -- highlight the changed spans within a changed line (DiffText)
  signs = false,         -- per-hunk gutter signs +/~/- (opt-in; reserves the column)
  fillchar = "-",        -- glyph painted across a blank filler row ("" leaves it blank)
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

## Performance

The line diff is an LCS with two guards so a large file never freezes the editor:
shared leading/trailing lines are **trimmed** before the `O(n·m)` table runs (a few
edits in a big file stay cheap and get the exact alignment), and a still-huge,
highly-divergent middle falls back to a coarse block-replace (`diff.LCS_CELL_LIMIT`)
rather than allocating an enormous table — correct, every line shown, just not minimal.

## Help

With [nxvim-help](https://github.com/davidrios/nxvim-help) installed, `:help nxvim-diff`
opens the full manual ([`doc/nxvim-diff.txt`](doc/nxvim-diff.txt)) — no `tags` file
needed, the anchors are auto-derived.

## Testing

The plugin carries a Lua test suite (`test/*_spec.lua`) built on nxvim's native
`nx.test` framework. Run it from the repo root:

```sh
nxvim --test-plugin .
```

The **pure** specs need no editor state: `config_spec` (merge/validation), `diff_spec`
(the 2-way + 3-way engine, the intra-line char-diff, and the perf guards), `conflict_spec`
(the marker parser), `nav_spec` (hunk navigation), and `api_spec` (`validate_spec` + git
helpers). The **live** specs drive a real diff: `render_spec` (2-pane layout),
`render3_spec` (3-way diff3 layout), `sync_spec` (scroll/cursor sync), `decor_spec` (the
line tints + `DiffText` spans), and `git_spec` (`:NxDiffGit`).

## License

MIT — see [LICENSE](LICENSE).
