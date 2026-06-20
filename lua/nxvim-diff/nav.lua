-- nxvim-diff.nav — hunk navigation (]c / [c …) and the pane-sync wiring.
--
-- The navigation math is pure (it walks `session.hunks` against the active pane's
-- alignment row) and drives the editor only through the session's `goto_row` method
-- and `nx.notify`, so it is ready now and exercised once view.lua builds a session.
--
-- `attach_sync` (the WinScrolled-driven scroll/cursor mirror) is the Phase 3 piece —
-- it depends on the live window ids the session owns, so it is a documented fail-loud
-- skeleton until then. It is what consumes the editor's new `WinScrolled` event and
-- `nx.win.set_topline` / `set_leftcol` / `set_cursor` seam.

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

function M.close(_session)
  require("nxvim-diff").close()
end

-- attach_sync(session) — keep the panes' viewports + cursor row locked. On the active
-- pane's `WinScrolled` (the editor event the companion core change adds), mirror its
-- topline (and leftcol, when nowrap) onto the other panes via nx.win.set_topline /
-- set_leftcol; on cursor move, mirror the row via nx.win.set_cursor. A re-entrancy
-- guard (a `session._syncing` flag) breaks the echo a programmatic scroll would cause.
-- Returns a detach function stored as `session._detach`. Phase 3.
function M.attach_sync(_session)
  error("nxvim-diff.nav.attach_sync: pane scroll/cursor sync not implemented yet (Phase 3)")
end

return M
