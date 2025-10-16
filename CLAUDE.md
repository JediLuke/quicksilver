# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

Quicksilver is an Elixir-native agentic framework with tool-calling capabilities. The key architectural pattern is:

```
Terminal Interface (though any interface can be used)
    ↓
ToolAgent (GenServer, multiple agents can exist and be used)
    ↓
Backend (LlamaCpp) → External LLM Server
    ↓
Tools (Registry + Individual Tools)
```

### Critical Design Patterns

**1. Agentic Loop with Per-Iteration Timeouts**

The ToolAgent (`lib/quicksilver/agents/tool_agent.ex`) implements an iterative reasoning loop:
- Max 50 iterations per task (configurable)
- Each iteration has a 5-minute timeout (per-iteration, not total)
- Overall 10-minute safety timeout on the GenServer call
- Uses `Task.async` + `Task.yield` for per-iteration timeout control
- On each iteration: prompt LLM → parse response → execute tool → add to history → repeat

**2. Tool System Architecture**

Tools are defined via the `Quicksilver.Tools.Behaviour`:
- `name/0` - Unique identifier
- `description/0` - LLM-facing description
- `parameters_schema/0` - JSON schema for arguments
- `execute/2` - Implementation (args, context)

The Registry (`lib/quicksilver/tools/registry.ex`) is an Agent that stores tool modules and handles execution.

The Formatter (`lib/quicksilver/tools/formatter.ex`) converts tools to LLM prompts and parses tool calls from various JSON formats.

**3. Approval System for Destructive Operations**

Located in `lib/quicksilver/approval/`:
- `Policy` - Defines which tools require approval
- `Interactive` - Shows diffs and prompts user for [A]pprove/[R]eject/[Q]uit

Context includes `:approval_policy` which is checked before executing write tools.

**4. Backend Abstraction**

`lib/backends/backend.ex` defines the behaviour. Currently only `LlamaCpp` is implemented, which:
- Manages llama.cpp server lifecycle (starts if not running)
- Uses HTTP API for completions
- Configured in `config/config.exs`

### Supervision Tree

```elixir
Quicksilver.Supervisor
├── Registry (for agent processes)
├── Quicksilver.Backends.LlamaCpp (GenServer)
├── Quicksilver.Tools.Registry (Agent)
├── Quicksilver.Agents.ToolAgent (GenServer)
└── Quicksilver.Agents.Manager (GenServer)
```

All supervised processes start on application boot. Tools are registered after supervisor starts successfully.

## Available Tools (As of Current Implementation)

**Read-only:**
- `read_file` - Read file contents
- `search_files` - Search codebase (ripgrep/grep)
- `list_files` - List files with glob patterns

**Write (require approval):**
- `create_file` - Create new files
- `edit_file` - Edit existing files (uses exact string replacement with uniqueness validation)

**Utility:**
- `run_tests` - Execute `mix test` and return results

All write tools create `.backup.timestamp` files before modifications.

## Adding New Tools

1. Create module in `lib/quicksilver/tools/`
2. Implement `@behaviour Quicksilver.Tools.Behaviour`
3. Add to `lib/quicksilver/tools.ex` alias and `register_default_tools/0`
4. If destructive: integrate with approval system via context

## Agent Execution Context

When tools execute, they receive a `context` map with:
- `:workspace_root` - Base directory for file operations
- `:approval_policy` - Policy struct for approval checks

The ToolAgent automatically injects the default approval policy into context on each iteration.

## Terminal Interface

`lib/interfaces/terminal.ex` provides the interactive chat:
- Commands: `help`, `tools`, `agents`, `agent <name>`, `history`, `clear`, `exit`
- Multi-agent switching with conversation history preservation
- Routes to ToolAgent's `execute_task/3`

## Configuration

`config/config.exs` contains llama.cpp server settings:
- Server binary path
- Model path and filename
- Port, threads, context size, GPU layers

Update these paths to match your local setup.

## Key Behaviors to Maintain

**Tool Uniqueness Validation**: The `edit_file` tool requires `old_string` to appear exactly once in the file. This prevents ambiguous edits.

**Backup Creation**: Always create backups before destructive operations (pattern: `path.backup.timestamp`).

**Per-Iteration Timeouts**: When modifying ToolAgent, maintain the pattern of per-iteration timeouts rather than total task timeouts to allow long-running multi-tool tasks.

**Tool Result Formatting**: Use `Formatter.format_tool_result/2` to ensure consistent formatting of tool outputs in conversation history.

## Testing Notes

- Unit tests in `test/` directory
- Integration tests in `test_editing.exs` (tests file creation/editing with auto-approve policy)
- Run terminal with `mix run start_chat.exs` for manual testing

## Common Pitfalls

1. **Don't use total timeouts** - The GenServer call uses `:infinity` (with 10min safety timeout), individual iterations timeout at 5min
2. **Tool registration timing** - Tools must be registered after supervision tree starts
3. **Context propagation** - When adding recursive calls in ToolAgent, ensure `per_iteration_timeout` is passed through
4. **Approval policy** - Write tools should check `should_request_approval?/3` and call `Interactive.request_approval/2`

Based on the research, here are the **highest-impact, immediately actionable** insights for your coding agent:

## 1. Start with the "Repository Map" Pattern (70% Success Rate)
```python
# Use tree-sitter to parse your codebase into an AST
# Apply PageRank algorithm to the call graph
# This gives you a token-efficient representation of the entire codebase
```
**Why it matters**: Aider achieved state-of-the-art results with this. It's deterministic, comprehensive, and avoids RAG false positives. This single feature determines whether agents can find the right files to edit.

## 2. Implement the "Documentation-First" Workflow
Before ANY coding task:
1. Have the agent read/create: `PROJECT.md`, `ARCHITECTURE.md`, `CONVENTIONS.md`
2. Start every request with: "First, read all project summary docs..."
3. **Result**: 9/10 tasks correct on first try (proven in 40,000 line production system)

## 3. Use the Three-Layer Context Strategy
```
Layer 1: Just store file paths/URLs (not content)
Layer 2: Write notes to files (agent's permanent memory)  
Layer 3: Keep prompt prefixes stable for 10x cost reduction
```
**Critical**: Cached tokens cost $0.30 vs $3.00 per million. This makes or breaks economic viability.

## 4. Enforce TDD as Non-Negotiable Default
```python
workflow = [
    "Write failing tests first",
    "User reviews tests",
    "Write code to pass tests", 
    "Iterate until passing",
    "User reviews implementation"
]
```
**Why**: Agents excel at iteration loops. TDD is "much more powerful with agents than manual TDD" per Anthropic's research.

## 5. Build "Skills" That Compound Over Time
Create `SKILL.md` files that agents MUST follow when applicable:
```yaml
---
name: debug_api_error
when: API returns 4xx or 5xx
mandatory: true
---
1. Check request headers first
2. Validate authentication
3. Log full request/response
4. [specific steps for your system]
```
Agents can even create new skills for themselves. This solves the "permanent new hire" problem.

## 6. Keep Errors in Context (Don't Clear Them)
```python
# DON'T DO THIS:
if error:
    clear_context()
    retry()

# DO THIS:
if error:
    append_to_context(error_trace)
    retry()  # Agent learns from the error
```
**Impact**: 35-49% reduction in repeat mistakes. Errors update the model's priors.

## 7. Use Voice Input for Requirements
- Explain requirements verbally instead of typing
- Agent transcribes to structured docs
- Then implements from its own documentation
- **Result**: "Far, far faster" - saves multiple days per project

## 8. Implement the "Dual-Session" Architecture
- **Session 1**: Architect (designs and reviews)
- **Session 2**: Implementer (builds)
- Use `/clear` between chunks for fresh perspective
- **Why**: Prevents implementation bias in code review

## 9. Tool Descriptions Are Make-or-Break
```python
# BAD:
def calc(a, b): return a+b

# GOOD:
def add_numbers(a: float, b: float) -> float:
    """Add two numbers. Use ANYTIME you need addition.
    
    Args:
        a: First number to add
        b: Second number to add
    Returns:
        Sum of the two numbers
    """
```
Well-described tools have 2-3x higher correct usage rate.

## 10. The Review Reality Check
**Accept this truth**: Even with perfect setup, agents make structural mistakes ~10% of the time. You MUST review thoroughly. Treat output like it's from a productive but inexperienced junior developer.

## Quick Start Implementation Order

**Week 1**: Repository map + basic file operations + TDD workflow

**Week 2**: Documentation-first pattern + persistent memory files

**Week 3**: Skills system + error preservation in context

**Week 4**: Cache optimization + dual-session architecture

## The Single Most Important Pattern

If you implement nothing else, do this:

```
Research → Plan → User Reviews Plan → Execute → Verify → Commit
```

Never let the agent jump straight from request to code. This one pattern prevents 80% of problems.