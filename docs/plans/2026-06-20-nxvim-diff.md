# nxvim-diff — phased implementation plan

A Meld-style side-by-side (and 3-way) diff viewer for nxvim, built as a **renderer you
feed a diff to**, not a git tool. The core renders + navigates a diff; where the sides
come from is the caller's business. The public Lua entry point —
`require("nxvim-diff").open(spec)` — is how *any* plugin (a git integration, an
LSP-rename preview, a formatter preview) sends a diff for preview.

Only two things are exposed as `:commands`; everything else is the Lua API (command
flags for the long tail aren't worth the friction):

- **`:NxDiffGit`** — diff the current file's working tree against git **HEAD**.
- **`:NxDiffConflict`** — if the current file has git conflict markers, open them as a
  3-way (diff3 style) / 2-way (plain merge style) diff.

Both are thin wrappers over the Lua API, so the bundled git/conflict support is itself
just a client of `open()`.

## Architecture at a glance

```
:NxDiffGit ─► git.head_spec(ctx) ──┐   (nx.run: git show HEAD:file)
:NxDiffConflict ─► conflict.spec(lines) ┤  (pure: parse markers → sides)
any plugin ─────────────────────────────┴─► open(spec) ─ validate ─► view.open
                                                                        │
   diff.compute → rows/hunks ; panes (nx.view) ; extmark tints + virt_line
   fillers ; nav + keymap + scroll/cursor sync (WinScrolled + nx.win.set_*)
```

Module map: `config` (data+validate), `diff` (pure engine), `conflict` (pure marker
parser), `git` (HEAD spec via nx.run), `highlights` (Diff* palette), `view`
(panes/layout/paint), `nav` (hunk motions + sync), `keymap`. One concern each.

### Editor primitives it depends on

The companion nxvim core change (committed in the editor repo) added the seam the sync
layer needs:

- **`WinScrolled`** autocmd — per-window on `topline`/`leftcol` change (gated on a
  handler).
- **`nx.win.set_topline` / `set_leftcol` / `set_cursor` / `restview`** — explicit-window
  setters that work from inside `nx.win.call`.
- **`nx.view:mount({ tab = true })`** — mount a view as the sole window of a fresh tab
  (no split, no leftover empty window; closing it closes the tab). Added so the diff
  lays out its panes in one deterministic tick (`A:mount{tab}` + `B:mount{split}`,
  both view-ops) instead of a `tabnew`/split/`:only` cross-tick dance.
- **`nx.buf.search(buf, pattern, opts)`** — native buffer search over the mirror
  (plain / pcre / vim engines, start position, captures). `:NxDiffConflict` uses it to
  locate the conflict region (start marker → end marker) instead of scanning lines in
  Lua, then parses only the block between.

Plus: `nx.view`, extmarks with `virt_lines` + `hl_group`, `nx.run`, `nx.fs`,
`nx.async`/`await`, `nx.layer`, `nx.command`, `nx.keymap.set`, `nx.hl.define`.

---

## Phase 0 — Scaffold ✅ (done)

Repo skeleton under `~/work/nxvim-plugins/nxvim-diff`, matching the sibling plugins.

## Phase 1 — Pure cores ✅ (done)

- `diff.lua`: LCS line diff → `same/add/del/change` alignment, `hunks`, and
  `project(rows, side)` (equal-height per-pane projection with `filler` markers).
- `conflict.lua`: parse `<<<<<<< / ||||||| / ======= / >>>>>>>` into full reconstructed
  ours/base/theirs sides → a 2/3-pane spec; fails loud on a malformed/unterminated
  marker.
- `git.lua`: pure helpers (`to_lines`, `repo_relative`) + `head_spec(ctx)` promise.
- `config.lua`: merge + validate.
- **Tests (passing):** `diff_spec`, `conflict_spec`, `api_spec` (validate_spec + git
  helpers), `config_spec`.
- **Follow-up:** swap the O(n·m) LCS for histogram/Myers if large files prove slow.

## Phase 2 — Two-pane rendering ✅ (done)

`view.open(root, spec)` renders a 2-pane diff (a 3-pane spec fails loud → Phase 6):
content resolution (`lines`/`buf`/`path`), `diff.compute` + `project`, a dedicated tab
laid out side-by-side (built across ticks so the ex-cmd/view-op ordering is
deterministic; the new tab's empty window is dropped with `:only`), each read-only side
an `nx.view` set to the projected lines (filler → blank row), whole-line
DiffAdd/DiffDelete/DiffChange tints via `set_decor`, `nowrap`, and `keymap.install`.
`close()` is a `:tabclose` + `view:close()`. The session exposes `cursor_row`/`goto_row`
(basic, pre-sync) and `reopen`. Live-verified in `test/render_spec.lua` (layout, clean
2-window tab, equal-height projection with fillers, `path`-pane reads). Deferred to
later phases: visible `fillchar` on filler rows (Phase 4), 3-way (Phase 6).

Original step list (for reference):

1. **Content resolution** — `pane.lines` as-is; `pane.buf` → `nvim_buf_get_lines`;
   `pane.path` → `nx.await(nx.fs.read)` split on `\n`.
2. **Layout** — open a dedicated `nx.layer`/tab, vsplit into N panes per
   `config.layout`; `nowrap` unless `config.wrap`.
3. **Panes** — each read-only side is an `nx.view`; set its lines from
   `diff.project(rows, side)`, a `filler` entry rendered as a blank/`fillchar` row.
4. **Paint** — extmarks: whole-line `DiffAdd`/`DiffDelete`/`DiffChange` tints
   (`highlights.hl_for`) + `NxDiffFiller` on fillers; `virt_lines` where a side needs
   height beyond its real lines.
5. **Session** — return the documented handle (`rows`, `hunks`, `panes`, `goto_row`,
   `cursor_row`, `reopen`, `_detach`, `_layer_close`); wire `keymap.install`.

- **Acceptance:** the `<leader>du` caps demo (examples) and `:NxDiffGit` on a changed
  tracked file render side-by-side, tinted, aligned.

## Phase 3 — Scroll & cursor sync ✅ (done)

`nav.attach_sync(session)` registers two autocmds (gated on `config.sync_scroll` /
`sync_cursor`, dropped by `session._detach` on close):

- **`WinScrolled`** — when a pane scrolls, copy its `topline` (and `leftcol`, unless
  `config.wrap`) onto the other panes via `nx.win.set_topline` / `set_leftcol`.
- **`CursorMoved`** — when the focused pane's cursor moves, mirror its line onto the
  others via `nx.win.set_cursor`. Because the projection is 1:1 (a pane's view line
  number IS the alignment row, fillers included), the aligned cursor is just the same
  line on every pane — no cross-filler remapping needed.

**Echo handling:** a programmatic `set_topline` re-fires `WinScrolled` for the moved
window next diff (the core rebases its scroll baseline to the *pre-callback* offsets on
purpose). The mirror is therefore **compare-and-set** — a pane already at the source's
topline is skipped — so the re-fire produces no new ops and the cascade dies after one
harmless round. `session._syncing` is the synchronous-reentry guard. Cursor mirroring
needs no echo care: setting a *non-focused* window's cursor neither steals focus nor
re-fires `CursorMoved`.

Live-verified in `test/sync_spec.lua`: vertical scroll mirrors both ways, cursor line
mirrors, `sync_scroll = false` lets the panes scroll independently, and `close()`
detaches the autocmds (a later scroll is inert). `view.lua` calls `attach_sync` from
`finish()` after the panes mount.

**Smooth scrolling.** nxvim animates viewport scrolls (`'scrollanim'`), but only the
*focused* window animates — and a synced pane is moved with a crisp `set_topline`. So a
scroll would slide the focused pane while the others snap to the destination: a visible
desync. Rather than work around it, this needed a core change (made in the editor repo):
`'scrollanim'` became a **per-window** option (a window-local `Option<bool>` override of
the global default, resolved in `finalize_scroll_gesture`). `view.lua` sets
`vim.wo[win].scrollanim = false` on every pane in `finish()` (the gate now also waits for
each pane's *window* id, not just its buffer, since the option must reach a real window —
and unlike `nowrap` the core defaults `scrollanim` *on*). The panes therefore snap in
lockstep with no animation. Covered by `sync_spec`'s "disables scroll animation on the
panes" case, plus the editor repo's `window_local_scrollanim_*` rendering tests.

## Phase 4 — Hunk nav polish, intra-line, signs

`]c`/`[c`/`[C`/`]C` are wired through `nav` already — verify wrap-around + "no
changes". Implement `diff.inline(a, b)` (char LCS) → `DiffText` spans on `change` rows
when `config.inline`. Sign-column markers per hunk when `config.signs`.

## Phase 5 — git polish

`:NxDiffGit` is HEAD-only by design. Verify the not-a-repo / no-file / file-not-in-HEAD
messages read well. Richer comparisons (a rev, the index, rev..rev) stay Lua-only: a
caller builds a spec with `lines = git.to_lines(...)` and calls `open()`.

## Phase 6 — 3-way diff / merge (`:NxDiffConflict` rendering)

`conflict.spec` already yields a 3-pane (diff3) / 2-pane (merge) spec. Make `view.open`
lay out 3 panes Meld-style (center-anchored alignment of base↔ours and base↔theirs).
Optional: `choose_ours`/`choose_theirs` hunk actions writing the resolution back into
the real conflicted buffer (extend `config.ACTIONS`).

## Phase 7 — Docs, perf

`doc/nxvim-diff.txt` help (via nxvim-help); README "Extending" worked example; ship the
histogram diff if Phase 1's follow-up is warranted.

---

## The public Lua API (stable from Phase 0)

```lua
local diff = require("nxvim-diff")

-- Preview any diff — the extension point a git/LSP/formatter plugin uses:
diff.open({
  title = "optional",
  panes = {                              -- exactly 2 or 3
    { label = "HEAD", lines = {...}, filetype = "rust", readonly = true },
    { label = "working", buf = 0, readonly = false },  -- or path = "/abs/file"
  },
})

diff.git_head()   -- current file vs HEAD (also :NxDiffGit)
diff.conflict()   -- parse this buffer's conflict markers (also :NxDiffConflict)
diff.close()
```

A pane carries **exactly one** of `lines` / `buf` / `path`. `validate_spec` enforces
the shape and fails loud — no silent mis-render.
