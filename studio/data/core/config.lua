local config = {}

config.project_scan_rate = 5
config.fps = 60
config.max_log_items = 80
config.message_timeout = 3
config.mouse_wheel_scroll = 50 * SCALE
config.file_size_limit = 10
config.ignore_files = "^%."
config.symbol_pattern = "[%a_][%w_]*"
config.non_word_chars = " \t\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-"
config.undo_merge_timeout = 0.3
config.max_undos = 10000
config.highlight_current_line = true
config.line_height = 1.2
config.indent_size = 2
config.tab_type = "soft"
config.line_limit = 80
-- Open .md/.markdown files as a rendered preview (MarkdownView) rather than raw
-- source. `markdown:toggle-source` switches to editing per-file at runtime.
config.markdown_preview = true
-- neovim-style modal editing (studio/data/core/vim.lua). Off by default; the
-- module always loads so `vim:toggle` / `:set vim` can turn it on at runtime.
config.vim_mode = false

return config
