# Quicksilver

Quicksilver is an Elixir-native agentic framework for building intelligent, tool-calling AI agents powered by local LLMs (llama.cpp). It provides a complete infrastructure for autonomous code exploration, editing, and task execution.

## Project Overview

**Location**: `/home/luke/workbench/quicksilver`
**Language**: Elixir 1.14+
**Primary Backend**: llama.cpp via HTTP API
**Architecture Pattern**: Stateless agent with iterative tool-calling loop

### Core Capabilities

- **Agentic Loop**: Iterative reasoning with up to 50 iterations per task (5-minute per-iteration timeout)
- **Tool System**: Modular tools for file operations, code search, and repository analysis
- **Repository Map**: PageRank-based code analysis for context-aware agent responses
- **Approval System**: Interactive user approval for destructive operations (file writes/edits)

## Architecture

Quicksilver is organized into two independent layers:

1. **LLM Engine** (`lib/llm_engine/`) — standalone local LLM server management
2. **Agentic** (`lib/agentic/`) — agents, tools, approval, repository map, and interfaces

```
Terminal Interface (lib/agentic/interfaces/terminal.ex)
         |
         v
Stateless Agent (lib/agentic/agent.ex)
         |
         v
LLM Backend (lib/llm_engine/backends/llama_cpp.ex) --> External llama.cpp server
         |
         v
Tools (Registry + Individual Tools in lib/agentic/tools/)
```

### Supervision Tree

```elixir
Quicksilver.Application
    |
    v
Quicksilver.Supervisor (strategy: :one_for_one)
    |-- Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
    |-- Quicksilver.Agentic.Tools.Registry (GenServer)
    |-- Quicksilver.Agentic.RepositoryMap.Cache.Server (GenServer)
```

Tools are always registered on startup. Agents are stateless (no supervised processes needed).

## Directory Structure

```
lib/
├── quicksilver.ex                          # Top-level convenience facade
├── application.ex                          # Supervision tree
│
├── llm_engine/                             # Standalone LLM backend management
│   ├── llm_engine.ex                       # Public API facade
│   ├── backend.ex                          # Backend behaviour
│   └── backends/
│       └── llama_cpp.ex                    # LlamaCpp GenServer
│
└── agentic/                                # Agents + Tools + Interfaces
    ├── agentic.ex                          # Public API facade
    ├── agent.ex                            # Stateless agent
    ├── tools.ex                            # Tool registration convenience
    ├── tools/
    │   ├── behaviour.ex                    # Tool callback interface
    │   ├── registry.ex                     # GenServer managing tool registration/execution
    │   ├── formatter.ex                    # JSON parsing and prompt formatting
    │   ├── file_reader.ex                  # read_file tool
    │   ├── search_files.ex                 # search_files tool
    │   ├── list_files.ex                   # list_files tool
    │   ├── create_file.ex                  # create_file tool (requires approval)
    │   ├── edit_file.ex                    # edit_file tool (requires approval)
    │   ├── run_tests.ex                    # run_tests tool
    │   └── get_repository_context.ex       # Repository map tool
    ├── approval/
    │   ├── policy.ex                       # Approval policy configuration
    │   └── interactive.ex                  # Interactive approval UI
    ├── repository_map/
    │   ├── repository_map.ex               # High-level repository map API
    │   ├── cache/server.ex                 # ETS-backed cache for maps
    │   ├── formatter/llm.ex                # Formats context for LLM
    │   ├── graph/builder.ex                # Builds call graph from entities
    │   ├── graph/ranker.ex                 # PageRank scoring algorithm
    │   └── parser/
    │       ├── entity.ex                   # Entity struct definition
    │       ├── elixir_parser.ex            # AST-based Elixir parsing
    │       └── repository_parser.ex        # Concurrent repo parsing
    └── interfaces/
        └── terminal.ex                     # Interactive terminal chat interface
```

## Key Components

### 1. Stateless Agent (lib/agentic/agent.ex)

The core agentic loop implementation. Executes tasks by iteratively:
1. Building prompts with available tools
2. Calling the LLM backend
3. Parsing responses for tool calls
4. Executing tools and adding results to history
5. Continuing until a final answer or max iterations

**Key Function**:
- `execute_task/2` - Takes task string and opts, returns `{:ok, text, updated_history}` or `{:error, reason}`

**Options**:
- `:backend_module` - LLM backend module (default: LlamaCpp)
- `:backend_pid` - Backend process name/pid
- `:conversation_history` - Prior messages
- `:max_iterations` - Max LLM calls (default: 50)
- `:per_iteration_timeout` - Timeout per call in ms (default: 300000)
- `:workspace_root` - Base directory for file operations
- `:allowed_tools` - `:all` or list of tool names

**Timeout Strategy**: Per-iteration timeouts (5 min default), NOT total task timeout.

### 2. Tool System

#### Tool Behaviour (lib/agentic/tools/behaviour.ex)
```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters_schema() :: map()  # JSON Schema
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

#### Policy (policy.ex)
```elixir
%Quicksilver.Agentic.Approval.Policy{
  mode: :manual | :auto | :readonly,
  auto_approve_list: ["read_file", "search_files", "list_files"],
  max_auto_size: 1000,
  whitelist_patterns: [],
  blacklist_patterns: ["**/.git/**", "**/node_modules/**"]
}
```

### 4. Repository Map System (lib/agentic/repository_map/)

PageRank-based code analysis for intelligent context selection.

### 5. LlamaCpp Backend (lib/llm_engine/backends/llama_cpp.ex)

GenServer managing llama.cpp server lifecycle:
- `complete/3` - HTTP POST to `/completion` endpoint
- `health_check/1` - GET `/health`
- `start_standalone/1` - Start detached server
- `initialize/0` - Connect to existing or start new server

### 6. Terminal Interface (lib/agentic/interfaces/terminal.ex)

Interactive chat with multi-line input and commands:
- `help` - Show commands
- `tools` - List available tools
- `history` - Show conversation
- `clear` - Reset history
- `exit` / `quit` - Exit

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

## Public API

```elixir
# Start terminal chat
Quicksilver.chat()

# LLM Engine
Quicksilver.LlmEngine.complete(messages, opts)
Quicksilver.LlmEngine.health_check()

# Agentic
Quicksilver.Agentic.execute_task(task, opts)
Quicksilver.Agentic.list_tools()
Quicksilver.Agentic.register_tool(module)
Quicksilver.Agentic.execute_tool(name, args, context)
```

## Adding New Tools

1. Create module in `lib/agentic/tools/`
2. Implement `@behaviour Quicksilver.Agentic.Tools.Behaviour`
3. Add to `Quicksilver.Agentic.Tools.register_default_tools/0`
4. If destructive: integrate with approval system via context

## Running the System

```bash
# Terminal chat (auto-starts everything)
mix run start_chat.exs

# IEx
iex -S mix
iex> Quicksilver.chat()

# Direct agent call
iex> Quicksilver.Agentic.execute_task("Analyze the project structure",
...>   workspace_root: "/path"
...> )
```

## Testing

```bash
mix test    # All tests
```

## Dependencies

```elixir
{:req, "~> 0.4"},           # HTTP client
{:jason, "~> 1.4"},         # JSON encoding/decoding
{:libgraph, "~> 0.16"},     # Graph algorithms (PageRank)
{:file_system, "~> 1.0"},   # File watching
{:flow, "~> 1.2"},          # Parallel processing
```
