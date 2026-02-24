# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

Quicksilver is an Elixir-native framework for ephemeral LLM conversation threads with optional tool-calling, organized into two layers:

1. **Context** (`lib/quicksilver/`) — ephemeral conversation threads (struct, not process), tools, interfaces
2. **LLM Engine** (`lib/llm_engine/`) — backend-agnostic LLM completions with multiple providers

The Context is the primary abstraction. A bare chat with no tools and a sophisticated tool-calling loop are architecturally the same thing — a `%Quicksilver.Context{}` struct tracking message history and configuration.

```
Layer Above (future "agent" libraries)
  - Goals, directives, persistence, long memory
  - Owns one or more Quicksilver Contexts
                    |
                    v
Quicksilver.Context
  - Ephemeral message thread (struct, not process)
  - Optional tool-calling loop
  - Optional system prompt & context
  - No persistence, no goals, no directives
                    |
                    v
Quicksilver.LlmEngine
  - Backend-agnostic LLM completions
  - Multiple backends: LlamaCpp, OpenAI, Anthropic, Claude CLI
```

### What Quicksilver IS
- An ephemeral conversation thread manager
- A tool-calling execution engine
- A multi-backend LLM interface
- A terminal chat interface

### What Quicksilver IS NOT
- An agent framework (agents live above)
- A persistence layer (no disk, no database)
- A goal/directive system
- A long-term memory system

### Supervision Tree

```elixir
Quicksilver.Supervisor (strategy: :one_for_one)
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Tools.Registry (GenServer)
└── Quicksilver.Tools.RepositoryMap.Cache.Server (GenServer)
```

Contexts are **structs, not processes** — the caller owns the struct and manages its lifecycle.

### Key Design Patterns

**1. Context as Primary Abstraction**

The `%Quicksilver.Context{}` struct tracks:
- Message history (accumulated back-and-forth)
- Configuration (backend, tools, system prompt, timeouts)
- Backend state (for stateful backends like Claude CLI)
- Approval callback (injected by caller)
- No persistence — Quicksilver never saves to disk

Send behaviour is determined by the `tools` field:
- `tools: :none` — single LLM call, no tool parsing (bare chat)
- `tools: :all` or `tools: [list]` — iterative tool-calling loop until text response

**2. Tool System Architecture**

Tools are defined via `Quicksilver.Tools.Behaviour`:
- `name/0` - Unique identifier
- `description/0` - LLM-facing description
- `parameters_schema/0` - JSON schema for arguments
- `execute/2` - Implementation (args, context)

The Registry (`lib/quicksilver/tools/registry.ex`) is a GenServer that stores tool modules and handles execution.

The Formatter (`lib/quicksilver/tools/formatter.ex`) converts tools to LLM prompts and parses tool calls from various JSON formats.

**3. Approval System for Destructive Operations**

Approval is handled via a callback function on the Context struct:
- `approve: fn(action_type, details) -> :approved | :rejected | :quit_session`
- When `nil`, all operations are auto-approved (programmatic use)
- Terminal injects `Quicksilver.Interfaces.Interactive.request_approval/2` for IO-based approval
- Write tools call the `approve` function from the execution context

**4. Backend Abstraction**

`lib/llm_engine/backend.ex` defines the behaviour with pidless callbacks:
- `complete(messages, options)` — standard completion
- `complete_with_state(messages, state, options)` — for stateful backends (optional)
- `health_check(options)` — verify backend readiness

The `LlmEngine` facade resolves backend atoms to modules:
- `:llama_cpp` → `Quicksilver.LlmEngine.Backends.LlamaCpp` (local llama.cpp, GenServer)
- `:openai` → `Quicksilver.LlmEngine.Backends.OpenAI` (OpenAI API, stateless)
- `:anthropic` → `Quicksilver.LlmEngine.Backends.Anthropic` (Anthropic API, stateless)
- `:claude_cli` → `Quicksilver.LlmEngine.Backends.ClaudeCli` (Claude CLI headless, stateful)

Unknown atoms are treated as module names directly (useful for testing with mock backends).

## Public API

```elixir
# Create contexts
ctx = Quicksilver.Context.new()                                    # bare chat (llama_cpp)
ctx = Quicksilver.Context.new(backend: :openai)                    # OpenAI
ctx = Quicksilver.Context.new(backend: :claude_cli, tools: :all)   # Claude CLI + tools
ctx = Quicksilver.Context.new(system_prompt: "You are an expert.") # system prompt

# Send messages
{:ok, response, ctx} = Quicksilver.Context.send(ctx, "Hello!")
{:ok, response, ctx} = Quicksilver.Context.send(ctx, "Tell me more")

# History
Quicksilver.Context.history(ctx)
ctx = Quicksilver.Context.clear(ctx)

# Terminal chat with options
Quicksilver.chat(backend: :openai, tools: :none)
Quicksilver.chat(backend: :claude_cli, system_prompt: "Be concise.")

# Tools
Quicksilver.list_tools()
Quicksilver.register_tool(MyTool)
```

## Directory Structure

```
lib/
├── quicksilver.ex                              # Top-level facade
├── application.ex                              # Supervision tree
│
├── quicksilver/
│   ├── context.ex                              # Primary abstraction (struct + API + send logic)
│   ├── tools/                                  # Tool system
│   │   ├── behaviour.ex
│   │   ├── registry.ex
│   │   ├── formatter.ex
│   │   ├── tools.ex                            # Registration convenience
│   │   ├── file_reader.ex, search_files.ex, list_files.ex
│   │   ├── create_file.ex, edit_file.ex
│   │   ├── run_tests.ex, get_repository_context.ex
│   │   └── repository_map/                     # PageRank-based code context (powers get_repository_context)
│   │       ├── repository_map.ex
│   │       ├── cache/server.ex
│   │       ├── formatter/llm.ex
│   │       ├── graph/builder.ex, ranker.ex
│   │       └── parser/entity.ex, elixir_parser.ex, repository_parser.ex
│   └── interfaces/
│       ├── terminal.ex                         # Terminal chat (injects IO-based approval)
│       └── interactive.ex                      # IO-based approval UI (diff display, prompts)
│
└── llm_engine/                                 # LLM backends
    ├── llm_engine.ex                           # Facade with backend resolution
    ├── backend.ex                              # Behaviour (pidless callbacks)
    └── backends/
        ├── llama_cpp.ex                        # Local llama.cpp (GenServer)
        ├── openai.ex                           # OpenAI API (stateless)
        ├── anthropic.ex                        # Anthropic API (stateless)
        └── claude_cli.ex                       # Claude CLI headless (stateful)
```

## Context Struct

```elixir
defstruct [
  history: [],
  system_prompt: nil,
  tools: :none,               # :none | :all | [list of tool name strings]
  backend: :llama_cpp,         # :llama_cpp | :openai | :anthropic | :claude_cli | module
  backend_state: %{},          # backend-specific state (e.g. claude_cli session_id)
  workspace_root: nil,
  max_iterations: 50,
  per_iteration_timeout: 300_000,
  approve: nil                 # fn(action_type, details) -> :approved | :rejected | :quit_session
]
```

## Available Tools

**Read-only:**
- `read_file` - Read file contents
- `search_files` - Search codebase (ripgrep/grep)
- `list_files` - List files with glob patterns
- `get_repository_context` - PageRank-based code context

**Write (require approval):**
- `create_file` - Create new files
- `edit_file` - Edit existing files (uses exact string replacement with uniqueness validation)

**Utility:**
- `run_tests` - Execute `mix test` and return results

All write tools create `.backup.timestamp` files before modifications.

## Adding New Tools

1. Create module in `lib/quicksilver/tools/`
2. Implement `@behaviour Quicksilver.Tools.Behaviour`
3. Add to `lib/quicksilver/tools/tools.ex` `register_default_tools/0`
4. Write tools: call `approve` function from context for destructive operations

## Tool Execution Context

When tools execute, they receive a `context` map with:
- `:workspace_root` - Base directory for file operations
- `:approve` - Approval callback function

## Configuration

```elixir
# config/config.exs

# Local LlamaCpp
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "...",
  model_path: "...",
  model_file: "...",
  port: 8080,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  auto_start: true

# OpenAI
config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAI,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o"

# Anthropic
config :quicksilver, Quicksilver.LlmEngine.Backends.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-sonnet-4-6"
```

## Key Behaviours to Maintain

**Context is a struct** — no GenServer, no process, no supervision. The caller owns the struct.

**Tool Uniqueness Validation**: The `edit_file` tool requires `old_string` to appear exactly once in the file.

**Backup Creation**: Always create backups before destructive operations (pattern: `path.backup.timestamp`).

**Per-Iteration Timeouts**: When modifying the tool-calling strategy, maintain per-iteration timeouts rather than total task timeouts.

**Tool Result Formatting**: Use `Formatter.format_tool_result/2` for consistent formatting.

**Approval is a callback** — tools call `context.approve.(action_type, details)`. They never import IO or Interactive directly.

## Testing

- Unit tests in `test/` directory
- Run terminal with `mix run start_chat.exs` for manual testing
- `mix test` runs all tests
- Mock backends: pass module directly as `backend:` option (e.g., `backend: MyMockBackend`)

## Common Pitfalls

1. **Config returns keyword list** - `Application.get_env(:quicksilver, Module)` returns a keyword list, convert with `Map.new/1` before using with `Map.merge/2`
2. **Tool registration timing** - Tools must be registered after supervision tree starts
3. **Context is a struct** — no GenServer state; the caller (terminal, test harness, higher-level agent) manages the `%Context{}` struct
4. **Approval is injected** - Write tools call `context.approve` callback, not Interactive directly. Terminal injects the IO-based callback; tests/programmatic use pass `nil` (auto-approve)
5. **Backend resolution** — atom keys (`:openai`, `:anthropic`) are resolved by `LlmEngine.resolve_backend/1`. Unknown atoms are treated as module names directly.
