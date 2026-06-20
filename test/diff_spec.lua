-- The pure line-diff engine: alignment, hunks, and per-pane projection. Run with
-- `nxvim --test-plugin`. No editor state — just arrays in, alignment out.

local diff = require("nxvim-diff.diff")

local function kinds(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = r.kind
  end
  return table.concat(out, ",")
end

nx.test.describe("nxvim-diff.diff", function()
  nx.test.it("identical inputs are all `same` with no hunks", function()
    local r = diff.compute({ "a", "b" }, { "a", "b" })
    nx.test.expect(kinds(r.rows)).to_be("same,same")
    nx.test.expect(#r.hunks).to_be(0)
  end)

  nx.test.it("a pure insertion is an `add` row in one hunk", function()
    local r = diff.compute({ "a" }, { "a", "b" })
    nx.test.expect(kinds(r.rows)).to_be("same,add")
    nx.test.expect(#r.hunks).to_be(1)
    nx.test.expect(r.hunks[1].first).to_be(2)
    nx.test.expect(r.hunks[1].last).to_be(2)
  end)

  nx.test.it("a pure deletion is a `del` row", function()
    local r = diff.compute({ "a", "b" }, { "a" })
    nx.test.expect(kinds(r.rows)).to_be("same,del")
  end)

  nx.test.it("a replaced line pairs into a `change` row", function()
    local r = diff.compute({ "a", "b", "c" }, { "a", "x", "c" })
    nx.test.expect(kinds(r.rows)).to_be("same,change,same")
    nx.test.expect(#r.hunks).to_be(1)
    nx.test.expect(r.hunks[1].first).to_be(2)
  end)

  nx.test.it("projects each side to equal height with fillers", function()
    -- a → a,b : the `a` pane needs a filler opposite the inserted `b`.
    local r = diff.compute({ "a" }, { "a", "b" })
    local pa = diff.project(r.rows, "a")
    local pb = diff.project(r.rows, "b")
    nx.test.expect(#pa).to_be(#pb) -- equal height ⇒ rows line up on screen
    nx.test.expect(pa[1].line).to_be(1)
    nx.test.expect(pa[2].filler).to_be(true)
    nx.test.expect(pb[2].line).to_be(2)
  end)

  nx.test.it("inline char-diff fails loud until implemented (Phase 4)", function()
    nx.test
      .expect(function()
        diff.inline("foo", "bar")
      end)
      .to_error("not implemented")
  end)
end)
