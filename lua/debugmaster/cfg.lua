---@class dm.Cfg
local cfg = {
  widgets = {
    -- Use snacks.nvim to render DAP widgets with borders and styling.
    use_snacks = false,
    snacks = {
      win = {
        position = "float",
        border = "rounded",
        backdrop = false,
        width = 0.5,
        height = 0.4,
        minimal = true,
        enter = true,
        wo = {
          wrap = false,
          number = false,
          relativenumber = false,
          signcolumn = "no",
        },
      },
    },
  },
}

return cfg
