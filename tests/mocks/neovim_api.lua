-- Mock Neovim API for testing
local M = {}

-- Mock storage for autocmds and augroups
M._autocmds = {}
M._augroups = {}
M._next_augroup_id = 1000
M._next_autocmd_id = 2000

-- Observability for window lifecycle tests (leak detection)
M._open_win_calls = 0 -- number of nvim_open_win invocations
M._win_close_calls = 0 -- number of nvim_win_close invocations
M._closed_wins = {} -- set of window ids that have been closed
M._last_win_config = nil -- last config passed to nvim_win_set_config
M._deferred = {} -- callbacks captured by the deferred-mock (see _G.vim.defer_fn shim)
M._next_win_id = 999 -- next window id handed out by nvim_open_win
M._last_win_id = nil -- id returned by the most recent nvim_open_win

-- Mock vim.api
M.api = {
  nvim_create_augroup = function(name, opts)
    local id = M._next_augroup_id
    M._next_augroup_id = M._next_augroup_id + 1
    M._augroups[id] = {
      name = name,
      opts = opts or {},
      autocmds = {},
    }
    return id
  end,

  nvim_create_autocmd = function(events, opts)
    local id = M._next_autocmd_id
    M._next_autocmd_id = M._next_autocmd_id + 1

    -- Support both single event and array of events
    local event_list = type(events) == "table" and events or { events }

    for _, event in ipairs(event_list) do
      if not M._autocmds[event] then
        M._autocmds[event] = {}
      end
      table.insert(M._autocmds[event], {
        id = id,
        opts = opts,
        callback = opts.callback,
      })
    end

    return id
  end,

  nvim_del_augroup_by_id = function(id)
    M._augroups[id] = nil
  end,

  nvim_exec_autocmds = function(event, opts)
    opts = opts or {}
    local pattern = opts.pattern

    if M._autocmds[event] then
      for _, autocmd in ipairs(M._autocmds[event]) do
        -- Check if pattern matches
        if not pattern or autocmd.opts.pattern == pattern then
          if autocmd.callback then
            autocmd.callback({
              match = pattern or event,
              event = event,
            })
          end
        end
      end
    end
  end,

  nvim_get_current_buf = function()
    return 1 -- Mock buffer ID
  end,

  nvim_buf_get_name = function(_bufnr)
    return "/mock/path/file.lua" -- Mock file path
  end,

  nvim_win_get_cursor = function(_winid)
    return { 5, 10 } -- Mock cursor position
  end,

  nvim_win_get_position = function(_winid)
    return { 100, 200 } -- Mock window position
  end,

  nvim_open_win = function(_bufnr, _enter, _opts)
    M._open_win_calls = M._open_win_calls + 1
    -- Hand out a unique id per open, like real nvim: a newly opened window
    -- is never a previously closed id (fixes "new window seen as closed"
    -- when ids were a constant 999).
    local winid = M._next_win_id
    M._next_win_id = M._next_win_id + 1
    M._last_win_id = winid
    return winid
  end,

  nvim_win_close = function(winid, _force)
    M._win_close_calls = M._win_close_calls + 1
    M._closed_wins[winid] = true
  end,

  nvim_create_buf = function(_listed, _scratch)
    return 1000 + math.random(1000) -- Mock buffer ID
  end,

  nvim_buf_delete = function(_bufnr, _opts)
    -- Mock buffer deletion
  end,

  nvim_buf_set_lines = function(_bufnr, _start, _end_, _strict, _lines)
    -- Mock buffer line setting
  end,

  nvim_create_namespace = function(_name)
    return 3000 -- Mock namespace ID
  end,

  nvim_buf_add_highlight = function(_bufnr, _ns_id, _hl_group, _line, _col_start, _col_end)
    -- Mock highlighting
  end,

  nvim_buf_clear_namespace = function(_bufnr, _ns_id, _line_start, _line_end)
    -- Mock namespace clearing
  end,

  nvim_buf_set_extmark = function(_bufnr, _ns_id, _line, _col, _opts)
    -- Mock setting extmark
  end,

  nvim_win_is_valid = function(win)
    -- Valid unless closed; safe because ids are unique per open, so a
    -- freshly opened window can never collide with a closed one.
    return not M._closed_wins[win]
  end,

  nvim_buf_is_valid = function(_buf)
    return true -- Mock buffer is valid
  end,

  nvim_win_set_config = function(_win, cfg)
    M._last_win_config = cfg -- Record for assertions
  end,

  nvim_set_option_value = function(_name, _value, _opts)
    -- Mock setting option value
  end,
}

-- Mock vim.fn
M.fn = {
  search = function(_pattern, _flags)
    return 0 -- Mock search result (no match)
  end,

  searchcount = function(_opts)
    return { total = 0, current = 0 } -- Mock search count
  end,

  fnamemodify = function(_path, _mods)
    return "mock_file.lua"
  end,

  line = function(_expr)
    return 10 -- Mock line number
  end,

  col = function(_expr)
    return 5 -- Mock column number
  end,

  getline = function(_lnum)
    return "mock line content" -- Mock line content
  end,

  stdpath = function(_what)
    return "/mock/path" -- Mock standard path
  end,

  filereadable = function(_file)
    return true -- Mock file exists
  end,

  isdirectory = function(_dir)
    return true -- Mock directory exists
  end,
}

-- Mock vim.o (options)
M.o = {
  lines = 24,
  columns = 80,
  cmdheight = 1,
  laststatus = 2,
}

-- Mock vim.opt
M.opt = {
  fileencoding = {
    get = function()
      return "utf-8"
    end,
  },
  fileformat = {
    get = function()
      return "unix"
    end,
  },
}

-- Mock vim.loop (libuv)
M.loop = {
  hrtime = function()
    return 1000000000 -- Mock nanosecond timestamp
  end,

  new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function() end,
    }
  end,
}

-- Mock vim.schedule
M.schedule = function(fn)
  fn() -- Execute immediately for testing
end

-- Mock vim.defer_fn
M.defer_fn = function(fn, _delay)
  fn() -- Execute immediately for testing (ignore delay)
end

-- Mock vim.cmd
M.cmd = function(_cmd)
  -- Mock vim command execution
  print("vim.cmd: mock command")
end

-- Mock vim.notify
M.notify = function(msg, level, _opts)
  print(string.format("[NOTIFY %s] %s", level or "INFO", msg))
end

-- Mock vim.log
M.log = {
  levels = {
    INFO = "info",
    WARN = "warn",
    ERROR = "error",
    DEBUG = "debug",
  },
}

-- Mock vim.highlight
M.highlight = {
  priorities = {
    user = 100,
  },
}

-- Mock vim.tbl_deep_extend
M.tbl_deep_extend = function(_behavior, ...)
  -- Simple mock implementation
  local result = {}
  for _i = 1, select("#", ...) do
    local tbl = select(_i, ...)
    if type(tbl) == "table" then
      for k, v in pairs(tbl) do
        result[k] = v
      end
    end
  end
  return result
end

-- Mock vim.schedule_wrap
M.schedule_wrap = function(fn)
  return fn -- Execute immediately in test environment
end

-- Helper to reset mock state
M.reset = function()
  M._autocmds = {}
  M._augroups = {}
  M._next_augroup_id = 1000
  M._next_autocmd_id = 2000
  M._open_win_calls = 0
  M._win_close_calls = 0
  M._closed_wins = {}
  M._last_win_config = nil
  M._deferred = {}
  M._next_win_id = 999
  M._last_win_id = nil
end

return M
