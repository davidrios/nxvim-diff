-- Live scroll/cursor-sync test (Phase 3): opens a tall 2-pane diff, scrolls / moves the
-- focused pane, and asserts the other pane's viewport (`topline`/`leftcol`) and cursor
-- line follow. Exercises nav.attach_sync end-to-end — the `WinScrolled` / `CursorMoved`
-- mirror — through the real editor. Run with `nxvim --test-plugin`.

local diff = require("nxvim-diff")

-- Wait until the open()'d session has finished rendering (panes mounted, sync attached).
local function await_ready()
  nx.await(nx.wait_for(function()
    local s = diff.session()
    return s and s._ready
  end, { tries = 200, interval = 5, message = "diff never became ready" }))
  return diff.session()
end

-- A pane's current view: `topline` (1-based), `leftcol` (0-based), `lnum` (cursor line).
-- Read through nx.win.call so it resolves against THAT pane's window, focused or not.
local function view_of(pane)
  return nx.win.call(pane.view:winid(), nx.win.saveview)
end

-- N numbered lines, with line 20 differing between the sides so it's a real (aligned,
-- filler-free) change — the panes stay equal height, so a given line is the same
-- alignment row on both.
local function numbered(n, marker)
  local out = {}
  for i = 1, n do
    out[i] = (i == 20) and marker or ("line " .. i)
  end
  return out
end

local function open_tall()
  diff.open({
    panes = {
      { label = "old", lines = numbered(60, "OLD line 20") },
      { label = "new", lines = numbered(60, "NEW line 20") },
    },
  })
  return await_ready()
end

nx.test.describe("nxvim-diff scroll/cursor sync", function()
  nx.test.before_each(function()
    require("nxvim-diff").setup({})
  end)
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("disables scroll animation on the panes (so a synced scroll can't desync)", function()
    local s = open_tall()
    -- Only the focused pane animates a scroll; mirroring moves the others with a crisp
    -- jump, so the panes must not animate or they'd visibly desync mid-slide.
    for _, p in ipairs(s.panes) do
      nx.test.expect(vim.wo[p.view:winid()].scrollanim).to_be(false)
    end
  end)

  nx.test.it("mirrors a vertical scroll onto the other pane", function(t)
    local s = open_tall()

    -- Both panes start pinned to the top.
    nx.test.expect(view_of(s.panes[1]).topline).to_be(1)
    nx.test.expect(view_of(s.panes[2]).topline).to_be(1)

    -- Scroll the focused (left) pane to the bottom; the right pane follows.
    t:feed("G", { settle = 2 })
    local top = view_of(s.panes[1]).topline
    nx.test.expect(top > 1).to_be(true) -- it really scrolled off the top
    nx.test.expect(view_of(s.panes[2]).topline).to_be(top)

    -- …and back up: still locked together.
    t:feed("gg", { settle = 2 })
    nx.test.expect(view_of(s.panes[1]).topline).to_be(1)
    nx.test.expect(view_of(s.panes[2]).topline).to_be(1)
  end)

  nx.test.it("mirrors the cursor line onto the other pane", function(t)
    local s = open_tall()

    t:feed("30G", { settle = 2 })
    nx.test.expect(view_of(s.panes[1]).lnum).to_be(30)
    nx.test.expect(view_of(s.panes[2]).lnum).to_be(30)
  end)

  nx.test.it("respects sync_scroll = false (panes scroll independently)", function(t)
    require("nxvim-diff").setup({ sync_scroll = false })
    local s = open_tall()

    t:feed("G", { settle = 2 })
    nx.test.expect(view_of(s.panes[1]).topline > 1).to_be(true)
    -- The right pane was never touched.
    nx.test.expect(view_of(s.panes[2]).topline).to_be(1)
  end)

  nx.test.it("detaches the sync autocmds on close (a later scroll is inert)", function(t)
    open_tall()
    local sess = diff.session()
    nx.test.expect(type(sess._detach)).to_be("function")

    diff.close()
    nx.test.expect(diff.session()).to_be_nil()
    -- Scrolling the restored layout must not error (the autocmds are gone).
    t:feed("G", { settle = 1 })
  end)
end)
