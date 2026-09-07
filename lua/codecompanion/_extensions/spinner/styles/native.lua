-- A highly configurable spinner using Neovim's built-in nvim_open_win.
--
-- This spinner creates a floating window with full user control over its
-- appearance and behavior. It uses only built-in Neovim features and provides
-- maximum configurability for advanced users.
local M = {}

local config = require("codecompanion._extensions.spinner.config")
local tracker = require("codecompanion._extensions.spinner.tracker")

-- State mapping for content
local state_map = tracker.state_map

-- Holds the state of the floating window
local ui = {
  timer = nil,
  win = nil,
  buf = nil,
  frame = 1,
  current_state = tracker.State.IDLE,
  close_token = 0,
}

local animations = {
  default = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  interval = 80,
}

local function get_title_text(content, is_spinning)
  local current_config = require("codecompanion._extensions.spinner.config")
  local default_icon = current_config.get().default_icon
  local title = current_config.get().native.window.title

  if is_spinning then
    local frame_char = animations.default[ui.frame]
    return string.format(" %s %s ", frame_char, title)
  else
    return string.format(" %s%s%s ", default_icon, content.spacing, title)
  end
end

local function get_window_icon(content, _is_spinning)
  local current_config = require("codecompanion._extensions.spinner.config")
  local default_icon = current_config.get().default_icon

  -- Use default icon for thinking state, otherwise use state-specific icon
  if content.message:find("Thinking") then
    return default_icon
  else
    return content.icon
  end
end

local function close_window()
  if ui.timer then
    ui.timer:stop()
    ui.timer:close()
    ui.timer = nil
  end
  if ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
    pcall(vim.api.nvim_buf_delete, ui.buf, { force = true })
    ui.buf = nil
  end
  if ui.win and vim.api.nvim_win_is_valid(ui.win) then
    vim.api.nvim_win_close(ui.win, false)
    ui.win = nil
  end
  ui.frame = 1

  -- Force redraw to ensure the window is closed visually
  vim.cmd("redraw!")
end

--- Recomputes the window position from the current editor size.
--- Only editor-relative windows are re-anchored: "win"/"cursor" anchored
--- windows already track their anchor, and their row/col have a different
--- meaning. User-pinned row/col are kept as-is.
--- @param win number The window handle to reposition.
local function reposition_window(win)
  local window_config = (config.get().native or {}).window or {}
  if (window_config.relative or "editor") ~= "editor" then
    return
  end
  local row = window_config.row
  local col = window_config.col
  if row == nil then
    row = vim.o.lines - 5
  end
  if col == nil then
    col = vim.o.columns - 35
  end
  -- 'relative' is required when passing row/col to nvim_win_set_config.
  pcall(vim.api.nvim_win_set_config, win, { relative = "editor", row = row, col = col })
end

local function update_spinner_display()
  if not (ui.win and vim.api.nvim_win_is_valid(ui.win) and ui.buf and vim.api.nvim_buf_is_valid(ui.buf)) then
    close_window()
    return
  end

  local state_name = state_map[ui.current_state] or "idle"
  local content = config.get_content_for_state(state_name)
  local title_text = get_title_text(content, true)
  local window_icon = get_window_icon(content, true)
  local window_text = string.format(" %s%s%s ", window_icon, content.spacing, content.message)

  -- Update window title with animation
  pcall(vim.api.nvim_win_set_config, ui.win, { title = title_text })

  -- Update window content with icon and message
  pcall(vim.api.nvim_buf_set_lines, ui.buf, 0, -1, false, { window_text })

  -- Advance animation frame
  ui.frame = (ui.frame % #animations.default) + 1
end

local function start_spinner()
  if ui.timer then
    return -- Already running
  end

  -- Get native configuration
  local native_config = config.get().native or {}

  if ui.win and vim.api.nvim_win_is_valid(ui.win) and ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
    -- Reuse the window left over from the previous activity burst (e.g. the
    -- "Done!" window whose deferred close was cancelled by this new state).
    -- Opening a new window here would orphan the old one: its handle was
    -- overwritten below, so nothing would ever close it.
    reposition_window(ui.win)
  else
    -- Defensive: if a stale window survived without its buffer (e.g. the
    -- buffer was wiped out-of-band), close it now so it cannot be orphaned
    -- when ui.win is overwritten below.
    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      pcall(vim.api.nvim_win_close, ui.win, false)
      ui.win = nil
    end

    -- Create buffer
    ui.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = ui.buf })

    -- Set up window configuration with user defaults
    local win_config = vim.tbl_deep_extend("force", {
      relative = "editor",
      width = 30,
      height = 1,
      row = vim.o.lines - 5,
      col = vim.o.columns - 35,
      style = "minimal",
      border = "rounded",
      title = " CodeCompanion ",
      title_pos = "center",
      focusable = false,
      noautocmd = true,
    }, native_config.window or {})

    -- Create window
    ui.win = vim.api.nvim_open_win(ui.buf, false, win_config)

    -- Apply any additional window options
    if native_config.win_options then
      for option, value in pairs(native_config.win_options) do
        pcall(vim.api.nvim_set_option_value, option, value, { win = ui.win })
      end
    end
  end

  -- Start animation timer
  ui.timer = vim.loop.new_timer()
  ui.timer:start(
    0,
    animations.interval,
    vim.schedule_wrap(function()
      pcall(update_spinner_display)
    end)
  )
end

--- The main render function called by the plugin's core.
--- @param new_state number The new state from the tracker.
--- @param event string The raw event that triggered the state change.
function M.render(new_state, event)
  -- Handle persistent states
  ui.current_state = new_state
  ui.close_token = ui.close_token + 1 -- Invalidate any pending close timers

  if new_state == tracker.State.IDLE then
    -- If we were in a non-idle state, show "Done" briefly, then close.
    local content = config.get_content_for_state("done")
    local done_title = get_title_text(content, false)
    local done_window_icon = get_window_icon(content, false)
    local done_window = string.format("%s%s%s", done_window_icon, content.spacing, content.message)

    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      if ui.timer then -- Stop the animation timer
        ui.timer:stop()
        ui.timer:close()
        ui.timer = nil
      end
      pcall(vim.api.nvim_win_set_config, ui.win, { title = done_title })
      pcall(vim.api.nvim_buf_set_lines, ui.buf, 0, -1, false, { done_window })

      local this_token = ui.close_token
      local native_config = config.get().native or {}
      local timer_ms = native_config.done_timer or 500
      vim.defer_fn(function()
        if ui.close_token == this_token then
          close_window()
        end
      end, timer_ms)
    else
      close_window()
    end
  else
    -- If not idle, start or just update the spinner
    if not ui.timer then
      start_spinner()
    end
    -- The running timer will pick up the new state and content
  end

  -- Handle one-off notification events
  local state_key = tracker.one_off_events[event]
  if state_key then
    local content = config.get_content_for_state(state_key)
    -- For one-off events, update the current window if it exists
    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      local temp_title = get_title_text(content, false)
      local temp_window_icon = get_window_icon(content, false)
      local temp_window = string.format("%s%s%s", temp_window_icon, content.spacing, content.message)
      pcall(vim.api.nvim_win_set_config, ui.win, { title = temp_title })
      pcall(vim.api.nvim_buf_set_lines, ui.buf, 0, -1, false, { temp_window })
    end
  end
end

--- One-time setup for this spinner style.
function M.setup()
  -- Get native configuration for validation
  local native_config = require("codecompanion._extensions.spinner.config").get().native or {}

  -- Validate window configuration if provided
  if native_config.window then
    -- Basic validation - ensure required fields are reasonable
    local win_config = native_config.window
    if win_config.width and (win_config.width < 1 or win_config.width > vim.o.columns) then
      vim.notify(
        "Native spinner: Invalid width configuration",
        vim.log.levels.WARN,
        { title = "CodeCompanion Spinners" }
      )
    end
    if win_config.height and (win_config.height < 1 or win_config.height > vim.o.lines) then
      vim.notify(
        "Native spinner: Invalid height configuration",
        vim.log.levels.WARN,
        { title = "CodeCompanion Spinners" }
      )
    end
  end

  -- Keep the spinner anchored to the editor corner across terminal resizes.
  -- Without this, a window created at an old size keeps its stale absolute
  -- row/col after the editor is resized (clamped on-screen, but drifting off
  -- the corner once the terminal grows again).
  local group = vim.api.nvim_create_augroup("CodeCompanionSpinnersNative", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if ui.win and vim.api.nvim_win_is_valid(ui.win) then
        reposition_window(ui.win)
      end
    end,
  })
end

return M
