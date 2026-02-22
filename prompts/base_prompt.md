# Quicksilver

Quicksilver is an Elixir-native framework for ephemeral LLM conversation threads with optional tool-calling capabilities, powered by local LLMs (llama.cpp).

## Project Overview

**Location**: `/home/luke/workbench/quicksilver`
**Language**: Elixir 1.14+
**Primary Backend**: llama.cpp via HTTP API

### Core Capabilities

- **Conversation Threads**: Ephemeral, struct-based conversation management with message history
- **Tool-Calling Loop**: Optional iterative reasoning with up to 50 iterations per send (5-minute per-iteration timeout)
- **Tool System**: Modular tools for file operations, code search, and repository analysis
- **Repository Map**: PageRank-based code analysis for context-aware responses
- **Approval System**: Interactive user approval for destructive operations (file writes/edits)

## Architecture

Quicksilver is organized into three layers:

1. **Conversation** (`lib/conversation/`) — ephemeral conversation threads (struct, not process)
2. **Agentic** (`lib/agentic/`) — tools, approval, repository map, and interfaces
3. **LLM Engine** (`lib/llm_engine/`) — standalone local LLM server management

```
Layer Above (future agent libraries)
  - Goals, directives, persistence
  - Owns one or more Conversations
          |
          v
Quicksilver.Conversation (struct)
  - Ephemeral message thread
  - Optional tool-calling loop
          |
          v
Quicksilver.LlmEngine
  - Backend-agnostic completions
  - Server lifecycle management
```

### Supervision Tree

```elixir
Quicksilver.Application
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Agentic.Tools.Registry (GenServer)
└── Quicksilver.Agentic.RepositoryMap.Cache.Server (GenServer)
```

Conversations are structs — no supervised processes needed.

## Key Components

### 1. Conversation (lib/conversation/)

The primary abstraction. A `%Quicksilver.Conversation{}` struct tracking message history and configuration.

Two send strategies:
- **Simple** (`simple.ex`): One LLM call, no tool parsing. For bare chats.
- **ToolCalling** (`tool_calling.ex`): Iterative loop until text response. For tool-calling conversations.

**Key Functions**:
- `Conversation.new/1` - Create with options (system_prompt, tools, backend, etc.)
- `Conversation.send/2` - Send message, get response + updated conversation
- `Conversation.history/1` - Return message list
- `Conversation.clear/1` - Clear history, keep config

### 2. Tool System

#### Tool Behaviour (lib/agentic/tools/behaviour.ex)
```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters_schema() :: map()
@callback execute(args :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}
```

#### Available Tools

**Read-Only (auto-approved)**:
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

### 3. Approval System (lib/agentic/approval/)

```elixir
%Quicksilver.Agentic.Approval.Policy{
  mode: :manual | :auto | :readonly,
  auto_approve_list: ["read_file", "search_files", "list_files"],
  max_auto_size: 1000,
  whitelist_patterns: [],
  blacklist_patterns: ["**/.git/**", "**/node_modules/**"]
}
```

### 4. LlamaCpp Backend (lib/llm_engine/backends/llama_cpp.ex)

GenServer managing llama.cpp server lifecycle:
- `complete/3` - HTTP POST to `/completion` endpoint
- `health_check/1` - GET `/health`

### 5. Terminal Interface (lib/agentic/interfaces/terminal.ex)

Interactive chat using `%Conversation{}` internally. Commands: `help`, `tools`, `history`, `clear`, `exit`/`quit`.

## Public API

```elixir
# Conversations
conv = Quicksilver.new_conversation(opts)
{:ok, response, conv} = Quicksilver.Conversation.send(conv, message)
Quicksilver.Conversation.history(conv)
Quicksilver.Conversation.clear(conv)

# Terminal
Quicksilver.chat()

# LLM Engine
Quicksilver.LlmEngine.complete(messages, opts)
Quicksilver.LlmEngine.health_check()

# Tools
Quicksilver.Agentic.list_tools()
Quicksilver.Agentic.register_tool(module)
Quicksilver.Agentic.execute_tool(name, args, context)

```

## Configuration (config/config.exs)

```elixir
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "/path/to/llama-server",
  model_path: "/path/to/models/",
  model_file: "model.gguf",
  port: 8080,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  auto_start: true
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
