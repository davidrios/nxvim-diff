-- Config merge + validation. Pure (no editor state), run with `nxvim --test-plugin`.

local config = require("nxvim-diff.config")

nx.test.describe("nxvim-diff.config", function()
  nx.test.it("defaults() hands out an independent copy each call", function()
    local a = config.defaults()
    local b = config.defaults()
    a.sync_scroll = false
    a.keymaps["zz"] = "close"
    nx.test.expect(b.sync_scroll).to_be(true)
    nx.test.expect(b.keymaps["zz"]).to_be_nil()
  end)

  nx.test.it("merges scalars and merges keymaps key-by-key", function()
    local cfg = config.merge(config.defaults(), {
      wrap = true,
      keymaps = { ["gn"] = "next_hunk", ["]c"] = false },
    })
    nx.test.expect(cfg.wrap).to_be(true)
    -- the user's new key is present…
    nx.test.expect(cfg.keymaps["gn"]).to_be("next_hunk")
    -- …their disabled default survives as `false`…
    nx.test.expect(cfg.keymaps["]c"]).to_be(false)
    -- …and untouched defaults remain.
    nx.test.expect(cfg.keymaps["q"]).to_be("close")
  end)

  nx.test.it("accepts a function as a custom keymap action", function()
    local cfg = config.merge(config.defaults(), { keymaps = { ["g?"] = function() end } })
    nx.test.expect(type(cfg.keymaps["g?"])).to_be("function")
  end)

  nx.test.it("rejects an unknown action name (fails loud)", function()
    nx.test
      .expect(function()
        config.merge(config.defaults(), { keymaps = { ["z"] = "does_not_exist" } })
      end)
      .to_error("unknown action")
  end)

  nx.test.it("rejects an invalid layout", function()
    nx.test
      .expect(function()
        config.merge(config.defaults(), { layout = "diagonal" })
      end)
      .to_error("layout")
  end)

  nx.test.it("rejects a non-boolean flag", function()
    nx.test
      .expect(function()
        config.merge(config.defaults(), { sync_scroll = "yes" })
      end)
      .to_error("sync_scroll")
  end)
end)
