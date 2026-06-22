-- nxvim-diff.view — turn a validated spec into the on-screen panes, and tear them
-- down. The editor-integration heart; the only module that touches windows, views,
-- and extmarks.
--
-- Renders a 2-pane diff OR a 3-pane diff3 (Phase 6): the read-only sides are `nx.view`
-- surfaces laid out side by side in a dedicated tab, so closing the diff restores the
-- user's layout untouched. In a 3-pane spec the MIDDLE pane is the common base and the
-- outer two are center-anchored against it (see `build` / `diff.compute3`).
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
--     resolve,                                  -- conflict write-back map (nil if none)
--     panes = { { view, label, side = "a"|"b", proj, text }, ... },
--     _ready,                                   -- true once panes are rendered
--     goto_row  = function(self, row) end,      -- move every pane to alignment `row`
--     cursor_row = function(self) -> row end,   -- the focused pane's alignment row
--     reopen = function() end,                  -- re-run the source & re-render
--   }

local diff = require("nxvim-diff.diff")
local highlights = require("nxvim-diff.highlights")
local keymap = require("nxvim-diff.keymap")
local nav = require("nxvim-diff.nav")

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

-- The extmark priorities: the whole-line tint sits under the intra-line DiffText spans
-- so the changed characters stay visible on top of the changed-line background.
local LINE_PRIORITY = 100
local TEXT_PRIORITY = 200

-- The per-hunk gutter sign for a changed real row, by its kind: `+` an added line,
-- `~` a changed line, `-` a deleted one. A non-filler row's kind is exactly what this
-- pane shows (an `add` row is real only on the added side, `del` only on the deleted
-- side, `change` on both), so the kind maps straight to the glyph.
local SIGN_GLYPH = { add = "+", change = "~", del = "-" }
local SIGN_HL = { add = "NxDiffSignAdd", change = "NxDiffSignChange", del = "NxDiffSignDelete" }

-- Decoration marks for one pane (`config` gates the optional layers):
--   * whole-line DiffAdd/DiffDelete/DiffChange tint on every changed real row,
--   * `DiffText` spans over the changed characters of a `change` row (`config.inline`,
--     from `entry.spans` the caller stashed — half-open 0-based byte ranges),
--   * a per-hunk gutter sign (`+`/`~`/`-`) on each changed real row (`config.signs`,
--     via the core `sign_text` extmark decoration),
--   * a `fillchar` rule across each blank filler row (`config.fillchar`, via the core
--     `line_fill` extmark decoration) so the alignment gap reads as a gap, vim-style.
local function pane_marks(proj, text, config)
  local marks = {}
  for i, e in ipairs(proj) do
    local line0 = i - 1
    if e.filler then
      -- The alignment gap: paint the fillchar across the blank row (when configured).
      if config.fillchar ~= "" then
        marks[#marks + 1] = {
          line = line0,
          col = 0,
          line_fill = { text = config.fillchar, hl_group = "NxDiffFiller" },
          priority = LINE_PRIORITY,
        }
      end
    else
      local hl = highlights.hl_for(e.kind)
      if hl then
        marks[#marks + 1] = {
          line = line0,
          col = 0,
          end_row = line0,
          end_col = #(text[i] or ""),
          hl_group = hl,
          priority = LINE_PRIORITY,
        }
      end
      if config.signs and SIGN_GLYPH[e.kind] then
        marks[#marks + 1] = {
          line = line0,
          col = 0,
          sign_text = SIGN_GLYPH[e.kind],
          sign_hl_group = SIGN_HL[e.kind],
          priority = LINE_PRIORITY,
        }
      end
      if config.inline and e.spans then
        for _, span in ipairs(e.spans) do
          marks[#marks + 1] = {
            line = line0,
            col = span[1],
            end_row = line0,
            end_col = span[2],
            hl_group = "DiffText",
            priority = TEXT_PRIORITY,
          }
        end
      end
    end
  end
  return marks
end

-- Decorate + finalize once every pane has both its backing buffer AND its window. The
-- window id lags the buffer by a tick (it only exists after the mount op drains), and
-- the per-window options below — `nowrap`, and especially `noscrollanim`, which the core
-- defaults *on* — must reach a real window to take effect, so the gate waits for both.
local function finish(session, api)
  nx.wait_for(function()
    for _, p in ipairs(session.panes) do
      if not p.view:bufnr() or not p.view:winid() then
        return false
      end
    end
    return true
  end, { tries = 200, interval = 5, message = "nxvim-diff: panes never mounted" })
    :next(function()
      for _, p in ipairs(session.panes) do
        p.view:set_decor(session.ns, pane_marks(p.proj, p.text, session.config))
        local win = p.view:winid()
        pcall(function()
          if not session.config.wrap then
            vim.wo[win].wrap = false
          end
          -- With signs on, reserve the column on EVERY pane (not just ones that have a
          -- sign) so the panes stay the same width and their lines keep lining up.
          if session.config.signs then
            vim.wo[win].signcolumn = "yes"
          end
          -- Only the focused pane can animate a scroll; a synced (non-focused) pane is
          -- moved with a crisp `set_topline`, so it would jump while the focused pane
          -- slides — a visible desync. Disable scroll animation on every diff pane so
          -- they move in lockstep. (Per-window override; the global `'scrollanim'` and
          -- other windows are untouched, and it's restored when the view's window goes.)
          vim.wo[win].scrollanim = false
        end)
        if type(session.config.on_attach) == "function" then
          pcall(session.config.on_attach, session, api, p.view:bufnr())
        end
      end
      keymap.install(session, api)
      nav.attach_sync(session) -- scrollbind the panes (Phase 3)
      session.panes[1].view:focus()
      session._ready = true
    end)
    :catch(function(e)
      nx.notify("nxvim-diff: render failed: " .. tostring(e), 4)
    end)
end

-- Compute the alignment AND the per-pane projections (with intra-line `DiffText` spans
-- already attached when `config.inline`) for a 2- or 3-pane diff. Both pane counts yield
-- the same per-pane entry shape (`{ line=, kind=, spans? }` / `{ filler=true, kind= }`),
-- so the rest of the view paints them through one path.
--
-- A 3-pane spec is a diff3: the MIDDLE pane is the common base, the outer two are
-- center-anchored against it. compute3 takes (base, ours, theirs) = (contents[2],
-- contents[1], contents[3]); only the outer panes carry intra-line spans (each computed
-- against the base line — the base pane stays a whole-line tint).
local function build(config, contents)
  if #contents == 3 then
    local result = diff.compute3(contents[2], contents[1], contents[3])
    local projs = {
      diff.project3(result.rows, "ours"),
      diff.project3(result.rows, "base"),
      diff.project3(result.rows, "theirs"),
    }
    if config.inline then
      for k, r in ipairs(result.rows) do
        if r.base then
          local base_line = contents[2][r.base]
          if r.cells.ours.kind == "change" then
            projs[1][k].spans = diff.inline(base_line, contents[1][r.cells.ours.line]).b
          end
          if r.cells.theirs.kind == "change" then
            projs[3][k].spans = diff.inline(base_line, contents[3][r.cells.theirs.line]).b
          end
        end
      end
    end
    return result, projs
  end

  local result = diff.compute(contents[1], contents[2])
  local projs = { diff.project(result.rows, "a"), diff.project(result.rows, "b") }
  if config.inline then
    for k, r in ipairs(result.rows) do
      if r.kind == "change" then
        local sp = diff.inline(contents[1][r.a], contents[2][r.b])
        projs[1][k].spans = sp.a
        projs[2][k].spans = sp.b
      end
    end
  end
  return result, projs
end

-- Precompute each conflict region's ALIGNMENT-ROW range, so `choose_*` can map the
-- cursor's row back to the conflict it sits in. A region's reconstructed-line span
-- (`recon`, per side, from `conflict.parse`) is projected through the per-pane entry
-- lists: a row belongs to the region when some pane's projected line falls inside that
-- side's span. The union's min/max over every side is the region's `{ first, last }` row
-- range (regions are disjoint and ordered, so the ranges don't overlap). Only a conflict
-- spec carries `resolve`; a plain diff is a no-op here.
local function attach_region_rows(resolve, projs)
  if not (resolve and resolve.regions) then
    return
  end
  -- Which projection (by pane index) carries which reconstructed side. A 3-pane diff is
  -- ours | base | theirs; a 2-pane (plain merge) is ours | theirs.
  local roles = #projs == 3
      and {
        { proj = projs[1], key = "ours" },
        { proj = projs[2], key = "base" },
        { proj = projs[3], key = "theirs" },
      }
    or { { proj = projs[1], key = "ours" }, { proj = projs[2], key = "theirs" } }
  for _, region in ipairs(resolve.regions) do
    local lo, hi
    for _, role in ipairs(roles) do
      local span = region.recon and region.recon[role.key]
      if span and span.from <= span.to then
        for row, e in ipairs(role.proj) do
          if e.line and e.line >= span.from and e.line <= span.to then
            lo = lo and math.min(lo, row) or row
            hi = hi and math.max(hi, row) or row
          end
        end
      end
    end
    region.rows = lo and { first = lo, last = hi } or nil
  end
end

-- open(root, spec) — build a session from a validated spec (see the contract above).
function M.open(root, spec)
  if #spec.panes ~= 2 and #spec.panes ~= 3 then
    error(("nxvim-diff: a diff needs 2 or 3 panes, got %d"):format(#spec.panes))
  end

  local contents = {}
  for i, pane in ipairs(spec.panes) do
    contents[i] = resolve(pane)
  end
  -- Intra-line spans (Phase 4) are computed inside build(), gated on config.inline (an
  -- O(len²) per-row character diff), and stashed on each side's projection entry.
  local result, projs = build(root.config, contents)
  -- Map each conflict region to the alignment rows it occupies, so `choose_*` can resolve
  -- the conflict under the cursor (a no-op for a non-conflict spec).
  attach_region_rows(spec.resolve, projs)

  local panes = {}
  for i, pane in ipairs(spec.panes) do
    local v = nx.view.create({
      -- The pane label IS the view's display name — it's what the statusline and the tab
      -- label now show (a view has no file path, so without a name it reads `[No Name]`),
      -- so each pane reads as its side ("ours" / "base" / "theirs" / "HEAD" / …).
      name = pane.label or ("pane " .. i),
      filetype = pane.filetype,
    })
    -- Closing ANY pane's window (`:q` / `:close`) tears the whole diff down: the three
    -- panes are one unit, so they come and go together. `on_close` fires only on the user
    -- close path, and `root.close()` routes through `:unmount`/`destroy` (not the user
    -- path), so closing the siblings here doesn't re-fire — no recursion.
    v:on_close(function()
      root.close()
    end)
    local proj = projs[i]
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
    -- The conflict write-back target (only a `:NxDiffConflict` spec carries it); the
    -- `choose_*` actions read it. Absent on a plain (non-conflict) diff.
    resolve = spec.resolve,
    _ready = false,
    _syncing = false, -- re-entrancy guard for the scroll/cursor mirror (nav.attach_sync)
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

  -- Move every pane to alignment `row` (a hunk jump sets all panes explicitly so it
  -- works regardless of `sync_cursor`; live scroll/cursor sync is nav.attach_sync),
  -- then restore focus to the first pane.
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
