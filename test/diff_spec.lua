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

-- Perf guards: prefix/suffix trim + the cell-cap coarse fallback (Phase 7). The trim
-- must not change the alignment for ordinary edits; the cap must still produce a correct
-- (if coarse) result past the limit instead of building the big LCS table.
nx.test.describe("nxvim-diff.diff perf guards", function()
  local function kinds_of(a, b)
    local out = {}
    for _, r in ipairs(diff.compute(a, b).rows) do
      out[#out + 1] = r.kind
    end
    return table.concat(out, ",")
  end

  nx.test.it("trimming a shared prefix/suffix gives the same alignment as a full LCS", function()
    -- A change buried inside identical context — the common case the trim optimizes.
    local a = { "h1", "h2", "h3", "old", "f1", "f2" }
    local b = { "h1", "h2", "h3", "new", "f1", "f2" }
    nx.test.expect(kinds_of(a, b)).to_be("same,same,same,change,same,same")
  end)

  nx.test.it("an internal match inside the middle is still found under the cap", function()
    -- middle a=[X,c,Y] vs b=[c] (between shared p…s): the exact LCS keeps `c` as `same`.
    local a = { "p", "X", "c", "Y", "s" }
    local b = { "p", "c", "s" }
    nx.test.expect(kinds_of(a, b)).to_be("same,del,same,del,same")
  end)

  nx.test.it("past the cell cap the middle falls back to a coarse block-replace", function()
    local saved = diff.LCS_CELL_LIMIT
    diff.LCS_CELL_LIMIT = 2 -- middle is 3×1 = 3 cells > 2 ⇒ coarse path
    local a = { "p", "X", "c", "Y", "s" }
    local b = { "p", "c", "s" }
    -- Coarse del-run+add-run: X→c pairs into a change, then c/Y drop as dels (no LCS, so
    -- the internal `c` match is NOT recovered — the trade for staying bounded).
    nx.test.expect(kinds_of(a, b)).to_be("same,change,del,del,same")
    diff.LCS_CELL_LIMIT = saved
  end)
end)

-- 3-way (diff3) alignment: a center-anchored merge of two 2-way diffs against `base`.
nx.test.describe("nxvim-diff.diff 3-way", function()
  -- The text each pane shows for an alignment, via its projection (filler → "·").
  local function shown(rows, role, lines)
    local out = {}
    for _, e in ipairs(diff.project3(rows, role)) do
      out[#out + 1] = e.filler and "·" or lines[e.line]
    end
    return table.concat(out, "|")
  end

  nx.test.it("identical sides are all `same` with no hunks", function()
    local r = diff.compute3({ "a", "b" }, { "a", "b" }, { "a", "b" })
    nx.test.expect(kinds(r.rows)).to_be("same,same")
    nx.test.expect(#r.hunks).to_be(0)
  end)

  nx.test.it("each side modifying a different line aligns both on the base row", function()
    -- base a,b,c ; ours changes b→B ; theirs changes c→C.
    local base, ours, theirs = { "a", "b", "c" }, { "a", "B", "c" }, { "a", "b", "C" }
    local r = diff.compute3(base, ours, theirs)
    nx.test.expect(kinds(r.rows)).to_be("same,change,change")
    -- one contiguous hunk over the two changed rows
    nx.test.expect(#r.hunks).to_be(1)
    nx.test.expect(r.hunks[1].first).to_be(2)
    nx.test.expect(r.hunks[1].last).to_be(3)
    -- every pane is the same height, lines aligned by base row
    nx.test.expect(shown(r.rows, "ours", ours)).to_be("a|B|c")
    nx.test.expect(shown(r.rows, "base", base)).to_be("a|b|c")
    nx.test.expect(shown(r.rows, "theirs", theirs)).to_be("a|b|C")
    -- the changed cells carry the `change` kind; unchanged cells carry none
    local po = diff.project3(r.rows, "ours")
    nx.test.expect(po[2].kind).to_be("change")
    nx.test.expect(po[3].kind).to_be_nil()
  end)

  nx.test.it("a side insertion is an `add` row with fillers on the other panes", function()
    -- ours appends z ; theirs deletes the leading x.
    local base, ours, theirs = { "x", "y" }, { "x", "y", "z" }, { "y" }
    local r = diff.compute3(base, ours, theirs)
    -- x: theirs deleted it (change row) ; y: untouched ; z: ours inserted it (change row)
    nx.test.expect(kinds(r.rows)).to_be("change,same,change")
    nx.test.expect(#r.hunks).to_be(2)
    -- center-anchored: each pane fills opposite the others' edits
    nx.test.expect(shown(r.rows, "ours", ours)).to_be("x|y|z")
    nx.test.expect(shown(r.rows, "base", base)).to_be("x|y|·")
    nx.test.expect(shown(r.rows, "theirs", theirs)).to_be("·|y|·")
    -- the insertion cell is tagged `add`; the deletion shows as a base-side `change` tint
    local po, pb = diff.project3(r.rows, "ours"), diff.project3(r.rows, "base")
    nx.test.expect(po[3].kind).to_be("add")
    nx.test.expect(pb[1].kind).to_be("change")
  end)
end)
