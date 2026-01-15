local api = vim.api

---@class dm.ui.WatchExpressionView
---@field id integer
---@field response? dap.EvaluateResponse
---@field err? dap.ErrorResponse
---@field children? dm.ui.WatchVariableView[]
---@field expanded boolean
---@field updated boolean

---@class dm.ui.WatchVariableView
---@field variable dap.Variable
---@field err? dap.ErrorResponse
---@field updated boolean
---@field reference number
---@field expanded boolean
---@field children? dm.ui.WatchVariableView[]

---@class dm.ui.Watches: dm.ui.Sidepanel.IComponent
local Watches = {}

function Watches.new()
  ---@class dm.ui.Watches
  local self = setmetatable({}, { __index = Watches })

  self.buf = api.nvim_create_buf(false, true)
  self.name = "[W]atches"
  self.ns_id = api.nvim_create_namespace("dm_watches")

  ---@type table<string, dm.ui.WatchExpressionView>
  self.watched_expressions = {}
  ---@type table<integer, {expression: string, view: dm.ui.WatchExpressionView}>
  self.expression_views_by_line = {}
  ---@type table<integer, {parent_reference: number, variable: dap.Variable, view: dm.ui.WatchVariableView}>
  self.variable_views_by_line = {}
  self.expr_count = 0

  self:_setup_keymaps()
  self:_setup_autocmds()
  self:_setup_dap_listeners()
  self:_render_empty()

  return self
end

function Watches:_setup_keymaps()
  local opts = { buffer = self.buf, nowait = true }

  -- Toggle expand/collapse
  vim.keymap.set("n", "<CR>", function()
    self:_expand_or_collapse()
  end, opts)

  vim.keymap.set("n", "<Tab>", function()
    self:_expand_or_collapse()
  end, opts)

  -- Add new expression (append)
  vim.keymap.set("n", "a", function()
    self:_new_expression(true)
  end, opts)

  -- Insert new expression (prepend)
  vim.keymap.set("n", "i", function()
    self:_new_expression(false)
  end, opts)

  -- Delete expression
  vim.keymap.set("n", "d", function()
    self:_delete_expression()
  end, opts)

  -- Edit expression
  vim.keymap.set("n", "e", function()
    self:_edit_expression()
  end, opts)

  -- Copy expression
  vim.keymap.set("n", "c", function()
    self:_copy_expression()
  end, opts)

  -- Set value
  vim.keymap.set("n", "s", function()
    self:_set_value()
  end, opts)

  -- Refresh
  vim.keymap.set("n", "r", function()
    self:refresh()
  end, opts)
end

function Watches:_setup_autocmds()
  api.nvim_create_autocmd("User", {
    pattern = "DapSessionChanged",
    callback = vim.schedule_wrap(function()
      self:refresh()
    end)
  })
end

function Watches:_setup_dap_listeners()
  local dap = require("dap")

  -- Track the last frame_id used for evaluation
  self._last_frame_id = nil

  -- Listen for stackTrace response to detect frame changes
  -- This fires when user navigates frames (up/down) or after stopping
  dap.listeners.after.stackTrace["dm_watches"] = function(session)
    if not session then
      return
    end

    local current_frame_id = session.current_frame and session.current_frame.id

    -- Only refresh if frame actually changed and we have watched expressions
    if current_frame_id ~= self._last_frame_id and not vim.tbl_isempty(self.watched_expressions) then
      self._last_frame_id = current_frame_id
      vim.schedule(function()
        self:refresh()
      end)
    end
  end

  -- Also listen for stopped event to ensure watches are refreshed when stepping
  dap.listeners.after.event_stopped["dm_watches"] = function(session)
    if session and not vim.tbl_isempty(self.watched_expressions) then
      self._last_frame_id = session.current_frame and session.current_frame.id
      vim.schedule(function()
        self:refresh()
      end)
    end
  end

  -- Clean up frame tracking when session ends
  dap.listeners.before.event_terminated["dm_watches"] = function()
    self._last_frame_id = nil
  end

  dap.listeners.before.disconnect["dm_watches"] = function()
    self._last_frame_id = nil
  end
end

function Watches:_render_empty()
  api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  api.nvim_buf_set_lines(self.buf, 0, -1, false, {
    "No expressions.",
    "",
    "Press 'a' to add, '?' for help."
  })
  api.nvim_set_option_value("modifiable", false, { buf = self.buf })
end

---@return boolean
function Watches:_expect_stopped()
  local session = require("dap").session()
  if not session then
    vim.notify("No active debug session")
    return false
  end
  if not session.stopped_thread_id then
    vim.notify("Session is not stopped")
    return false
  end
  return true
end

---@param expression string
---@param default_expanded boolean
---@param id? integer
function Watches:_evaluate_expression(expression, default_expanded, id)
  local session = require("dap").session()
  if not session then
    return
  end

  local frame_id = session.current_frame and session.current_frame.id

  local err, response = session:request("evaluate", {
    expression = expression,
    context = "watch",
    frameId = frame_id
  })

  local previous_expression_view = self.watched_expressions[expression]

  local previous_result = previous_expression_view
      and previous_expression_view.response
      and previous_expression_view.response.result

  if previous_expression_view and response then
    previous_expression_view.updated = previous_result ~= response.result
  end

  if previous_expression_view and err then
    previous_expression_view.children = nil
    previous_expression_view.updated = false
    previous_expression_view.expanded = false
  end

  ---@type dm.ui.WatchExpressionView
  local default_expression_view = {
    id = id or self.expr_count,
    response = response,
    err = err,
    updated = false,
    expanded = default_expanded,
    children = nil,
  }

  if previous_expression_view then
    previous_expression_view.response = response
    previous_expression_view.err = err
  end

  ---@type dm.ui.WatchExpressionView
  local new_expression_view = previous_expression_view or default_expression_view

  if new_expression_view.expanded then
    local variables_reference = response and response.variablesReference

    if variables_reference and variables_reference > 0 then
      new_expression_view.children = self:_expand_variable(variables_reference, new_expression_view.children)
    else
      new_expression_view.children = nil
    end
  end

  self.watched_expressions[expression] = new_expression_view
end

---@param variables_reference number
---@param previous_expansion_result? dm.ui.WatchVariableView[]
---@return dm.ui.WatchVariableView[]|nil
---@return dap.ErrorResponse|nil
function Watches:_expand_variable(variables_reference, previous_expansion_result)
  local session = require("dap").session()
  if not session then
    return nil, nil
  end

  local frame_id = session.current_frame and session.current_frame.id

  local err, response = session:request("variables", {
    variablesReference = variables_reference,
    context = "watch",
    frameId = frame_id
  })

  local response_variables = response and response.variables

  ---@type dm.ui.WatchVariableView[]
  local variable_views = {}

  for k, variable in ipairs(response_variables or {}) do
    ---@type dm.ui.WatchVariableView?
    local previous_variable_view = vim.iter(previous_expansion_result or {}):find(
      function(v)
        if v.variable.evaluateName then
          return v.variable.evaluateName == variable.evaluateName
        end
        if v.variable.variablesReference > 0 then
          return v.variable.variablesReference == variable.variablesReference
        end
      end
    )

    if previous_variable_view then
      if err then
        previous_variable_view.children = nil
        previous_variable_view.expanded = false
        previous_variable_view.updated = false
      else
        previous_variable_view.updated = previous_variable_view.variable.value ~= variable.value
        previous_variable_view.variable = variable
      end
    end

    ---@type dm.ui.WatchVariableView
    local default_variable_view = {
      variable = variable,
      updated = false,
      expanded = false,
      children = nil,
      reference = variable.variablesReference,
    }

    ---@type dm.ui.WatchVariableView
    local new_variable_view = previous_variable_view or default_variable_view

    local var_ref = variable.variablesReference

    if new_variable_view.expanded then
      if var_ref > 0 then
        new_variable_view.children, new_variable_view.err = self:_expand_variable(var_ref, new_variable_view.children)
      else
        new_variable_view.children = nil
      end
    end

    variable_views[k] = new_variable_view
  end

  return #variable_views > 0 and variable_views or nil, err
end

---@param expr string
---@param default_expanded boolean
---@param append? boolean
---@return boolean
function Watches:add_watch_expr(expr, default_expanded, append)
  if #expr == 0 or not self:_expect_stopped() then
    return false
  end

  self:_evaluate_expression(expr, default_expanded, (append and 1 or -1) * self.expr_count)

  self.expr_count = self.expr_count + 1

  return true
end

---@param line number
---@return {expression: string, view: dm.ui.WatchExpressionView}|nil
function Watches:_remove_watch_expr(line)
  local expression_view = self.expression_views_by_line[line]

  if expression_view then
    self.watched_expressions[expression_view.expression] = nil
    return expression_view
  else
    vim.notify("No expression under cursor")
    return nil
  end
end

function Watches:_new_expression(append)
  vim.ui.input({ prompt = "Expression: " }, function(input)
    if input then
      coroutine.wrap(function()
        if self:add_watch_expr(input, false, append) then
          self:render()
        end
      end)()
    end
  end)
end

function Watches:_delete_expression()
  local cursor_line = api.nvim_win_get_cursor(0)[1]
  self:_remove_watch_expr(cursor_line)
  self:render()
end

function Watches:_edit_expression()
  local cursor_line = api.nvim_win_get_cursor(0)[1]
  local expression_view = self.expression_views_by_line[cursor_line]

  if expression_view then
    vim.ui.input({ prompt = "Expression: ", default = expression_view.expression }, function(input)
      if input then
        coroutine.wrap(function()
          -- Delete old and insert new
          local old_view = self:_remove_watch_expr(cursor_line)
          if old_view and self:_expect_stopped() then
            self:_evaluate_expression(input, old_view.view.expanded)
            self:render()
          end
        end)()
      end
    end)
  else
    vim.notify("No expression under cursor")
  end
end

function Watches:_copy_expression()
  local cursor_line = api.nvim_win_get_cursor(0)[1]
  local expression_view = self.expression_views_by_line[cursor_line]

  if expression_view then
    vim.fn.setreg("+", expression_view.expression)
    vim.notify("Expression copied: " .. expression_view.expression)
  else
    local variable_view = self.variable_views_by_line[cursor_line]
    if variable_view then
      local evaluate_name = variable_view.variable.evaluateName
      if evaluate_name then
        vim.fn.setreg("+", evaluate_name)
        vim.notify("Variable copied: " .. evaluate_name)
      else
        vim.notify("Missing evaluateName, can't copy variable")
      end
    else
      vim.notify("No expression or variable under cursor")
    end
  end
end

function Watches:_set_value()
  if not self:_expect_stopped() then
    return
  end

  local cursor_line = api.nvim_win_get_cursor(0)[1]
  local expression_view = self.expression_views_by_line[cursor_line]

  if expression_view then
    local default_value = expression_view.view.response and expression_view.view.response.result or ""
    vim.ui.input({ prompt = "New value: ", default = default_value }, function(value)
      if value then
        coroutine.wrap(function()
          local session = require("dap").session()
          if session and session.capabilities.supportsSetExpression then
            local frame_id = session.current_frame and session.current_frame.id
            local err, _ = session:request("setExpression", {
              expression = expression_view.expression,
              value = value,
              frameId = frame_id
            })
            if err then
              vim.notify("Failed to set expression: " .. tostring(err))
            else
              self:refresh()
            end
          else
            vim.notify("Adapter doesn't support setExpression")
          end
        end)()
      end
    end)
  else
    local variable_view = self.variable_views_by_line[cursor_line]
    if variable_view then
      local default_value = variable_view.variable.value or ""
      vim.ui.input({ prompt = "New value: ", default = default_value }, function(value)
        if value then
          coroutine.wrap(function()
            local session = require("dap").session()
            if session then
              local err, _ = session:request("setVariable", {
                variablesReference = variable_view.parent_reference,
                name = variable_view.variable.name,
                value = value
              })
              if err then
                vim.notify("Failed to set variable: " .. tostring(err))
              else
                self:refresh()
              end
            end
          end)()
        end
      end)
    else
      vim.notify("No expression or variable under cursor")
    end
  end
end

function Watches:_expand_or_collapse()
  if not self:_expect_stopped() then
    return
  end

  local cursor_line = api.nvim_win_get_cursor(0)[1]
  local expression_view = self.expression_views_by_line[cursor_line]

  if expression_view then
    expression_view.view.expanded = not expression_view.view.expanded

    coroutine.wrap(function()
      self:_evaluate_expression(expression_view.expression, true)
      self:render()
    end)()
  else
    local variable_view = self.variable_views_by_line[cursor_line]
    if variable_view then
      local reference = variable_view.variable.variablesReference

      if reference > 0 then
        variable_view.view.expanded = not variable_view.view.expanded

        coroutine.wrap(function()
          variable_view.view.children, variable_view.view.err = self:_expand_variable(reference)
          self:render()
        end)()
      else
        vim.notify("Nothing to expand")
      end
    else
      vim.notify("No expression or variable under cursor")
    end
  end
end

-- Highlight groups
local hl_types = {
  string = "String",
  number = "Number",
  float = "Float",
  integer = "Number",
  boolean = "Boolean",
  bool = "Boolean",
  ["nil"] = "Constant",
  ["null"] = "Constant",
  ["function"] = "Function",
  table = "Type",
  object = "Type",
  array = "Type",
}

---@param children dm.ui.WatchVariableView[]
---@param reference number
---@param line integer
---@param depth integer
---@return integer
function Watches:_show_variables(children, reference, line, depth)
  for _, child in ipairs(children) do
    local variable = child.variable
    local show_expand_hint = #variable.value == 0 and variable.variablesReference > 0
    local value = show_expand_hint and "..." or variable.value
    local content = variable.name .. " = " .. value

    -- Can't have linebreaks with nvim_buf_set_lines
    local trimmed_content = content:gsub("%s+", " ")
    local indented_content = string.rep("\t", depth) .. trimmed_content

    api.nvim_buf_set_lines(self.buf, line, line, true, { indented_content })

    -- Highlight variable name (tab counts as 1 char in buffer)
    local name_start = depth
    local name_end = name_start + #variable.name
    api.nvim_buf_add_highlight(self.buf, self.ns_id, "Identifier", line, name_start, name_end)

    -- Highlight value
    local hl_group = (show_expand_hint and "Comment")
        or (child.updated and "DiagnosticWarn")
        or (variable.type and hl_types[variable.type:lower()])

    if hl_group then
      local hl_start = name_end + 3 -- " = "
      api.nvim_buf_add_highlight(self.buf, self.ns_id, hl_group, line, hl_start, -1)
    end

    line = line + 1

    self.variable_views_by_line[line] = {
      parent_reference = reference,
      variable = variable,
      view = child
    }

    if child.err then
      local err_content = string.rep("\t", depth + 1) .. tostring(child.err)
      api.nvim_buf_set_lines(self.buf, line, line, true, { err_content })
      api.nvim_buf_add_highlight(self.buf, self.ns_id, "DiagnosticError", line, 0, #err_content)
      line = line + 1
    end

    if child.expanded and child.children ~= nil then
      line = self:_show_variables(child.children, child.reference, line, depth + 1)
    end
  end
  return line
end

function Watches:render()
  -- Clear line mappings
  for k, _ in pairs(self.expression_views_by_line) do
    self.expression_views_by_line[k] = nil
  end
  for k, _ in pairs(self.variable_views_by_line) do
    self.variable_views_by_line[k] = nil
  end

  if vim.tbl_isempty(self.watched_expressions) then
    self:_render_empty()
    return
  end

  api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  api.nvim_buf_clear_namespace(self.buf, self.ns_id, 0, -1)

  local line = 0

  -- Sort expressions to keep a "stable" experience
  ---@type [string, dm.ui.WatchExpressionView][]
  local expressions = vim.iter(self.watched_expressions)
      :map(function(k, v)
        return { k, v }
      end)
      :totable()

  table.sort(
    expressions,
    function(lhs, rhs)
      return lhs[2].id < rhs[2].id
    end
  )

  for _, expression_view in ipairs(expressions) do
    local expression, view = unpack(expression_view)
    local response = view.response
    local err = view.err

    local result = response and response.result or err and tostring(err)

    local content = expression .. " = " .. (result or "")
    local trimmed_content = content:gsub("%s+", " ")

    api.nvim_buf_set_lines(self.buf, line, line, true, { trimmed_content })

    -- Highlight expression name
    api.nvim_buf_add_highlight(self.buf, self.ns_id, "Function", line, 0, #expression)

    -- Highlight value/error
    local hl_group = err and "DiagnosticError"
        or view.updated and "DiagnosticWarn"
        or response and response.type and hl_types[response.type:lower()]

    if hl_group then
      local hl_start = #expression + 3
      api.nvim_buf_add_highlight(self.buf, self.ns_id, hl_group, line, hl_start, -1)
    end

    line = line + 1

    self.expression_views_by_line[line] = { expression = expression, view = view }

    if err == nil and view.children ~= nil and view.expanded and response ~= nil then
      line = self:_show_variables(view.children, response.variablesReference, line, 1)
    end
  end

  -- Clear remaining lines
  api.nvim_buf_set_lines(self.buf, line, -1, true, {})
  api.nvim_set_option_value("modifiable", false, { buf = self.buf })
end

function Watches:refresh()
  if vim.tbl_isempty(self.watched_expressions) then
    self:_render_empty()
    return
  end

  coroutine.wrap(function()
    for expression, _ in pairs(self.watched_expressions) do
      self:_evaluate_expression(expression, false)
    end
    self:render()
  end)()
end

--- Add the word/expression under cursor from any buffer to watches
---@param expr? string Optional expression, if nil will use expression under cursor
function Watches:add_cursor_expr(expr)
  local expression = expr
  if not expression then
    -- Try to get visual selection first
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' then
      -- Exit visual mode to get accurate marks
      local keys = api.nvim_replace_termcodes("<Esc>", true, true, true)
      api.nvim_feedkeys(keys, "x", false)
      expression = self:_get_visual_selection()
    else
      -- Use <cexpr> to capture full C-style expressions like abc[12], foo.bar, etc.
      expression = vim.fn.expand("<cexpr>")
    end
  end

  if expression and #expression > 0 then
    coroutine.wrap(function()
      if self:add_watch_expr(expression, false, true) then
        self:render()
      end
    end)()
  else
    vim.notify("No expression to add")
  end
end

---@return string
function Watches:_get_visual_selection()
  local start = vim.fn.getpos("'<")
  local finish = vim.fn.getpos("'>")

  local start_line, start_col = start[2], start[3]
  local finish_line, finish_col = finish[2], finish[3]

  -- Swap if selection is backwards
  if start_line > finish_line or (start_line == finish_line and start_col > finish_col) then
    start_line, start_col, finish_line, finish_col = finish_line, finish_col, start_line, start_col
  end

  local lines = vim.fn.getline(start_line, finish_line)
  if #lines == 0 then
    return ""
  end

  -- Handle single line case
  if #lines == 1 then
    return vim.trim(string.sub(lines[1], start_col, finish_col))
  end

  -- Multi-line: trim first and last line boundaries
  lines[1] = string.sub(lines[1], start_col)
  lines[#lines] = string.sub(lines[#lines], 1, finish_col)

  -- Join and trim whitespace
  return vim.iter(lines)
      :map(function(line) return vim.trim(line) end)
      :fold("", function(acc, line) return acc .. line end)
end

return Watches

