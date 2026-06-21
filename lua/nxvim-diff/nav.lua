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

-- Resolve the conflict by replacing its marker block in the live buffer with the chosen
-- side's lines. Only meaningful on a `:NxDiffConflict` session (which carries
-- `session.resolve`); a plain diff has nothing to write back to and just notifies.
--
-- The write goes through the editor's one buffer-text mutation, `nx.buf.set_lines`
-- (the marker block — lines [first-1, last) 0-based — is replaced wholesale by the
-- chosen side). It targets the conflicted buffer BY ID, so it doesn't matter that the
-- diff panes hold focus; the diff is closed first only to return the user to their
-- resolved file. It is guarded: if the recorded markers are no longer where we left
-- them (the file changed under us), it aborts loud rather than corrupt the buffer.
local function resolve(session, side)
  local r = session.resolve
  if not r then
    nx.notify("nxvim-diff: not a conflict diff — nothing to resolve", 3)
    return
  end
  -- One conflict block per session today (`:NxDiffConflict` slices the first); the
  -- regions list is already shaped for a future cursor→region pick.
  local region = (r.regions or {})[1]
  if not region then
    nx.notify("nxvim-diff: no conflict region to resolve", 3)
    return
  end
  local buf, first, last = r.buf, region.first, region.last
  -- Guard: the live buffer must still carry the markers where we recorded them, else
  -- these line numbers are stale and writing would corrupt the file — refuse loud.
  local head = nx.buf.lines(buf, first - 1, first)[1] or ""
  local tail = nx.buf.lines(buf, last - 1, last)[1] or ""
  if not head:match("^<<<<<<<") or not tail:match("^>>>>>>>") then
    nx.notify("nxvim-diff: the conflict markers moved or are gone — aborting resolve", 4)
    return
  end
  local chosen = region[side] or {}

  require("nxvim-diff").close()
  -- Replace [first-1, last) (0-based, end-exclusive) — the whole marker block — with the
  -- chosen side. set_lines is async (the edit applies after this chunk); notify when it
  -- lands, and surface any refusal (a nomodifiable buffer) rather than failing silent.
  nx.buf
    .set_lines(buf, first - 1, last, true, chosen)
    :next(function()
      nx.notify("nxvim-diff: resolved conflict using " .. side)
    end)
    :catch(function(e)
      nx.notify("nxvim-diff: resolve failed: " .. tostring(e), 4)
    end)
end

function M.choose_ours(session)
  resolve(session, "ours")
end

function M.choose_theirs(session)
  resolve(session, "theirs")
end

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
