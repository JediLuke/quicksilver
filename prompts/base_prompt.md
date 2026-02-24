# Quicksilver

Quicksilver is an Elixir-native framework for ephemeral LLM conversation threads with optional tool-calling capabilities, powered by multiple LLM backends.

## Project Overview

**Location**: `/home/luke/workbench/quicksilver`
**Language**: Elixir 1.14+
**Backends**: llama.cpp (local), OpenAI API, Anthropic API, Claude CLI

### Core Capabilities

- **Context Threads**: Ephemeral, struct-based conversation management with message history
- **Tool-Calling Loop**: Optional iterative reasoning with up to 50 iterations per send (5-minute per-iteration timeout)
- **Tool System**: Modular tools for file operations, code search, and repository analysis
- **Repository Map**: PageRank-based code analysis for context-aware responses
- **Approval System**: Callback-based approval for destructive operations (injected by caller)

## Architecture

Quicksilver is organized into two layers:

1. **Context** (`lib/quicksilver/`) — ephemeral conversation threads (struct, not process), tools, interfaces
2. **LLM Engine** (`lib/llm_engine/`) — backend-agnostic LLM completions with multiple providers

```
Layer Above (future agent libraries)
  - Goals, directives, persistence
  - Owns one or more Contexts
          |
          v
Quicksilver.Context (struct)
  - Ephemeral message thread
  - Optional tool-calling loop
          |
          v
Quicksilver.LlmEngine
  - Backend-agnostic completions
  - Multiple providers
```

### Supervision Tree

```elixir
Quicksilver.Application
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Tools.Registry (GenServer)
└── Quicksilver.Tools.RepositoryMap.Cache.Server (GenServer)
```

Contexts are structs — no supervised processes needed.

## Key Components

### 1. Context (lib/quicksilver/context.ex)

The primary abstraction. A `%Quicksilver.Context{}` struct tracking message history and configuration.

Send behaviour is determined by the `tools` field:
- `tools: :none` — single LLM call, no tool parsing (bare chat)
- `tools: :all` or `tools: [list]` — iterative tool-calling loop until text response

**Key Functions**:
- `Context.new/1` - Create with options (system_prompt, tools, backend, etc.)
- `Context.send/2` - Send message, get response + updated context
- `Context.history/1` - Return message list
- `Context.clear/1` - Clear history, keep config

### 2. Tool System

#### Tool Behaviour (lib/quicksilver/tools/behaviour.ex)
```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters_schema() :: map()
@callback execute(args :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}
```

#### Available Tools

**Read-Only**:
| Tool | Purpose | Parameters |
|------|---------|------------|
| `read_file` | Read file contents (max 100KB) | `path` |
| `search_files` | Search codebase (ripgrep/grep) | `pattern`, `directory`, `file_pattern` |
| `list_files` | List files with glob patterns | `directory`, `pattern` |
| `get_repository_context` | PageRank-based code context | `task_description`, `token_limit` |
| `run_tests` | Execute mix test | `path` (optional) |

**Write (require approval)**:
| Tool | Purpose | Parameters |
|------|---------|------------|
| `create_file` | Create new files | `path`, `content` |
| `edit_file` | Edit via exact string replacement | `path`, `old_string`, `new_string` |

### 3. Approval System

Approval is a callback function on the Context struct:
```elixir
approve: fn(action_type, details) -> :approved | :rejected | :quit_session
```

- When `nil`, all operations are auto-approved (programmatic use)
- Terminal injects `Quicksilver.Interfaces.Interactive.request_approval/2` for IO-based approval
- Write tools call the `approve` callback from their execution context

### 4. LLM Backends

| Key | Module | Type |
|-----|--------|------|
| `:llama_cpp` | `Quicksilver.LlmEngine.Backends.LlamaCpp` | Local llama.cpp (GenServer) |
| `:openai` | `Quicksilver.LlmEngine.Backends.OpenAI` | OpenAI API (stateless) |
| `:anthropic` | `Quicksilver.LlmEngine.Backends.Anthropic` | Anthropic API (stateless) |
| `:claude_cli` | `Quicksilver.LlmEngine.Backends.ClaudeCli` | Claude CLI headless (stateful) |

The LlmEngine facade resolves atom keys to modules. Unknown atoms are treated as module names directly (useful for testing with mock backends).

### 5. Terminal Interface (lib/quicksilver/interfaces/terminal.ex)

Interactive chat using `%Context{}` internally. Passes all options through to `Context.new/1`. Commands: `help`, `tools`, `history`, `clear`, `exit`/`quit`.

## Public API

```elixir
# Contexts
ctx = Quicksilver.Context.new(opts)
{:ok, response, ctx} = Quicksilver.Context.send(ctx, message)
Quicksilver.Context.history(ctx)
Quicksilver.Context.clear(ctx)

# Terminal
Quicksilver.chat()
Quicksilver.chat(backend: :openai, tools: :none)

# LLM Engine
Quicksilver.LlmEngine.complete(messages, backend: :openai)
Quicksilver.LlmEngine.health_check(backend: :llama_cpp)

# Tools
Quicksilver.list_tools()
Quicksilver.register_tool(module)
Quicksilver.execute_tool(name, args, context)
```

## Configuration (config/config.exs)

```elixir
# Local LlamaCpp
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "/path/to/llama-server",
  model_path: "/path/to/models/",
  model_file: "model.gguf",
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

## Running

```bash
mix run start_chat.exs    # Terminal chat
iex -S mix                # IEx
mix test                  # Tests
```

## Dependencies

```elixir
{:req, "~> 0.4"},           # HTTP client
{:jason, "~> 1.4"},         # JSON encoding/decoding
{:libgraph, "~> 0.16"},     # Graph algorithms (PageRank)
{:file_system, "~> 1.0"},   # File watching
{:flow, "~> 1.2"},          # Parallel processing
```
