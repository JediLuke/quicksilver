# Quicksilver

## Project Overview

**Project Name**: Quicksilver
**Version**: 0.1.0
**Language**: Elixir
**Purpose**: An Elixir-based LLM agent framework with tool-calling capabilities

## What is Quicksilver?

Quicksilver is a flexible agent framework that allows LLMs to interact with their environment through tools. It provides:

- **Backend Abstraction**: Works with any LLM backend (currently supports llama.cpp)
- **Tool System**: Extensible tool-calling architecture via Elixir behaviours
- **Agentic Loop**: Iterative reasoning with multi-step tool execution
- **Safe by Default**: Read-only tools initially (file reading, searching)

## Architecture

### Core Components

1. **Backends** (`lib/backends/`)
   - `LlamaCpp` - llama.cpp integration for local LLM inference
   - `Behaviour` - Abstract interface for any LLM provider

2. **Tools** (`lib/quicksilver/tools/`)
   - `Registry` - Manages tool registration and execution
   - `Formatter` - Converts tools to LLM prompts, parses tool calls
   - `FileReader` - Read file contents safely
   - `SearchFiles` - Search codebase with ripgrep/grep

3. **Agents** (`lib/quicksilver/agents/`)
   - `ToolAgent` - Main agentic loop with tool-calling
   - `Manager` - Manages multiple agent instances

4. **Interfaces**
   - `Terminal` - Interactive command-line chat interface

## Available Tools

### read_file
Read the contents of a file from the workspace.
- **Parameters**: `path` (string) - relative or absolute file path
- **Safety**: Truncates files >100KB, workspace-aware path resolution

### search_files
Search for text patterns in files within the workspace.
- **Parameters**:
  - `pattern` (required) - text to search for
  - `directory` (optional) - where to search
  - `file_pattern` (optional) - filter by filename (e.g., "*.ex")
- **Features**: Uses ripgrep if available, limits results to avoid context overflow

## How It Works

1. User sends a message to the ToolAgent
2. Agent builds a prompt with available tools and conversation history
3. LLM responds with either:
   - A tool call (JSON format)
   - A final text response
4. If tool call: Execute tool → Add result to history → Loop (max 10 iterations)
5. If text response: Return answer to user

## Example Usage

```elixir
# Start interactive chat
iex> Quicksilver.Interfaces.Terminal.start()

# Or execute a task directly
iex> Quicksilver.Agents.ToolAgent.execute_task(
  "Read the mix.exs file and tell me the dependencies"
)
```

## Development

- **Config**: `config/config.exs` - llama.cpp server settings
- **Tests**: `test_tools.exs` - Tool system validation
- **Logs**: Logger configured for debug-level output during development

## Future Enhancements

- Write/edit file tools (with approval)
- Git operations
- Code execution (sandboxed)
- Web search capabilities
- Parallel tool execution
- Conversation persistence
