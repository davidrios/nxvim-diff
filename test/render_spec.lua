-- Live rendering test (Phase 2): drives the real editor — opens a 2-pane diff via the
-- public open() API and asserts the panes are laid out and projected. Run with
-- `nxvim --test-plugin`. The `it` body is async (it may nx.await), so it waits on the
-- session's readiness signal before asserting.

local diff = require("nxvim-diff")

-- Wait until the open()'d session has finished rendering.
local function await_ready()
  nx.await(nx.wait_for(function()
    local s = diff.session()
    return s and s._ready
  end, { tries = 200, interval = 5, message = "diff never became ready" }))
  return diff.session()
end

nx.test.describe("nxvim-diff render", function()
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("lays out two panes, projected to equal height with fillers", function()
    diff.open({
      panes = {
        { label = "old", lines = { "same", "old", "tail" } },
        { label = "new", lines = { "same", "new", "extra", "tail" } },
      },
    })
    local s = await_ready()

    nx.test.expect(#s.panes).to_be(2)
    -- Both views exist and are shown in a window.
    nx.test.expect(s.panes[1].view:bufnr() ~= nil).to_be(true)
    nx.test.expect(s.panes[2].view:winid() ~= nil).to_be(true)

    -- The alignment: same / change(old→new) / add(extra) / same → 4 rows. Each pane
    -- is projected to that height (the `a` side gets a filler opposite the insertion).
    local a = nx.buf.lines(s.panes[1].view:bufnr(), 0, -1)
    local b = nx.buf.lines(s.panes[2].view:bufnr(), 0, -1)
    nx.test.expect(#a).to_be(4)
    nx.test.expect(#b).to_be(4)
    nx.test.expect(table.concat(a, "|")).to_be("same|old||tail") -- filler is the blank
    nx.test.expect(table.concat(b, "|")).to_be("same|new|extra|tail")
  end)

  nx.test.it("opens in a dedicated tab so the panes are side by side", function()
    diff.open({
      panes = {
        { label = "l", lines = { "x" } },
        { label = "r", lines = { "y" } },
      },
    })
    local s = await_ready()
    -- The two panes occupy two distinct windows.
    nx.test.expect(s.panes[1].view:winid() ~= s.panes[2].view:winid()).to_be(true)
    -- …and ONLY those two — the new tab's initial empty window was dropped (:only),
    -- so the diff tab is a clean 2-up split.
    nx.test.expect(#nx.win.list()).to_be(2)
  end)

  nx.test.it("resolves `path` panes by reading the files (the files source path)", function()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/a.txt", "one\ntwo\n"))
    nx.await(nx.fs.write(dir .. "/b.txt", "one\nTWO\n"))
    diff.open({
      panes = {
        { label = "a", path = dir .. "/a.txt" },
        { label = "b", path = dir .. "/b.txt" },
      },
    })
    local s = await_ready()
    local a = nx.buf.lines(s.panes[1].view:bufnr(), 0, -1)
    -- "two" → "TWO" is a change row; both sides stay 2 lines (no filler needed).
    nx.test.expect(table.concat(a, "|")).to_be("one|two")
  end)
end)
