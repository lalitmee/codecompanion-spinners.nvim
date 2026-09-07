-- Regression tests for the native spinner window lifecycle.
--
-- Covers the floating-window leak fixed by reusing an existing window when a
-- new activity starts inside the `done_timer` window (the classic tool-call
-- flow: RequestFinished -> ToolStarted a few ms later), plus the VimResized
-- re-anchoring behavior.
describe("Native Spinner Window Lifecycle", function()
  local config = require("codecompanion._extensions.spinner.config")
  local tracker = require("codecompanion._extensions.spinner.tracker")
  local neovim_mock = require("tests.mocks.neovim_api")

  local orig_defer_fn
  local native

  before_each(function()
    config.reset()
    config.load({ style = "native" })
    neovim_mock.reset()

    -- Reload the native module so each test starts from a clean ui state
    -- (its ui table is module-local and would otherwise leak across tests)
    package.loaded["codecompanion._extensions.spinner.styles.native"] = nil
    native = require("codecompanion._extensions.spinner.styles.native")

    -- Make deferred callbacks observable but NOT run immediately, so tests
    -- can observe the intermediate "Done!" window state before it closes.
    orig_defer_fn = vim.defer_fn
    vim.defer_fn = function(fn, _delay)
      table.insert(neovim_mock._deferred, fn)
    end
  end)

  after_each(function()
    vim.defer_fn = orig_defer_fn
  end)

  -- Run all deferred callbacks captured so far (simulates time passing).
  local function run_deferred()
    local deferred = neovim_mock._deferred
    neovim_mock._deferred = {}
    for _, fn in ipairs(deferred) do
      fn()
    end
  end

  describe("window reuse on rapid IDLE -> non-IDLE transitions", function()
    it("does not open a second window when a tool starts right after a request finishes", function()
      native.setup()
      neovim_mock._open_win_calls = 0

      -- Request starts: first window is created
      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")
      assert.equals(1, neovim_mock._open_win_calls)

      -- Request finishes: "Done!" shown, close deferred by done_timer (500ms)
      native.render(tracker.State.IDLE, "CodeCompanionRequestFinished")
      assert.equals(1, neovim_mock._open_win_calls)

      -- Tool starts immediately (well within done_timer): the leak moment.
      -- The window must be REUSED, not re-opened.
      native.render(tracker.State.TOOLS_RUNNING, "CodeCompanionToolStarted")
      assert.equals(
        1,
        neovim_mock._open_win_calls,
        "start_spinner() must reuse the existing window instead of opening (and orphaning) a new one"
      )

      -- A second tool round trip: still exactly one window
      native.render(tracker.State.TOOLS_PROCESSING, "CodeCompanionToolFinished")
      native.render(tracker.State.IDLE, "CodeCompanionToolsFinished")
      native.render(tracker.State.TOOLS_RUNNING, "CodeCompanionToolStarted")
      assert.equals(1, neovim_mock._open_win_calls)
    end)

    it("closes the window after done_timer once activity truly ends", function()
      native.setup()

      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")
      assert.equals(1, neovim_mock._open_win_calls)
      local first_win = neovim_mock._last_win_id

      native.render(tracker.State.IDLE, "CodeCompanionRequestFinished")

      -- done_timer elapses: the deferred close runs and closes the window
      run_deferred()
      assert.is_true(
        neovim_mock._closed_wins[first_win],
        "the spinner window should be closed after done_timer expires"
      )
      assert.is_false(
        neovim_mock.api.nvim_win_is_valid(first_win),
        "closed window must be reported invalid by the mock"
      )

      -- New activity afterwards opens a fresh window
      neovim_mock._open_win_calls = 0
      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")
      assert.equals(1, neovim_mock._open_win_calls)
      local second_win = neovim_mock._last_win_id
      assert.is_not.equals(first_win, second_win, "a fresh window must get a new id")
      assert.is_true(
        neovim_mock.api.nvim_win_is_valid(second_win),
        "newly opened window must be valid (mock models real nvim semantics)"
      )
    end)
  end)

  describe("VimResized re-anchoring", function()
    it("repositions the open window when the editor is resized", function()
      native.setup()

      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")

      -- Simulate a terminal resize
      neovim_mock.o.lines = 25
      neovim_mock.o.columns = 90

      -- Fire the VimResized autocmds registered by native.setup()
      for _, autocmd in ipairs(neovim_mock._autocmds["VimResized"] or {}) do
        autocmd.callback({ event = "VimResized" })
      end

      -- The plugin should have repositioned via nvim_win_set_config with
      -- freshly computed editor-relative coordinates.
      local cfg = neovim_mock._last_win_config
      assert.is_table(cfg, "expected a win_set_config call from the VimResized handler")
      assert.equals("editor", cfg.relative, "repositioning must pass relative='editor' (API requirement)")
      assert.equals(25 - 5, cfg.row, "row should be recomputed from the new vim.o.lines")
      assert.equals(90 - 35, cfg.col, "col should be recomputed from the new vim.o.columns")
    end)

    it("does not reposition when the user pinned an absolute row/col", function()
      config.load({
        style = "native",
        native = { window = { row = 3, col = 10 } },
      })
      native.setup()

      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")

      neovim_mock.o.lines = 25
      neovim_mock.o.columns = 90

      for _, autocmd in ipairs(neovim_mock._autocmds["VimResized"] or {}) do
        autocmd.callback({ event = "VimResized" })
      end

      local cfg = neovim_mock._last_win_config
      assert.is_table(cfg)
      assert.equals(3, cfg.row, "pinned row must be preserved")
      assert.equals(10, cfg.col, "pinned col must be preserved")
    end)

    it("ignores resize for non-editor-relative windows", function()
      config.load({
        style = "native",
        native = { window = { relative = "win" } },
      })
      native.setup()

      native.render(tracker.State.THINKING, "CodeCompanionRequestStarted")

      neovim_mock._last_win_config = nil
      neovim_mock.o.lines = 25
      neovim_mock.o.columns = 90

      for _, autocmd in ipairs(neovim_mock._autocmds["VimResized"] or {}) do
        autocmd.callback({ event = "VimResized" })
      end

      assert.is_nil(
        neovim_mock._last_win_config,
        "win/cursor-anchored windows follow their anchor and must not be force-repositioned"
      )
    end)
  end)
end)
