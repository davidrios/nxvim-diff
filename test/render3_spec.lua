-- Live 3-way (diff3) rendering test (Phase 6): drives the real editor — opens a 3-pane
-- diff (ours | base | theirs) via the public open() API and asserts the panes are laid
-- out side by side and center-anchored against the middle (base) pane, with the changed
-- cells tinted. Run with `nxvim --test-plugin`.

local diff = require("nxvim-diff")
local conflict = require("nxvim-diff.conflict")

local function await_ready()
  nx.await(nx.wait_for(function()
    local s = diff.session()
    return s and s._ready
  end, { tries = 200, interval = 5, message = "diff never became ready" }))
  return diff.session()
end

-- The marks on `row` (0-based) of `pane` whose details satisfy `pred`.
local function marks_where(pane, s, row, pred)
  local out = {}
  for _, m in ipairs(nx.buf.extmarks(pane.view:bufnr(), s.ns, 0, -1, { details = true })) do
    if m[2] == row and pred(m[4] or {}) then
      out[#out + 1] = m
    end
  end
  return out
end

local function pane_lines(pane)
  return table.concat(nx.buf.lines(pane.view:bufnr(), 0, -1), "|")
end

nx.test.describe("nxvim-diff 3-way render", function()
  nx.test.before_each(function()
    require("nxvim-diff").setup({})
  end)
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("lays out three panes, center-anchored on the base", function()
    -- base a,b,c ; ours changes b ; theirs changes c.
    diff.open({
      panes = {
        { label = "ours", lines = { "a", "B", "c" } },
        { label = "base", lines = { "a", "b", "c" } },
        { label = "theirs", lines = { "a", "b", "C" } },
      },
    })
    local s = await_ready()
    nx.test.expect(#s.panes).to_be(3)
    -- three distinct windows, and ONLY those three (the new tab's empty window dropped)
    nx.test.expect(#nx.win.list()).to_be(3)
    -- every pane projected to the same height, aligned on the base rows
    nx.test.expect(pane_lines(s.panes[1])).to_be("a|B|c")
    nx.test.expect(pane_lines(s.panes[2])).to_be("a|b|c")
    nx.test.expect(pane_lines(s.panes[3])).to_be("a|b|C")
  end)

  nx.test.it("tints each side's change and fills opposite an insertion", function()
    -- ours appends z ; theirs deletes the leading x.
    diff.open({
      panes = {
        { label = "ours", lines = { "x", "y", "z" } },
        { label = "base", lines = { "x", "y" } },
        { label = "theirs", lines = { "y" } },
      },
    })
    local s = await_ready()
    -- center-anchored: base shows x,y then a filler opposite ours' inserted z
    nx.test.expect(pane_lines(s.panes[2])).to_be("x|y|") -- filler is the blank
    nx.test.expect(pane_lines(s.panes[3])).to_be("|y|") -- theirs dropped x, never had z
    -- ours' inserted z (row 2, 0-based) tinted DiffAdd
    local add = marks_where(s.panes[1], s, 2, function(d)
      return d.hl_group == "DiffAdd"
    end)
    nx.test.expect(#add).to_be(1)
    -- the base line ours/theirs disagree on (x, row 0) is tinted DiffChange on the base pane
    local chg = marks_where(s.panes[2], s, 0, function(d)
      return d.hl_group == "DiffChange"
    end)
    nx.test.expect(#chg).to_be(1)
  end)

  nx.test.it("renders a diff3 conflict spec as a 3-way diff", function()
    local spec = conflict.spec({
      "common top",
      "<<<<<<< HEAD",
      "ours line",
      "||||||| base",
      "base line",
      "=======",
      "theirs line",
      ">>>>>>> branch",
      "common bottom",
    }, "f.txt")
    nx.test.expect(#spec.panes).to_be(3)
    diff.open(spec)
    local s = await_ready()
    nx.test.expect(#s.panes).to_be(3)
    nx.test.expect(pane_lines(s.panes[1])).to_be("common top|ours line|common bottom")
    nx.test.expect(pane_lines(s.panes[2])).to_be("common top|base line|common bottom")
    nx.test.expect(pane_lines(s.panes[3])).to_be("common top|theirs line|common bottom")
  end)
end)
