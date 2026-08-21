# mymew

A small CLI/TUI AI coding agent written in Zig, using comptime duck-typed plugins for tools and hooks.

## Requirements

- Zig 0.16.0
- `GLM_API_KEY` (or `ZAI_API_KEY`) for the GLM provider

## Usage

```sh
zig build            # build
zig build run        # interactive TUI
zig build run -- -p "your prompt"   # headless, one-shot
zig build test       # tests
```

Optional env vars: `GLM_MODEL`, `GLM_BASE_URL`, `MYMEW_MEMORY_PATH`.

## Layout

- `src/core/` — engine (ReAct loop), memory, LLM provider, agent thread, tool/hook contracts
- `src/plugins/tools/` — tools (read/write file, list files, execute command, ...)
- `src/plugins/hooks/` — interceptor hooks (system prompt, command guard, todo tracker, ...)
- `src/tui/` — terminal frontend
- `docs/Architecture_Design.md` — design reference
