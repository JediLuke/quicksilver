# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

Quicksilver is an Elixir-native framework for ephemeral LLM conversation threads with optional tool-calling, organized into two layers:

1. **Conversation** (`lib/quicksilver/`) — ephemeral conversation threads (struct, not process), tools, approval, repository map, interfaces
2. **LLM Engine** (`lib/llm_engine/`) — backend-agnostic LLM completions with multiple providers

The Conversation is the primary abstraction. A bare chat with no tools and a sophisticated tool-calling loop are architecturally the same thing — a `%Quicksilver.Conversation{}` struct tracking message history and configuration.

```
Layer Above (future "agent" libraries)
  - Goals, directives, persistence, long memory
  - Owns one or more Quicksilver Conversations
                    |
                    v
Quicksilver.Conversation
  - Ephemeral message thread (struct, not process)
  - Optional tool-calling loop
  - Optional system prompt & context
  - No persistence, no goals, no directives
                    |
                    v
Quicksilver.LlmEngine
  - Backend-agnostic LLM completions
  - Multiple backends: LlamaCpp, OpenAI-compatible, OpenAI, Anthropic, Claude CLI
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
├── Quicksilver.SessionReaper (GenServer — kills claude CLI processes whose owner died)
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Tools.Registry (GenServer)
└── Quicksilver.Tools.RepositoryMap.Cache.Server (GenServer)
```

Conversations are **structs, not processes** — the caller owns the struct and manages its lifecycle.

### Key Design Patterns

**1. Conversation as Primary Abstraction**

The `%Quicksilver.Conversation{}` struct tracks:
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

The Registry (`lib/quicksilver/tools/registry.ex`) is a GenServer that stores tool modules. `execute_tool/3` looks the tool up there but runs it in the caller's process, because tools can block for a long time (approval prompts, `run_tests`). Never move tool execution back inside a `GenServer.call`.

The Formatter (`lib/quicksilver/tools/formatter.ex`) converts tools to LLM prompts and parses tool calls from various JSON formats.

**3. Approval System for Destructive Operations**

Approval is handled via a callback function on the Conversation struct:
- `approve: fn(action_type, details) -> :approved | :rejected | :quit_session`
- When `nil`, destructive operations are rejected by default (safe by default)
- Terminal injects `Quicksilver.Interfaces.Interactive.request_approval/2` for IO-based approval
- Write tools call the `approve` function from the execution context

**4. Backend Abstraction**

`lib/llm_engine/backend.ex` defines the behaviour with pidless callbacks:
- `complete(messages, options)` — standard completion
- `complete_with_state(messages, state, options)` — for stateful backends (optional)
- `health_check(options)` — verify backend readiness
- `native_tools?()` — true when the backend takes structured messages plus a `:tools` option and returns `{:ok, {:tool_calls, calls, assistant_message}}` (optional)

Conversations with tools use **native tool calling** when `LlmEngine.native_tools?/1` is true: system prompt + structured history, tool schemas in the request, one `tool` message (with `tool_call_id`) per call. Otherwise they fall back to the **JSON-in-text** protocol (`Formatter.system_prompt_with_tools/1` + `Formatter.parse_tool_call/1`). Models with their own chat/tool format (gpt-oss, Qwen3) need native calling.

The `LlmEngine` facade resolves backend atoms to modules:
- `:llama_cpp` → `Quicksilver.LlmEngine.Backends.LlamaCpp` (local llama.cpp, GenServer; native tools via `OpenAICompatible.chat/3`)
- `:openai_compatible` → `Quicksilver.LlmEngine.Backends.OpenAICompatible` (any `/chat/completions` server: OpenRouter, Mistral, vLLM, Ollama, ...; stateless)
- `:openai` → `Quicksilver.LlmEngine.Backends.OpenAI` (`OpenAICompatible` preset for api.openai.com)
- `:anthropic` → `Quicksilver.LlmEngine.Backends.Anthropic` (Anthropic API, stateless)
- `:claude_cli` → `Quicksilver.LlmEngine.Backends.ClaudeCli` (Claude CLI headless, stateful)

Unknown atoms are treated as module names directly (useful for testing with mock backends).

With no `:backend` option, `LlmEngine.default_backend/0` uses the `:backend` config key (`QUICKSILVER_BACKEND` env var, default `llama_cpp`). Don't hardcode a backend elsewhere.

## Public API

```elixir
# Create conversations
ctx = Quicksilver.Conversation.new()                                    # bare chat (default backend)
ctx = Quicksilver.Conversation.new(backend: :openai)                    # OpenAI
ctx = Quicksilver.Conversation.new(backend: :claude_cli, tools: :all)   # Claude CLI + tools
ctx = Quicksilver.Conversation.new(system_prompt: "You are an expert.") # system prompt

# Send messages
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Hello!")
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Tell me more")

# History
Quicksilver.Conversation.history(ctx)
ctx = Quicksilver.Conversation.clear(ctx)

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
│   ├── conversation.ex                         # Primary abstraction (struct + API + send logic)
│   ├── session_reaper.ex                       # Cleans up claude CLI processes
│   ├── context_lib/elixir_coding_assistant.ex  # Coding preset (tools + prompt), used by start_chat.exs
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
        ├── openai_compatible.ex                # Any /chat/completions API (stateless)
        ├── openai.ex                           # OpenAI preset of openai_compatible
        ├── anthropic.ex                        # Anthropic API (stateless)
        └── claude_cli.ex                       # Claude CLI headless (stateful)
```

## Conversation Struct

```elixir
defstruct [
  history: [],
  system_prompt: nil,
  tools: :none,               # :none | :all | [list of tool name strings]
  backend: :llama_cpp,         # set from LlmEngine.default_backend/0 by new/1; :openai_compatible | :openai | :anthropic | :claude_cli | module
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

`config/config.exs` holds shared defaults: the `:backend` key, LlamaCpp (`native_tools`, `max_tokens`, `auto_start: false`, ...), and one block per API backend. **Machine-specific settings and API keys go in `config/dev.secret.exs`** (gitignored, imported by `config/dev.exs`; template: `config/dev.secret.example.exs`) — e.g. LlamaCpp `launch_script`, `server_path`, `model_path`, `model_file`, `model`. The repo is public: never commit keys or local paths.

API backends take the key from `api_key` (set it in `dev.secret.exs`) or the env var named by `api_key_env`.

See `RUNNING_LOCALLY.md` for running with local models.

## Key Behaviours to Maintain

**Conversation is a struct** — no GenServer, no process, no supervision. The caller owns the struct.

**Tool Uniqueness Validation**: The `edit_file` tool requires `old_string` to appear exactly once in the file.

**Backup Creation**: Always create backups before destructive operations (pattern: `path.backup.timestamp`).

**Per-Iteration Timeouts**: When modifying the tool-calling strategy, maintain per-iteration timeouts rather than total task timeouts.

**Tool Result Formatting**: Use `Formatter.format_tool_result/2` for consistent formatting.

**Approval is a callback** — tools call `context.approve.(action_type, details)`. They never import IO or Interactive directly.

**Tools run in the caller's process** — `Registry.execute_tool/3` looks the tool up in the Registry GenServer but executes it in the caller, because tools block for a long time (approval prompts wait on the user, `run_tests` runs the suite). Never move tool execution back inside a `GenServer.call`.

**SessionReaper only touches what it was given** — it kills a registered claude CLI process when its owner exits. Never scan for and kill processes Quicksilver didn't spawn (other Claude Code sessions run headless too).

## Testing

- Unit tests in `test/` directory
- Run terminal with `mix run start_chat.exs` for manual testing
- `mix test` runs all tests
- Mock backends: pass module directly as `backend:` option (e.g., `backend: MyMockBackend`)

## Common Pitfalls

1. **Config returns keyword list** - `Application.get_env(:quicksilver, Module)` returns a keyword list, convert with `Map.new/1` before using with `Map.merge/2`
2. **Tool registration timing** - Tools must be registered after supervision tree starts
3. **Conversation is a struct** — no GenServer state; the caller (terminal, test harness, higher-level agent) manages the `%Conversation{}` struct
4. **Approval is injected** - Write tools call `context.approve` callback, not Interactive directly. Terminal injects the IO-based callback; with `nil`, destructive operations are rejected — tests/programmatic use pass `fn _, _ -> :approved end` to auto-approve
5. **Backend resolution** — atom keys (`:openai`, `:anthropic`) are resolved by `LlmEngine.resolve_backend/1`. Unknown atoms are treated as module names directly.
6. **`function_exported?/3` needs a loaded module** — call `Code.ensure_loaded?/1` first; in dev/test, modules load lazily and `function_exported?` is false until they do.
7. **Port `{:spawn, cmd}` already prepends `exec`** — Erlang runs it as `/bin/sh -c "exec cmd"`, so the port's `os_pid` is the command itself; adding your own `exec` breaks the command.
