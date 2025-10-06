# Quicksilver Tool-Calling Agent - Implementation Plan

## Executive Summary

This document outlines the complete implementation plan for adding tool-calling capabilities to Quicksilver. The design uses a modular, behavior-driven architecture that works with any LLM backend and provides a solid foundation for building agentic capabilities.

## Current State

**Project**: Quicksilver - Elixir-based LLM agent framework
**Location**: `/home/luke/workbench/quicksilver`
**Existing Components**:
- `Quicksilver.Backends.LlamaCpp` - Working llama.cpp backend
- Terminal interface (recently added)
- Basic agent scaffolding in `lib/agents/` (untracked files)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Tool-Calling Agent                       │
│  ┌──────────────┐        ┌──────────────┐                   │
│  │  ToolAgent   │───────▶│   Backend    │ (abstracted)      │
│  │  (GenServer) │        │  Behaviour   │                   │
│  └──────┬───────┘        └──────────────┘                   │
│         │                                                   │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────┐        ┌──────────────┐                   │
│  │    Tools     │───────▶│     Tool     │                   │
│  │   Registry   │        │  Behaviour   │                   │
│  │  (GenServer) │        └──────────────┘                   │
│  └──────┬───────┘              ▲                            │
│         │                      │                            │
│         │          ┌───────────┴───────────┐                │
│         │          │                       │                │
│         └─────────▶│  FileReader           │                │
│                    │  SearchFiles          │                │
│                    │  [Future Tools...]    │                │
│                    └───────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Principles

1. **Backend Agnostic**: Works with any LLM backend (LlamaCpp, OpenAI, Anthropic, etc.)
2. **Safe by Default**: Initial tools are read-only (file reading, searching)
3. **Extensible**: Easy to add new tools via behaviour pattern
4. **Flexible Parsing**: Handles various JSON formats from different models
5. **Iterative Loop**: Supports multi-step reasoning with tool calls
6. **Production Ready**: Proper error handling, logging, and supervision

## Implementation Steps

### Phase 1: Core Infrastructure

#### 1.1 Tool Behaviour (`lib/quicksilver/tools/behaviour.ex`)
```elixir
defmodule Quicksilver.Tools.Behaviour do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback execute(args :: map(), context :: map()) ::
    {:ok, String.t()} | {:error, String.t()}
end
```

**Purpose**: Define contract for all tools
**Dependencies**: None
**Testing**: Compile-time checks via behaviour

#### 1.2 Tools Registry (`lib/quicksilver/tools/registry.ex`)
**Purpose**: Centralized tool discovery and execution
**Key Functions**:
- `register(tool_module)` - Add tools dynamically
- `list_tools()` - Get all tools (for prompt construction)
- `execute_tool(name, args, context)` - Run a tool by name

**State**: `%{tools: %{name => module}}`
**Testing**:
- Register valid/invalid tools
- Execute existing/non-existing tools
- List tools returns correct format

#### 1.3 Tool Formatter (`lib/quicksilver/tools/formatter.ex`)
**Purpose**: Bridge between LLM and tools
**Key Functions**:
- `system_prompt_with_tools(tools)` - Build system prompt with tool descriptions
- `parse_tool_call(response)` - Extract tool calls from LLM output

**Response Types**:
- `{:tool_call, name, args}` - Tool invocation detected
- `{:text_response, text}` - Normal text response
- `{:error, reason}` - Parse failure

**Parsing Strategy** (in order):
1. Direct JSON object
2. JSON embedded in text (regex extraction)
3. Fallback to text response

### Phase 2: Backend Abstraction

#### 2.1 Backend Behaviour (`lib/quicksilver/backends/behaviour.ex`)
```elixir
defmodule Quicksilver.Backends.Behaviour do
  @callback completion(prompt :: String.t(), opts :: keyword()) ::
    {:ok, String.t()} | {:error, String.t()}
end
```

**Purpose**: Decouple ToolAgent from specific LLM implementations
**Implementation Required**: Update `Quicksilver.Backends.LlamaCpp` to implement this behaviour

### Phase 3: Basic Tools

#### 3.1 File Reader (`lib/quicksilver/tools/file_reader.ex`)
**Tool Name**: `read_file`
**Parameters**: `path` (string)
**Safety Features**:
- Workspace-relative path resolution
- Truncate large files (>50KB)
- Handle ENOENT and other errors gracefully

**Context Usage**: `context[:workspace_root]` for path resolution

#### 3.2 Search Files (`lib/quicksilver/tools/search_files.ex`)
**Tool Name**: `search_files`
**Parameters**:
- `pattern` (required) - Text to search for
- `directory` (optional) - Where to search
- `file_pattern` (optional) - Filter by filename pattern

**Search Strategy** (fallback chain):
1. Try `ripgrep` (fastest)
2. Try `grep` + `find`
3. Pure Elixir implementation

**Result Limiting**: Max 20 results to avoid context overflow

### Phase 4: Tool Agent

#### 4.1 ToolAgent GenServer (`lib/quicksilver/agents/tool_agent.ex`)

**State Structure**:
```elixir
%{
  backend_module: Quicksilver.Backends.LlamaCpp,
  tools_registry: Quicksilver.Tools.Registry,
  max_iterations: 5,
  conversation_history: []
}
```

**Core Loop** (`execute_with_tools/3`):
1. Build prompt with tools + history
2. Call LLM backend
3. Parse response:
   - If tool call → execute tool → add to history → recurse
   - If text response → return final answer
   - If error → return error
4. Max iterations check prevents infinite loops

**Conversation History Format**:
```elixir
[
  %{role: "user", content: "..."},
  %{role: "assistant", content: "Using tool: read_file"},
  %{role: "tool", content: "Tool 'read_file' returned:\n..."},
  ...
]
```

**Error Handling**:
- Backend failures (network, timeout)
- Tool execution failures
- Parse failures
- Max iterations exceeded

### Phase 5: Integration

#### 5.1 Main Module (`lib/quicksilver/tools.ex`)
**Purpose**: Convenience module for tool registration
**Function**: `register_default_tools/0` - Registers FileReader and SearchFiles

#### 5.2 Application Supervisor (`lib/quicksilver/application.ex`)

**Supervision Tree**:
```elixir
children = [
  # Existing children...
  Quicksilver.Tools.Registry,
  {Quicksilver.Agents.ToolAgent,
   [
     backend_module: Quicksilver.Backends.LlamaCpp,
     name: Quicksilver.Agents.ToolAgent
   ]}
]
```

**Startup Sequence**:
1. Start Registry
2. Start ToolAgent (validates backend behaviour)
3. Register default tools

### Phase 6: Testing & Validation

#### 6.1 Test Script (`test_tools.exs`)
**Tests**:
1. List available tools
2. Read a file (README.md)
3. Search for pattern ("defmodule")
4. Interactive mode

**Run**: `mix run test_tools.exs`

#### 6.2 IEx Testing
```elixir
# Start application
iex -S mix

# Execute task
Quicksilver.Agents.ToolAgent.execute_task(
  "Read the mix.exs file and list dependencies"
)

# Check registered tools
Quicksilver.Tools.Registry.list_tools()
```

## File Checklist

### New Files to Create
- [ ] `lib/quicksilver/backends/behaviour.ex`
- [ ] `lib/quicksilver/tools/behaviour.ex`
- [ ] `lib/quicksilver/tools/registry.ex`
- [ ] `lib/quicksilver/tools/formatter.ex`
- [ ] `lib/quicksilver/tools/file_reader.ex`
- [ ] `lib/quicksilver/tools/search_files.ex`
- [ ] `lib/quicksilver/agents/tool_agent.ex`
- [ ] `lib/quicksilver/tools.ex`
- [ ] `test_tools.exs` (optional, for manual testing)

### Files to Modify
- [ ] `lib/quicksilver/application.ex` - Add Registry and ToolAgent to supervision tree
- [ ] `lib/quicksilver/backends/llama_cpp.ex` - Add `@behaviour` and implement `completion/2`

### Directory Structure
```
lib/quicksilver/
├── backends/
│   ├── behaviour.ex          # NEW
│   └── llama_cpp.ex          # MODIFY
├── tools/
│   ├── behaviour.ex          # NEW
│   ├── registry.ex           # NEW
│   ├── formatter.ex          # NEW
│   ├── file_reader.ex        # NEW
│   └── search_files.ex       # NEW
├── agents/
│   └── tool_agent.ex         # NEW
├── tools.ex                  # NEW
└── application.ex            # MODIFY
```

## Implementation Order (Recommended)

1. **Behaviours first** (no dependencies):
   - `backends/behaviour.ex`
   - `tools/behaviour.ex`

2. **Registry and Formatter** (core infrastructure):
   - `tools/registry.ex`
   - `tools/formatter.ex`

3. **Concrete Tools** (implements behaviour):
   - `tools/file_reader.ex`
   - `tools/search_files.ex`

4. **Agent** (uses everything):
   - `agents/tool_agent.ex`

5. **Integration** (wires it all together):
   - `tools.ex`
   - Modify `application.ex`
   - Update `backends/llama_cpp.ex`

6. **Testing**:
   - Create `test_tools.exs`
   - Manual IEx testing

## Critical Implementation Notes

### 1. Backend Integration
Your existing `Quicksilver.Backends.LlamaCpp` needs to expose a `completion/2` function:

```elixir
defmodule Quicksilver.Backends.LlamaCpp do
  @behaviour Quicksilver.Backends.Behaviour

  @impl true
  def completion(prompt, opts \\ []) do
    # Your existing llama.cpp call here
    # Must return {:ok, text} or {:error, reason}
  end
end
```

**Check**: Look at your current LlamaCpp module to understand the API.

### 2. Tool Context
The `context` parameter passed to `execute/2` should include:
- `workspace_root`: Base directory for relative paths
- Any other environment info tools might need

Initialize this in ToolAgent or pass from application config.

### 3. Prompt Engineering
The system prompt in `Formatter.system_prompt_with_tools/1` is critical. Models vary in their ability to output JSON. You may need to:
- Add examples for your specific model
- Adjust the format based on model behavior
- Enable debug logging to see raw LLM output

### 4. Context Window Management
The current implementation accumulates history indefinitely. For production:
- Monitor conversation history size
- Implement truncation strategy (keep recent N messages)
- Consider summarization for long conversations

### 5. Model Requirements
**Best Results**:
- Mistral 7B+
- Llama 3 8B+
- CodeLlama 7B+
- Any model fine-tuned for tool use

**May Struggle**:
- Smaller models (<7B parameters)
- Models not trained on instruction following
- Models without JSON output training

### 6. Security Considerations
Current design is **read-only** by default. When adding write/execute tools:
- Implement approval mechanism
- Sandbox execution environments
- Validate all inputs
- Log all tool executions
- Consider rate limiting

## Debugging Guide

### Tool Calls Not Detected
1. Enable debug logging: `Logger.configure(level: :debug)`
2. Check raw LLM output in logs
3. Try adding examples to system prompt
4. Verify model supports JSON output

### LlamaCpp Backend Issues
1. Verify model is loaded: Check application startup logs
2. Test backend directly: `Quicksilver.Backends.LlamaCpp.completion("test")`
3. Check context window: Ensure prompt fits in model's context
4. Verify model file path and parameters

### Registry Issues
1. Check tools are registered: `Quicksilver.Tools.Registry.list_tools()`
2. Verify modules implement behaviour (compile-time warnings)
3. Check GenServer is started in supervision tree

### Infinite Loops
- Check `max_iterations` setting (default: 5)
- Review conversation history for repeated patterns
- Ensure tools return proper success/error tuples

## Future Enhancements

### Phase 7: Additional Tools
- **File Writer**: Write/edit files (with approval)
- **Git Operations**: Commit, branch, diff
- **Code Execution**: Run tests, scripts (sandboxed)
- **Web Search**: Fetch documentation
- **AST Analysis**: Parse and analyze code structure

### Phase 8: Advanced Features
- **Streaming**: Stream tool execution progress
- **Parallel Tools**: Execute multiple tools concurrently
- **Tool Composition**: Chain tools automatically
- **Approval System**: User confirmation for dangerous ops
- **Tool Result Caching**: Avoid redundant tool calls
- **Conversation Persistence**: Save/restore agent state

### Phase 9: UI/UX
- **Progress Indicators**: Show which tool is executing
- **Approval Prompts**: Interactive y/n for dangerous ops
- **Tool Output Formatting**: Syntax highlighting, tables
- **Undo/Rollback**: Revert tool executions

## Success Criteria

✅ **Minimum Viable Implementation**:
- [ ] Agent can read files using `read_file` tool
- [ ] Agent can search codebases using `search_files` tool
- [ ] Agent completes multi-step tasks (read → search → synthesize)
- [ ] Error handling works (missing files, invalid patterns)
- [ ] No hardcoded backend references (fully abstracted)

✅ **Production Ready**:
- [ ] All tools have proper error handling
- [ ] Logging at appropriate levels
- [ ] Supervision tree handles crashes
- [ ] Context window limits respected
- [ ] Test coverage for critical paths

## Questions to Resolve During Implementation

1. **What's the current state of `Quicksilver.Backends.LlamaCpp`?**
   - Does it already have a `completion/2` function?
   - What does the response format look like?
   - Are there streaming capabilities?

2. **What model are you using?**
   - Model size and architecture?
   - Context window size?
   - Known quirks with JSON output?

3. **Where should workspace_root come from?**
   - Application config?
   - Environment variable?
   - CWD?

4. **Do you want the terminal interface to show tool execution?**
   - Progress indicators?
   - Approval prompts?
   - Pretty formatting?

## Quick Start (Next Session)

```elixir
# 1. Create behaviour files (copy from prompts/tool_calls.md)
# 2. Create Registry
# 3. Create Formatter
# 4. Create FileReader tool
# 5. Test in isolation:

iex> Quicksilver.Tools.Registry.start_link([])
iex> Quicksilver.Tools.Registry.register(Quicksilver.Tools.FileReader)
iex> Quicksilver.Tools.Registry.execute_tool("read_file", %{"path" => "README.md"})
{:ok, "# Quicksilver\n..."}

# 6. Continue with remaining components
```

## Reference Material

- Original design doc: `/home/luke/workbench/quicksilver/prompts/tool_calls.md`
- This implementation plan: `/home/luke/workbench/quicksilver/TOOL_CALLING_IMPLEMENTATION.md`

---

**Ready to implement**: This document contains everything needed to build tool-calling from scratch. Start with Phase 1, test incrementally, and iterate based on your model's behavior.
