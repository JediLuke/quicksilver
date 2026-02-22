defmodule QuicksilverTest do
  use ExUnit.Case

  test "chat function is available" do
    assert function_exported?(Quicksilver, :chat, 0)
    assert function_exported?(Quicksilver, :chat, 1)
  end

  test "agentic facade delegates" do
    assert function_exported?(Quicksilver.Agentic, :execute_task, 1)
    assert function_exported?(Quicksilver.Agentic, :execute_task, 2)
    assert function_exported?(Quicksilver.Agentic, :list_tools, 0)
    assert function_exported?(Quicksilver.Agentic, :register_tool, 1)
    assert function_exported?(Quicksilver.Agentic, :execute_tool, 2)
    assert function_exported?(Quicksilver.Agentic, :execute_tool, 3)
  end

  test "llm engine facade delegates" do
    assert function_exported?(Quicksilver.LlmEngine, :complete, 1)
    assert function_exported?(Quicksilver.LlmEngine, :complete, 2)
    assert function_exported?(Quicksilver.LlmEngine, :health_check, 0)
    assert function_exported?(Quicksilver.LlmEngine, :health_check, 1)
  end

  test "tools are registered on startup" do
    tools = Quicksilver.Agentic.Tools.list_tools()
    assert length(tools) > 0

    tool_names = Enum.map(tools, & &1.name)
    assert "read_file" in tool_names
    assert "search_files" in tool_names
    assert "list_files" in tool_names
    assert "create_file" in tool_names
    assert "edit_file" in tool_names
    assert "run_tests" in tool_names
    assert "get_repository_context" in tool_names
  end
end
