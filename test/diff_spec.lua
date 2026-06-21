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

  nx.test.it("inline char-diff marks only the changed spans", function()
    -- "foo()" → "bar()": the first three chars differ, "()" is the common tail.
    local sp = diff.inline("foo()", "bar()")
    nx.test.expect(sp.a).to_equal({ { 0, 3 } })
    nx.test.expect(sp.b).to_equal({ { 0, 3 } })
  end)

  nx.test.it("inline reports a mid-line insertion as a b-only span", function()
    -- "ac" → "abc": 'b' inserted at byte 1 on the b side; the a side is unchanged.
    local sp = diff.inline("ac", "abc")
    nx.test.expect(sp.a).to_equal({})
    nx.test.expect(sp.b).to_equal({ { 1, 2 } })
  end)

  nx.test.it("inline ranges are byte offsets over whole UTF-8 characters", function()
    -- "café" → "cafe": only the last char differs. 'é' is 2 bytes (3..5), 'e' is 1 (3..4)
    -- — the span must not split the multibyte character.
    local sp = diff.inline("café", "cafe")
    nx.test.expect(sp.a).to_equal({ { 3, 5 } })
    nx.test.expect(sp.b).to_equal({ { 3, 4 } })
  end)

  nx.test.it("inline coalesces adjacent changed characters into one span", function()
    -- "abcd" → "axyd": 'bc' → 'xy' is one contiguous edit, not two single-char spans.
    local sp = diff.inline("abcd", "axyd")
    nx.test.expect(sp.a).to_equal({ { 1, 3 } })
    nx.test.expect(sp.b).to_equal({ { 1, 3 } })
  end)
end)
