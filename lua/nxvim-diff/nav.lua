-- nxvim-diff.nav — hunk navigation (]c / [c …) and the pane-sync wiring.
--
-- The navigation math is pure (it walks `session.hunks` against the active pane's
-- alignment row) and drives the editor only through the session's `goto_row` method
-- and `nx.notify`, so it is ready now and exercised once view.lua builds a session.
--
-- `attach_sync` (the WinScrolled-driven scroll/cursor mirror) keeps the panes' viewports
-- and cursor row locked. It consumes the editor's `WinScrolled` / `CursorMoved` events
-- and the `nx.win.set_topline` / `set_leftcol` / `set_cursor` seam; see its own header.

local M = {}

-- Find the hunk to jump to from the active pane's current alignment row. Wraps around.
local function seek(session, dir)
  local hunks = session.hunks or {}
  if #hunks == 0 then
    return nil
  end
  local row = session:cursor_row()
  if dir > 0 then
    for _, h in ipairs(hunks) do
      if h.first > row then
        return h
      end
    end
    return hunks[1] -- past the last hunk → wrap to the first
  else
    for i = #hunks, 1, -1 do
      if hunks[i].last < row then
        return hunks[i]
      end
    end
    return hunks[#hunks] -- before the first hunk → wrap to the last
  end
end

local function jump(session, h)
  if h then
    session:goto_row(h.first)
  else
    nx.notify("nxvim-diff: no changes to navigate")
  end
end

function M.next_hunk(session)
  jump(session, seek(session, 1))
end

function M.prev_hunk(session)
  jump(session, seek(session, -1))
end

function M.first_hunk(session)
  jump(session, (session.hunks or {})[1])
end

function M.last_hunk(session)
  local hunks = session.hunks or {}
  jump(session, hunks[#hunks])
end

function M.refresh(session)
  if session.reopen then
    session.reopen()
  end
end

-- ===== conflict resolution (:NxDiffConflict sessions only) ==================
--
-- The resolve actions all write a chosen set of lines back over the conflict's marker
-- block in the live buffer and close the diff: `choose_ours`/`choose_theirs` pick one
-- side, `choose_both` keeps both, and `pick_lines`/`apply_picked` compose a resolution by
-- hand. They share `current_region` (which conflict) and `write_back` (the guarded edit).
--
-- region_at(session, row) — the conflict region the cursor sits in (the diff shows every
-- conflict of the file at once). A region carries the alignment-row range it occupies
-- (`region.rows`, computed in view.lua); the cursor's row picks it. When the cursor is
-- between conflicts (on shared context), the NEAREST region by row distance is chosen — so
-- the actions always act on the conflict you're closest to, as you'd expect after a
-- `]c`/`[c` jump.
local function region_at(session, row)
  local regions = (session.resolve and session.resolve.regions) or {}
  for _, region in ipairs(regions) do
    if region.rows and row >= region.rows.first and row <= region.rows.last then
      return region
    end
  end
  local best, best_dist
  for _, region in ipairs(regions) do
    if region.rows then
      local dist = math.min(math.abs(row - region.rows.first), math.abs(row - region.rows.last))
      if not best_dist or dist < best_dist then
        best, best_dist = region, dist
      end
    end
  end
  return best
end

-- The conflict region under the cursor, or nil after notifying WHY there isn't one (a
-- plain diff has no `resolve` target; the cursor may be nowhere near a region). Shared by
-- every resolve action so they agree on "which conflict" and on the failure notices.
local function current_region(session)
  if not session.resolve then
    nx.notify("nxvim-diff: not a conflict diff — nothing to resolve", 4)
    return nil
  end
  -- Pick the conflict the cursor is in (or nearest); the diff shows them all at once.
  local region = region_at(session, session:cursor_row())
  if not region then
    nx.notify("nxvim-diff: no conflict region to resolve", 4)
  end
  return region
end

-- The diff pane that currently holds focus (falls back to the first pane). Picking lines
-- reads from whichever side the cursor is in.
local function focused_pane(session)
  local cur = nx.win.current()
  for _, p in ipairs(session.panes) do
    if p.view:winid() == cur then
      return p
    end
  end
  return session.panes[1]
end

-- Replace `region`'s marker block in the live conflicted buffer with `lines`, then close
-- the diff so the user lands back on the resolved file. `label` names the choice in the
-- notice. Guarded: if the recorded markers are no longer where we left them (the file
-- changed under us), it aborts loud rather than corrupt the buffer.
--
-- The write goes through the editor's one buffer-text mutation, `nx.buf.set_lines`. It
-- targets the conflicted buffer BY ID, so it doesn't matter that the diff panes hold
-- focus; the diff is closed first only to return the user to their file.
local function write_back(session, region, lines, label)
  local buf, first, last = session.resolve.buf, region.first, region.last
  -- Guard: the live buffer must still carry the markers where we recorded them, else
  -- these line numbers are stale and writing would corrupt the file — refuse loud.
  local head = nx.buf.lines(buf, first - 1, first)[1] or ""
  local tail = nx.buf.lines(buf, last - 1, last)[1] or ""
  if not head:match("^<<<<<<<") or not tail:match("^>>>>>>>") then
    nx.notify("nxvim-diff: the conflict markers moved or are gone — aborting resolve", 4)
    return
  end

  require("nxvim-diff").close()
  -- Replace [first-1, last) (0-based, end-exclusive) — the whole marker block — with the
  -- chosen lines. set_lines is async (the edit applies after this chunk); notify when it
  -- lands, and surface any refusal (a nomodifiable buffer) rather than failing silent.
  nx.buf
    .set_lines(buf, first - 1, last, true, lines)
    :next(function()
      nx.notify("nxvim-diff: resolved conflict using " .. label)
    end)
    :catch(function(e)
      nx.notify("nxvim-diff: resolve failed: " .. tostring(e), 4)
    end)
end

local function resolve(session, side)
  local region = current_region(session)
  if region then
    write_back(session, region, region[side] or {}, side)
  end
end

function M.choose_ours(session)
  resolve(session, "ours")
end

function M.choose_theirs(session)
  resolve(session, "theirs")
end

-- choose_both — keep BOTH sides, ours then theirs (the left-to-right reading order), with
-- the conflict markers dropped. The common "accept both" resolution.
function M.choose_both(session)
  local region = current_region(session)
  if not region then
    return
  end
  local both = {}
  for _, line in ipairs(region.ours or {}) do
    both[#both + 1] = line
  end
  for _, line in ipairs(region.theirs or {}) do
    both[#both + 1] = line
  end
  write_back(session, region, both, "both sides")
end

-- pick_lines — stage the focused pane's conflict lines over the selected range into the
-- under-cursor conflict's pick list, to compose a resolution by hand from either side.
-- Bound in BOTH normal and visual mode (the keymap installer widens it via
-- nav.VISUAL_ACTIONS): in normal mode it stages the cursor's row, in visual mode the whole
-- selection. Only the conflict's OWN lines qualify — shared context outside the region (not
-- part of the diff) and blank filler rows are refused — and each staged row gets a pick
-- gutter sign (session:render_picks). Picks accumulate in the order made; `apply_picked`
-- writes them back, `clear_picked` discards them.
function M.pick_lines(session)
  local region = current_region(session)
  if not region then
    return
  end
  local pane = focused_pane(session)
  -- The selected alignment-row range. The base is the focused pane's cursor row (the
  -- editor-agnostic `view:line()`, the same accessor the rest of nav uses). In visual mode
  -- we widen to the selection: `line("v")` is the other end of the selection (and equals
  -- the cursor row when not visual). It's guarded so an absent `line("v")` degrades to
  -- picking the current row rather than erroring.
  local cur = session:cursor_row()
  local from, to = cur, cur
  local ok, other = pcall(vim.fn.line, "v")
  if ok and type(other) == "number" and other > 0 then
    from, to = math.min(cur, other), math.max(cur, other)
  end
  -- Drop back to normal mode so the next pick (often from another pane) starts clean.
  local _, mode = pcall(vim.fn.mode)
  if type(mode) == "string" and mode:match("^[vV\22]") then
    pcall(vim.cmd, "normal! \27")
  end

  -- Only the conflict's own lines may be staged — a row outside the region's alignment-row
  -- range (`region.rows`) is shared context, NOT part of the diff, so it must not go into a
  -- resolution. Filler (alignment-gap) rows carry no real text and are skipped too. What's
  -- left is exactly the lines this pane actually contributes to the conflict.
  local rows = region.rows
  region.picks = region.picks or {}
  local added, skipped = 0, 0
  for row = from, to do
    local e = pane.proj[row]
    if e and not e.filler then
      if rows and row >= rows.first and row <= rows.last then
        region.picks[#region.picks + 1] = { side = pane.side, row = row, text = pane.text[row] }
        added = added + 1
      else
        skipped = skipped + 1
      end
    end
  end
  session:render_picks()

  if added == 0 then
    local why = skipped > 0 and "those lines aren't part of the conflict"
      or "no lines to pick here"
    nx.notify("nxvim-diff: " .. why .. " — pick within the highlighted block", 4)
    return
  end
  local extra = skipped > 0 and (" (skipped %d outside the conflict)"):format(skipped) or ""
  nx.notify(
    ("nxvim-diff: picked %d line(s) from %s (%d staged)%s"):format(
      added,
      pane.label or pane.side,
      #region.picks,
      extra
    )
  )
end

-- apply_picked — resolve the under-cursor conflict with the lines staged by pick_lines, in
-- the order they were picked.
function M.apply_picked(session)
  local region = current_region(session)
  if not region then
    return
  end
  if not (region.picks and #region.picks > 0) then
    nx.notify("nxvim-diff: no lines picked yet — select lines and use pick_lines first", 4)
    return
  end
  local lines = {}
  for _, pick in ipairs(region.picks) do
    lines[#lines + 1] = pick.text
  end
  write_back(session, region, lines, "picked lines")
end

-- clear_picked — discard the lines staged for the under-cursor conflict (start over) and
-- wipe their gutter signs.
function M.clear_picked(session)
  local region = current_region(session)
  if not region then
    return
  end
  region.picks = nil
  session:render_picks()
  nx.notify("nxvim-diff: cleared picked lines")
end

-- The cursor→region mapper, exposed for tests (pure: reads region.rows + a row number).
M._region_at = region_at

-- The built-in actions that also bind in visual mode (the selection IS the input). The
-- keymap installer reads this to widen those bindings beyond normal mode.
M.VISUAL_ACTIONS = { pick_lines = true }

function M.close(_session)
  require("nxvim-diff").close()
end

-- attach_sync(session) — keep the panes' viewports + cursor row locked together, the
-- way Meld scrollbinds its sides. Registers two autocmds (dropped by the returned
-- detach):
--
--   * `WinScrolled` — when one pane scrolls, copy its `topline` (and `leftcol`, unless
--     wrapping) onto the other panes via nx.win.set_topline / set_leftcol.
--   * `CursorMoved` — when the focused pane's cursor moves, mirror its line onto the
--     others via nx.win.set_cursor. The projection is 1:1 (a pane's view line number
--     IS the alignment row, fillers included), so the aligned cursor is simply the
--     same line on every pane — no cross-filler remapping needed.
--
-- Breaking the echo: a programmatic `set_topline` re-fires `WinScrolled` for the moved
-- window on the next diff (the core rebases its scroll baseline to the *pre-callback*
-- offsets on purpose, so the plugin owns its own loop). The mirror is therefore
-- compare-and-set — a pane already at the source's topline is skipped — so that
-- re-fire produces no new ops and the cascade dies out after one harmless round. The
-- `session._syncing` flag is the belt-and-suspenders synchronous guard. Cursor mirroring
-- needs no such care: setting a *non-focused* window's cursor neither steals focus nor
-- re-fires `CursorMoved` (only the focused window's motion does).
function M.attach_sync(session)
  -- The diff pane showing window `win` (nil if `win` isn't one of our panes).
  local function pane_for_win(win)
    for _, p in ipairs(session.panes) do
      if p.view:winid() == win then
        return p
      end
    end
    return nil
  end

  -- The mounted windows of every pane other than `win`.
  local function other_wins(win)
    local out = {}
    for _, p in ipairs(session.panes) do
      local w = p.view:winid()
      if w and w ~= win then
        out[#out + 1] = w
      end
    end
    return out
  end

  local ids = {}

  if session.config.sync_scroll then
    ids[#ids + 1] = nx.autocmd.create("WinScrolled", {
      callback = function(args)
        if session._syncing then
          return
        end
        local win = tonumber(args.match)
        if not win or not pane_for_win(win) then
          return -- a scroll in some unrelated window — ignore
        end
        session._syncing = true
        local src = nx.win.call(win, nx.win.saveview)
        for _, w in ipairs(other_wins(win)) do
          local cur = nx.win.call(w, nx.win.saveview)
          if cur.topline ~= src.topline then
            nx.win.set_topline(w, src.topline)
          end
          if not session.config.wrap and cur.leftcol ~= src.leftcol then
            nx.win.set_leftcol(w, src.leftcol)
          end
        end
        session._syncing = false
      end,
    })
  end

  if session.config.sync_cursor then
    ids[#ids + 1] = nx.autocmd.create("CursorMoved", {
      callback = function()
        if session._syncing then
          return
        end
        local win = nx.win.current()
        if not pane_for_win(win) then
          return
        end
        local row = session:cursor_row()
        session._syncing = true
        for _, w in ipairs(other_wins(win)) do
          nx.win.set_cursor(w, row)
        end
        session._syncing = false
      end,
    })
  end

  session._detach = function()
    for _, id in ipairs(ids) do
      pcall(nx.autocmd.del, id)
    end
    session._detach = nil
  end
  return session._detach
end

return M
