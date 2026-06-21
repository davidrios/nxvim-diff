-- Live decoration test (Phase 4): opens a diff with a changed line and asserts the
-- extmarks the view paints — the whole-line tint and the intra-line `DiffText` spans —
-- land on the right rows with the right byte ranges. Run with `nxvim --test-plugin`.

local diff = require("nxvim-diff")

local function await_ready()
  nx.await(nx.wait_for(function()
    local s = diff.session()
    return s and s._ready
  end, { tries = 200, interval = 5, message = "diff never became ready" }))
  return diff.session()
end

-- The session-namespace extmarks on a pane buffer, as { id, row, col, details } entries.
local function marks(pane, s)
  return nx.buf.extmarks(pane.view:bufnr(), s.ns, 0, -1, { details = true })
end

-- The marks on `row` (0-based) whose details satisfy `pred`.
local function marks_where(pane, s, row, pred)
  local out = {}
  for _, m in ipairs(marks(pane, s)) do
    if m[2] == row and pred(m[4] or {}) then
      out[#out + 1] = m
    end
  end
  return out
end

-- A "same" line then a "foo()" → "bar()" change: row 2 (0-based row 1) is the change.
local function open_change()
  diff.open({
    panes = {
      { label = "old", lines = { "same", "foo()" } },
      { label = "new", lines = { "same", "bar()" } },
    },
  })
  return await_ready()
end

nx.test.describe("nxvim-diff decorations", function()
  nx.test.before_each(function()
    require("nxvim-diff").setup({})
  end)
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("tints the whole changed line with DiffChange", function()
    local s = open_change()
    local tint = marks_where(s.panes[1], s, 1, function(d)
      return d.hl_group == "DiffChange"
    end)
    nx.test.expect(#tint).to_be(1)
    nx.test.expect(tint[1][3]).to_be(0) -- starts at col 0
    nx.test.expect(tint[1][4].end_col).to_be(5) -- spans all of "foo()"
  end)

  nx.test.it("paints DiffText over only the changed characters", function()
    local s = open_change()
    -- "foo()" → "bar()": the first three bytes differ on both panes.
    for _, pane in ipairs(s.panes) do
      local text = marks_where(pane, s, 1, function(d)
        return d.hl_group == "DiffText"
      end)
      nx.test.expect(#text).to_be(1)
      nx.test.expect(text[1][3]).to_be(0) -- col 0
      nx.test.expect(text[1][4].end_col).to_be(3) -- through byte 3 ("foo"/"bar")
      nx.test.expect(text[1][4].priority > 100).to_be(true) -- above the line tint
    end
  end)

  nx.test.it("inline = false suppresses the DiffText spans (line tint stays)", function()
    require("nxvim-diff").setup({ inline = false })
    local s = open_change()
    local text = marks_where(s.panes[1], s, 1, function(d)
      return d.hl_group == "DiffText"
    end)
    nx.test.expect(#text).to_be(0)
    -- The whole-line tint is unaffected.
    local tint = marks_where(s.panes[1], s, 1, function(d)
      return d.hl_group == "DiffChange"
    end)
    nx.test.expect(#tint).to_be(1)
  end)
end)
