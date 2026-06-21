-- nxvim-diff.view — turn a validated spec into the on-screen panes, and tear them
-- down. The editor-integration heart; the only module that touches windows, views,
-- and extmarks.
--
-- Phase 2 renders a TWO-pane diff (a 3-pane spec — diff3 conflicts — fails loud until
-- Phase 6). The two read-only sides are `nx.view` surfaces laid out side by side in a
-- dedicated tab, so closing the diff restores the user's layout untouched.
--
-- Layout is a fresh tab: pane A mounts with `{ tab = true }` (the view fills a new tab
-- page, no split, no leftover empty window — the core primitive added for this), and
-- the remaining panes `{ split = "vsplit" }` beside it. Both are *view-ops* (one queue,
-- drained in order), so the whole layout is one deterministic tick — no `nx.cmd`, no
-- `:only`. The view buffer/winid only exist a tick after the mount, so decoration waits
-- on `nx.wait_for(bufnr)`. Closing the tab-mounted pane closes the whole tab.
--
-- ===== the session handle (what open returns) =====
--   session = {
--     config, spec, rows, hunks, ns,
--     panes = { { view, label, side = "a"|"b", proj, text }, ... },
--     _ready,                                   -- true once panes are rendered
--     goto_row  = function(self, row) end,      -- move every pane to alignment `row`
--     cursor_row = function(self) -> row end,   -- the focused pane's alignment row
--     reopen = function() end,                  -- re-run the source & re-render
--   }

local diff = require("nxvim-diff.diff")
local highlights = require("nxvim-diff.highlights")
local keymap = require("nxvim-diff.keymap")

local M = {}

local SIDES = { "a", "b", "c" }

-- Resolve a pane's content to a line array (may await for a `path` pane).
local function resolve(pane)
  if pane.lines then
    return pane.lines
  end
  if pane.buf then
    return nx.buf.lines(pane.buf, 0, -1)
  end
  if pane.path then
    local text = nx.await(nx.fs.read_text(pane.path))
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
      lines[#lines] = nil -- drop the empty produced by a trailing newline
    end
    return lines
  end
  return {}
end

-- The text shown in pane `side` for each alignment row (a filler row → "").
local function project_text(proj, lines)
  local out = {}
  for i, e in ipairs(proj) do
    out[i] = e.filler and "" or (lines[e.line] or "")
  end
  return out
end

-- Whole-line tint marks for one pane: DiffAdd/DiffDelete/DiffChange on the changed
-- real lines (a blank filler row is left untinted in Phase 2; fillchar styling is
-- Phase 4).
local function pane_marks(proj, text)
  local marks = {}
  for i, e in ipairs(proj) do
    if not e.filler then
      local hl = highlights.hl_for(e.kind)
      if hl then
        local line0 = i - 1
        marks[#marks + 1] =
          { line = line0, col = 0, end_row = line0, end_col = #(text[i] or ""), hl_group = hl }
      end
    end
  end
  return marks
end

-- Decorate + finalize once every pane's backing buffer exists (a tick after mount).
local function finish(session, api)
  nx.wait_for(function()
    for _, p in ipairs(session.panes) do
      if not p.view:bufnr() then
        return false
      end
    end
    return true
  end, { tries = 200, interval = 5, message = "nxvim-diff: pane buffers never appeared" })
    :next(function()
      for _, p in ipairs(session.panes) do
        p.view:set_decor(session.ns, pane_marks(p.proj, p.text))
        local win = p.view:winid()
        if win and not session.config.wrap then
          pcall(function()
            vim.wo[win].wrap = false
          end)
        end
        if type(session.config.on_attach) == "function" then
          pcall(session.config.on_attach, session, api, p.view:bufnr())
        end
      end
      keymap.install(session, api)
      session.panes[1].view:focus()
      session._ready = true
    end)
    :catch(function(e)
      nx.notify("nxvim-diff: render failed: " .. tostring(e), 4)
    end)
end

-- open(root, spec) — build a session from a validated spec (see the contract above).
function M.open(root, spec)
  if #spec.panes ~= 2 then
    error(
      ("nxvim-diff: 3-way rendering not implemented yet (Phase 6); got %d panes"):format(
        #spec.panes
      )
    )
  end

  local contents = {}
  for i, pane in ipairs(spec.panes) do
    contents[i] = resolve(pane)
  end
  local result = diff.compute(contents[1], contents[2])

  local panes = {}
  for i, pane in ipairs(spec.panes) do
    local v = nx.view.create({
      name = "nxdiff:" .. (pane.label or ("pane" .. i)),
      filetype = pane.filetype,
    })
    local proj = diff.project(result.rows, SIDES[i])
    local text = project_text(proj, contents[i])
    v:set_lines(text)
    panes[i] = { view = v, label = pane.label, side = SIDES[i], proj = proj, text = text }
  end

  local session = {
    config = root.config,
    spec = spec,
    rows = result.rows,
    hunks = result.hunks,
    ns = nx.ns.create("nxvim-diff"),
    panes = panes,
    _ready = false,
  }

  -- The focused pane's current alignment row (projection is 1:1 with the rows, so the
  -- view line number IS the alignment row).
  function session:cursor_row()
    local cur = nx.win.current()
    for _, p in ipairs(self.panes) do
      if p.view:winid() == cur then
        return p.view:line() or 1
      end
    end
    return self.panes[1].view:line() or 1
  end

  -- Move every pane to alignment `row` (basic sync; the WinScrolled-driven live sync
  -- is Phase 3), then restore focus to the first pane.
  function session:goto_row(row)
    for _, p in ipairs(self.panes) do
      p.view:set_cursor(row)
    end
    self.panes[1].view:focus()
  end

  session.reopen = function()
    root.open(spec)
  end

  -- Lay out the panes in one tick (see the module header): pane A fills a fresh tab,
  -- the rest split beside it — all view-ops, so order is deterministic.
  local api = { run = root._run }
  panes[1].view:mount({ tab = true })
  for i = 2, #panes do
    panes[i].view:mount({ split = "vsplit" })
  end
  finish(session, api)

  return session
end

-- close(session) — tear the panes down and restore the prior layout. Tolerant of a
-- partially-built or nil session (open may have failed mid-build).
function M.close(session)
  if not session then
    return
  end
  if session._detach then
    pcall(session._detach) -- drop the WinScrolled / sync autocmds (Phase 3)
  end
  -- Closing each view destroys its window; the tab-mounted pane (panes[1]) closes the
  -- whole diff tab, restoring the user's previous tab. All view-ops — one tick, no
  -- ex-commands, no ordering dance.
  for _, pane in ipairs(session.panes or {}) do
    if pane.view then
      pcall(function()
        pane.view:close()
      end)
    end
  end
end

return M
