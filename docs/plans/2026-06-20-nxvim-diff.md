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

## Phase 4 — Hunk nav polish, intra-line ✅ (signs later landed)

- **Hunk nav** — `]c`/`[c`/`[C`/`]C` were already wired through `nav`; verified
  wrap-around (next past the last hunk → first; prev before the first → last) and the
  "no changes" path (no jump) in `test/nav_spec.lua`, driven by a fake session so the
  pure seek/jump math is exercised without the editor.
- **Intra-line `DiffText`** — `diff.inline(a, b)` is a **character-level** LCS (whole
  UTF-8 characters, not bytes, with an invalid-UTF-8 byte-wise fallback) returning each
  side's changed spans as half-open 0-based **byte** ranges, adjacent edits coalesced.
  `view.open` computes it once per `change` row (gated on `config.inline`) and stashes
  each side's ranges on its projection entry; `pane_marks` paints them as `DiffText`
  extmarks at `TEXT_PRIORITY` (above the whole-line tint's `LINE_PRIORITY`). Covered by
  `diff_spec` (the pure spans, incl. the multibyte case) and `decor_spec` (the rendered
  extmarks + `inline = false`).
- **Signs — LANDED** (was deferred; the core gained the capability, see
  `docs/plans/2026-06-21-extmark-signs-and-fillchar.md` in the editor repo). nxvim's
  `VirtDecor` now carries `sign_text` / `sign_hl_group`, projects them into the sign
  column (merged with diagnostic signs), and round-trips them through the extmark mirror.
  `config.signs` (opt-in, default `false`) places a `+`/`~`/`-` gutter sign on each
  changed real row by its kind; every pane reserves the sign column (`signcolumn = yes`)
  so they stay aligned. Covered by `decor_spec`.

## Phase 5 — git polish ✅ (done)

`:NxDiffGit` is HEAD-only by design. Verifying the error paths surfaced a real bug, not
just wording:

- **git ran in the wrong directory.** `git_head` passed `cwd = getcwd()` (the editor's
  working dir), so a file opened from outside `:pwd` was diffed against *that* repo, not
  the file's own — e.g. a `/tmp/x` file got matched to the repo you launched from. Fixed
  to `cwd = fnamemodify(file, ":h")` (the file's directory). The "not a git repository"
  test is the regression guard: with the old cwd it would have found the launch repo and
  failed at `git show` instead.
- **Nameless-buffer detection.** `expand("%:p")` resolves an empty name to the cwd, so a
  scratch buffer looked like a real file. Now gated on `expand("%") ~= ""`.
- **Clean messages.** `head_spec` rejects with bare, position-free strings
  (`error(msg, 0)`): "not a git repository" / "this buffer has no file to diff" / "no
  HEAD version of <rel>". The `:NxDiffGit` path's `run` wrapper adds the single
  "nxvim-diff: " prefix, so there's no more `git.lua:NN: nxvim-diff: nxvim-diff: …`
  double-prefix-with-position pile-up.

Covered live in `test/git_spec.lua`: a real init'd repo (HEAD read via `head_spec`), plus
not-a-repo / nameless / not-in-HEAD. Richer comparisons (a rev, the index, rev..rev) stay
Lua-only: a caller builds a spec with `lines = git.to_lines(...)` and calls `open()`.

> Two **core** fixes (in the editor repo) made the above clean rather than worked-around:
> (1) `expand("%:p")` now returns `""` for a buffer with no file instead of resolving the
> empty name against the cwd (so a scratch buffer no longer looks like a real file at
> `<cwd>`), and (2) the per-convergence refresh now updates the Lua **current-buffer
> snapshot** (`nx._cur_buf`), not just the content mirror — so `expand("%")` right after
> `:edit` reads the file's name instead of a stale empty one. With those, `git_head` just
> reads `expand("%:p")` and the tests `:edit` normally (no touch dance).

## Phase 6 — 3-way diff / merge (`:NxDiffConflict` rendering) ✅ (choose_* deferred)

`conflict.spec` already yielded a 3-pane (diff3) / 2-pane (merge) spec; this phase makes
`view.open` actually render the 3-pane case Meld-style.

- **`diff.compute3(base, ours, theirs)`** — a center-anchored 3-way alignment built by
  reusing the 2-way engine: it runs `compute(base, ours)` and `compute(base, theirs)`
  (so `change`-pairing and the hunk model are shared) and **merges them on the base
  line**, so a base line and each side's version of it land on one screen row. Pure ⇒
  unit-tested (`diff_spec` "3-way": same/change kinds, hunk ranges, the center-anchored
  projections, and the `add`/`change` cell tints). Side insertions become base-less
  `add` rows; a base line a side deleted becomes a filler opposite it.
- **`diff.project3(rows, role)`** — the per-pane (`ours`/`base`/`theirs`) entry list, the
  same `{ line=, kind=, spans? }` / `{ filler=true }` shape `project` yields, so the view
  paints 2- and 3-way diffs through one path.
- **`view.lua`** — a `build(config, contents)` helper computes the alignment + per-pane
  projections (with `DiffText` spans attached) for either pane count; everything
  downstream (mount, decor, sync, keymap) was already pane-count-agnostic (it loops over
  `session.panes`), so the 3 panes lay out (ours | base | theirs), tint, scroll/cursor
  sync, and hunk-nav for free. **In any 3-pane spec the MIDDLE pane is the common base**
  and the outer two are aligned against it — the inline spans on the outer panes are
  computed against the base line; the base pane keeps a whole-line tint only.
- Live-verified in `test/render3_spec.lua`: a 3-pane layout center-anchored on the base,
  the `add`/`change` tints, fillers opposite an insertion/deletion, and a real diff3
  `conflict.spec` rendered end-to-end.

- **`choose_ours` / `choose_theirs` — DONE.** `conflict.parse` now also returns
  `regions` (each block's `<<<<<<<`/`>>>>>>>` line range + bare section contents);
  `conflict.spec` carries them as `spec.resolve`, and `init.conflict` rebases the ranges
  to absolute buffer lines and attaches the live `buf`, which `view.open` stows on the
  session. The two `config.ACTIONS` (default maps `co`/`ct`) drive `nav.choose_ours` /
  `nav.choose_theirs`, which — guarding that the recorded markers are still present —
  replace the marker block `[first-1, last)` with the chosen side and close the diff.
  - **This needed a new editor primitive** (the deferral's real blocker): nxvim had *no*
    buffer-text mutation API by design. Added **`nx.buf.set_lines`** (alias
    `nvim_buf_set_lines`) — an async, promise-returning whole-line write queued like every
    other effect (`BufOp::SetLines` → `Editor::api_set_lines`, one undoable group through
    the rope chokepoints), failing loud on a `nomodifiable`/read-only buffer; `vim.bo`
    gained a round-tripping `modifiable`. Covered by the editor repo's `buf_set_lines`
    suite and the plugin's `resolve_spec` (live: choose ours/theirs rewrites the buffer).
  - One conflict block is resolved per diff (the first; `:NxDiffConflict` slices it); the
    `regions` list is already shaped for a future cursor→region pick across a file.

## Phase 7 — Docs, perf ✅ (done)

- **Help** — `doc/nxvim-diff.txt`, a vim-help-format manual surfaced by nxvim-help
  (`:help nxvim-diff`). No `tags` file is shipped: nxvim-help auto-derives targets from
  the `*anchor*`s (matching the sibling plugins), so the help works the moment the plugin
  is on the runtimepath. Covers the commands, the in-diff keys, the 3-way layout, the
  full Lua API, configuration (incl. the deferred `signs`/`fillchar`/`choose_*`), a
  worked extending example, and the perf guards.
- **README "Extending"** — a complete formatter-preview worked example (buffer vs its
  formatted output through `open()`), alongside the existing git/conflict-as-clients note.
- **Perf** — rather than swap in histogram/Myers wholesale, `diff.compute` got two cheap,
  high-value guards that keep it bounded (the actual goal — "the editor must never
  freeze"):
  1. **Prefix/suffix trim** — shared leading/trailing lines are peeled off as `same` rows
     and only the differing *middle* runs the O(n·m) LCS. The dominant real case (a few
     edits in an otherwise-identical file) shrinks to a tiny middle and gets the exact,
     minimal alignment. (Trimming is result-identical to a plain LCS for ordinary edits —
     the peeled lines are equal, so the LCS would have matched them anyway.)
  2. **Cell cap** (`diff.LCS_CELL_LIMIT`, default 1e6) — if the trimmed middle is still
     huge and highly divergent, it falls back to a coarse block-replace (every old line a
     `del`, every new line an `add`; `pair_changes` turns the overlap into `change` rows)
     instead of allocating an enormous table. Correct (every line is shown), just not the
     minimal-edit alignment; O(n+m), never freezes.

  `compute3` inherits both for free (it's built on `compute`). Covered by `diff_spec`'s
  "perf guards" cases (trim parity, an internal match found under the cap, and the coarse
  fallback past a lowered cap). A full histogram/Myers engine stays a possible future
  upgrade, but the freeze risk Phase 1 flagged is closed.

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
