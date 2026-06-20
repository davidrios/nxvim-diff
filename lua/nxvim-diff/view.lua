-- nxvim-diff.view — turn a validated spec into the on-screen panes, and tear them
-- down. This is the editor-integration heart (the bulk of Phase 2/3); it is the only
-- module that touches windows, views, and extmarks.
--
-- It is delivered here as a documented SKELETON: `open()` fails loud (per the project's
-- no-silent-stubs rule) so the scaffold never *pretends* to render a diff. The doc
-- below is the contract `init.lua`, `nav.lua`, and `keymap.lua` are already written
-- against, so filling this in is the whole of Phases 2–3.
--
-- ===== the session handle (what open returns) =====
--   session = {
--     config = <effective config>,
--     spec   = <the validated spec>,
--     rows   = <diff.compute(a,b).rows>,   -- the alignment
--     hunks  = <diff.compute(a,b).hunks>,  -- { {first,last}, ... } over `rows`
--     ns     = <nx.ns.create("nxvim-diff")>,
--     panes  = { { view = <nx.view handle>, label = , side = "a"|"b"|"c" }, ... },
--     reopen = function() ... end,         -- re-run the source & re-render in place
--     goto_row  = function(self, row) ... end,  -- move the active pane to alignment
--                                               -- `row`, syncing the others
--     cursor_row = function(self) -> row end,   -- the active pane's alignment row
--   }
--
-- ===== what open(root, spec) must do (Phases 2–3) =====
--   1. Resolve each pane's content to a line array:
--        pane.lines           → use as-is
--        pane.buf  (bufnr)    → nvim_buf_get_lines(buf, 0, -1, false)
--        pane.path (abs path) → nx.await(nx.fs.read(path)) then split on "\n"
--   2. alignment = diff.compute(panes[1].lines, panes[2].lines)  (2-way; Phase 6 does
--      the 3-way base/ours/theirs projection).
--   3. Lay out the windows: open a fresh layer/tab, vsplit into N panes (config.layout),
--      set each pane's window to nowrap (unless config.wrap) so columns align.
--   4. For each pane: an nx.view holds the read-only side(s); the editable side may be
--      the real buffer. Set its lines from diff.project(rows, side) — a `filler` entry
--      becomes a blank/fillchar row so corresponding lines share a screen row.
--   5. Paint via extmarks under `ns`: whole-line DiffAdd/DiffDelete/DiffChange tints
--      (highlights.hl_for), the NxDiffFiller tint on filler rows, hunk signs when
--      config.signs, and DiffText spans on change rows when config.inline (diff.inline,
--      Phase 4).
--   6. Wire interaction: keymap.install(session, api); if config.sync_scroll /
--      sync_cursor, nav.attach_sync(session) (the WinScrolled-driven mirror — see
--      nav.lua). on_attach(session, api, bufnr) per pane when configured.
--
-- The scroll/cursor sync relies on the editor primitives this plugin's companion core
-- change added: the `WinScrolled` autocmd plus nx.win.set_topline / set_leftcol /
-- set_cursor (explicit-window, so they work from inside nx.win.call).

local M = {}

-- open(root, spec) — build a session from a validated spec. See the contract above.
function M.open(_root, _spec)
  error("nxvim-diff.view.open: pane rendering not implemented yet (Phase 2 — see docs/plans)")
end

-- close(session) — tear the panes down and restore the prior layout. Tolerant of a
-- partially-built or nil session (open() may have failed mid-build).
function M.close(session)
  if not session then
    return
  end
  if session._detach then
    pcall(session._detach) -- drop the WinScrolled / sync autocmds
  end
  for _, pane in ipairs(session.panes or {}) do
    if pane.view then
      pcall(function()
        pane.view:close()
      end)
    end
  end
  if session._layer_close then
    pcall(session._layer_close) -- close the diff's layer/tab if we opened one
  end
end

return M
