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

  nx.test.it("ships the resolve maps and validates their action names", function()
    -- merge() runs validate(); it would raise if any default keymap named an unknown
    -- action, so reaching the asserts proves the new actions are registered.
    local cfg = config.merge(config.defaults(), {})
    nx.test.expect(cfg.keymaps["cb"]).to_be("choose_both")
    nx.test.expect(cfg.keymaps["cp"]).to_be("pick_lines")
    nx.test.expect(cfg.keymaps["ca"]).to_be("apply_picked")
    nx.test.expect(cfg.keymaps["cx"]).to_be("clear_picked")
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
