-- Hunk navigation: ]c / [c / [C / ]C wrap-around and the "no changes" path. The nav
-- math is pure — it walks `session.hunks` against the active pane's alignment row and
-- drives the session only through `goto_row` — so a fake session (capturing the jump)
-- exercises it without the editor. Run with `nxvim --test-plugin`.

local nav = require("nxvim-diff.nav")

-- A session stand-in: a hunk list, the cursor's alignment row, and a `goto_row` that
-- records where nav jumped (nil ⇒ it chose not to jump).
local function fake(hunks, row)
  return {
    hunks = hunks,
    _row = row,
    jumped = nil,
    cursor_row = function(self)
      return self._row
    end,
    goto_row = function(self, r)
      self.jumped = r
    end,
  }
end

-- Two hunks: rows 2..3 and rows 6..6.
local function two_hunks(row)
  return fake({ { first = 2, last = 3 }, { first = 6, last = 6 } }, row)
end

nx.test.describe("nxvim-diff.nav", function()
  nx.test.it("next_hunk jumps to the first hunk that starts after the cursor", function()
    local s = two_hunks(1)
    nav.next_hunk(s)
    nx.test.expect(s.jumped).to_be(2)
  end)

  nx.test.it("next_hunk past the last hunk wraps to the first", function()
    local s = two_hunks(6)
    nav.next_hunk(s)
    nx.test.expect(s.jumped).to_be(2)
  end)

  nx.test.it("prev_hunk jumps to the last hunk that ends before the cursor", function()
    local s = two_hunks(6)
    nav.prev_hunk(s)
    nx.test.expect(s.jumped).to_be(2)
  end)

  nx.test.it("prev_hunk before the first hunk wraps to the last", function()
    local s = two_hunks(1)
    nav.prev_hunk(s)
    nx.test.expect(s.jumped).to_be(6)
  end)

  nx.test.it("first_hunk / last_hunk jump to the ends of the list", function()
    local s = two_hunks(4)
    nav.first_hunk(s)
    nx.test.expect(s.jumped).to_be(2)
    nav.last_hunk(s)
    nx.test.expect(s.jumped).to_be(6)
  end)

  nx.test.it("navigating with no changes does not jump", function()
    local s = fake({}, 1)
    nav.next_hunk(s)
    nx.test.expect(s.jumped).to_be_nil()
    nav.prev_hunk(s)
    nx.test.expect(s.jumped).to_be_nil()
    nav.first_hunk(s)
    nx.test.expect(s.jumped).to_be_nil()
  end)
end)
