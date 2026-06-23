-- nxvim-diff.keymap — install the configured bindings on every diff pane buffer.
--
-- `cfg.keymaps` is a `key -> action` table (defaults in config.lua). Each value is:
--   a string   the name of a built-in nav action (see nav.lua / config.ACTIONS)
--   a function a custom action, called as `fn(session, api)`
--   false      disable this key (drop a default without redeclaring the table)
--
-- Every binding is buffer-local on each pane's view buffer and runs inside `api.run`
-- (the async, error-surfacing wrapper), so an action may freely nx.await.

local nav = require("nxvim-diff.nav")

local M = {}

-- install(session, api) — bind `session.config.keymaps` on every pane buffer.
function M.install(session, api)
  for _, pane in ipairs(session.panes or {}) do
    local buf = pane.view and pane.view:bufnr()
    if buf then
      for key, action in pairs(session.config.keymaps) do
        if action ~= false then
          local fn, name
          if type(action) == "function" then
            fn, name = action, "custom"
          else
            fn, name = nav[action], action
            if not fn then
              nx.notify("nxvim-diff: no built-in action '" .. tostring(action) .. "'", 4)
            end
          end
          if fn then
            -- Most actions are normal-mode; the ones in nav.VISUAL_ACTIONS (pick_lines)
            -- also bind in visual mode, since the selection IS their input. A custom
            -- function action stays normal-mode (we can't know its mode).
            local modes = { "n" }
            if type(action) == "string" and nav.VISUAL_ACTIONS[action] then
              modes[#modes + 1] = "x"
            end
            for _, mode in ipairs(modes) do
              nx.keymap.set(mode, key, function()
                api.run(function()
                  fn(session, api)
                end)
              end, { buffer = buf, desc = "nxvim-diff: " .. name })
            end
          end
        end
      end
    end
  end
end

return M
