# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

Quicksilver is an Elixir-native agentic framework with tool-calling capabilities, organized into two independent layers:

1. **LLM Engine** (`lib/llm_engine/`) — standalone local LLM server management, usable independently
2. **Agentic** (`lib/agentic/`) — agents, tools, approval, repository map, and interfaces

The LLM engine knows nothing about agents. Agents depend on the engine for completions. Tools are backend-agnostic.

```
Terminal Interface (lib/agentic/interfaces/terminal.ex)
    ↓
Stateless Agent (lib/agentic/agent.ex)
    ↓
LLM Backend (lib/llm_engine/backends/llama_cpp.ex) → External LLM Server
    ↓
Tools (Registry + Individual Tools in lib/agentic/tools/)
```

### Supervision Tree

```elixir
Quicksilver.Supervisor (strategy: :one_for_one)
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Agentic.Tools.Registry (GenServer)
└── Quicksilver.Agentic.RepositoryMap.Cache.Server (GenServer)
```

Agents are **stateless** — the terminal manages conversation history and calls `Agent.execute_task/2` directly. No agent processes in the supervision tree.

### Key Design Patterns

**1. Stateless Agent with Per-Iteration Timeouts**

The Agent (`lib/agentic/agent.ex`) implements an iterative reasoning loop:
- Max 50 iterations per task (configurable)
- Each iteration has a 5-minute timeout (per-iteration, not total)
- Uses `Task.async` + `Task.yield` for per-iteration timeout control
- On each iteration: prompt LLM → parse response → execute tool → add to history → repeat
- Returns `{:ok, response, updated_history}` — caller manages state

**2. Tool System Architecture**

Tools are defined via `Quicksilver.Agentic.Tools.Behaviour`:
- `name/0` - Unique identifier
- `description/0` - LLM-facing description
- `parameters_schema/0` - JSON schema for arguments
- `execute/2` - Implementation (args, context)

The Registry (`lib/agentic/tools/registry.ex`) is a GenServer that stores tool modules and handles execution.

The Formatter (`lib/agentic/tools/formatter.ex`) converts tools to LLM prompts and parses tool calls from various JSON formats.

**3. Approval System for Destructive Operations**

Located in `lib/agentic/approval/`:
- `Policy` - Defines which tools require approval
- `Interactive` - Shows diffs and prompts user for [A]pprove/[R]eject/[Q]uit

Context includes `:approval_policy` which is checked before executing write tools.

**4. Backend Abstraction**

`lib/llm_engine/backend.ex` defines the behaviour. Currently only `LlamaCpp` is implemented, which:
- Manages llama.cpp server lifecycle (starts if not running)
- Uses HTTP API for completions
- Configured via `config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp, ...`

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
    ├── agent.ex                            # Stateless agent (request/response)
    ├── tools.ex                            # Tool registration convenience
    ├── tools/
    │   ├── behaviour.ex
    │   ├── registry.ex
    │   ├── formatter.ex
    │   ├── file_reader.ex
    │   ├── search_files.ex
    │   ├── list_files.ex
    │   ├── create_file.ex
    │   ├── edit_file.ex
    │   ├── run_tests.ex
    │   └── get_repository_context.ex
    ├── approval/
    │   ├── policy.ex
    │   └── interactive.ex
    ├── repository_map/
    │   ├── repository_map.ex
    │   ├── cache/server.ex
    │   ├── formatter/llm.ex
    │   ├── graph/builder.ex
    │   ├── graph/ranker.ex
    │   └── parser/
    │       ├── entity.ex
    │       ├── elixir_parser.ex
    │       └── repository_parser.ex
    └── interfaces/
        └── terminal.ex
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

1. Create module in `lib/agentic/tools/`
2. Implement `@behaviour Quicksilver.Agentic.Tools.Behaviour`
3. Add to `lib/agentic/tools.ex` `register_default_tools/0`
4. If destructive: integrate with approval system via context

## Agent Execution Context

When tools execute, they receive a `context` map with:
- `:workspace_root` - Base directory for file operations
- `:approval_policy` - Policy struct for approval checks

## Configuration

```elixir
# config/config.exs
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "...",
  model_path: "...",
  model_file: "...",
  port: 8080,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  auto_start: true
```

## Key Behaviours to Maintain

**Tool Uniqueness Validation**: The `edit_file` tool requires `old_string` to appear exactly once in the file.

**Backup Creation**: Always create backups before destructive operations (pattern: `path.backup.timestamp`).

**Per-Iteration Timeouts**: When modifying Agent, maintain per-iteration timeouts rather than total task timeouts.

**Tool Result Formatting**: Use `Formatter.format_tool_result/2` for consistent formatting.

## Testing

- Unit tests in `test/` directory
- Run terminal with `mix run start_chat.exs` for manual testing
- `mix test` runs all tests

## Common Pitfalls

1. **Config returns keyword list** - `Application.get_env(:quicksilver, Module)` returns a keyword list, convert with `Map.new/1` before using with `Map.merge/2`
2. **Tool registration timing** - Tools must be registered after supervision tree starts
3. **Agent is stateless** - No GenServer state; the terminal manages conversation history
4. **Approval policy** - Write tools should check `should_request_approval?/3` and call `Interactive.request_approval/2`
