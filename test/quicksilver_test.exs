defmodule QuicksilverTest do
  use ExUnit.Case

  test "chat function is available" do
    assert function_exported?(Quicksilver, :chat, 0)
    assert function_exported?(Quicksilver, :chat, 1)
  end

  test "new_conversation convenience is available" do
    assert function_exported?(Quicksilver, :new_conversation, 0)
    assert function_exported?(Quicksilver, :new_conversation, 1)
  end

  test "agentic facade delegates" do
    assert function_exported?(Quicksilver.Agentic, :list_tools, 0)
    assert function_exported?(Quicksilver.Agentic, :register_tool, 1)
    assert function_exported?(Quicksilver.Agentic, :execute_tool, 2)
    assert function_exported?(Quicksilver.Agentic, :execute_tool, 3)
    assert function_exported?(Quicksilver.Agentic, :new_conversation, 0)
    assert function_exported?(Quicksilver.Agentic, :new_conversation, 1)
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

defmodule Quicksilver.ConversationTest do
  use ExUnit.Case

  alias Quicksilver.Conversation

  describe "new/1" do
    test "creates a bare conversation with defaults" do
      conv = Conversation.new()

      assert conv.history == []
      assert conv.system_prompt == nil
      assert conv.tools == :none
      assert conv.backend_module == Quicksilver.LlmEngine.Backends.LlamaCpp
      assert conv.backend_pid == Quicksilver.LlmEngine.Backends.LlamaCpp
      assert conv.workspace_root == nil
      assert conv.max_iterations == 50
      assert conv.per_iteration_timeout == 300_000
      assert conv.approval_policy == nil
    end

    test "creates a conversation with system prompt" do
      conv = Conversation.new(system_prompt: "You are helpful.")

      assert conv.system_prompt == "You are helpful."
      assert conv.tools == :none
    end

    test "creates a tool-calling conversation" do
      conv = Conversation.new(tools: :all, workspace_root: "/tmp")

      assert conv.tools == :all
      assert conv.workspace_root == "/tmp"
    end

    test "creates a conversation with selective tools" do
      conv = Conversation.new(tools: ["read_file", "search_files"])

      assert conv.tools == ["read_file", "search_files"]
    end

    test "accepts custom backend configuration" do
      conv = Conversation.new(
        backend_module: SomeBackend,
        backend_pid: :my_backend
      )

      assert conv.backend_module == SomeBackend
      assert conv.backend_pid == :my_backend
    end

    test "accepts initial history" do
      history = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
      conv = Conversation.new(history: history)

      assert conv.history == history
    end

    test "accepts custom iteration settings" do
      conv = Conversation.new(max_iterations: 10, per_iteration_timeout: 60_000)

      assert conv.max_iterations == 10
      assert conv.per_iteration_timeout == 60_000
    end
  end

  describe "history/1" do
    test "returns empty history for new conversation" do
      conv = Conversation.new()
      assert Conversation.history(conv) == []
    end

    test "returns history from conversation" do
      history = [%{role: "user", content: "hi"}]
      conv = Conversation.new(history: history)
      assert Conversation.history(conv) == history
    end
  end

  describe "clear/1" do
    test "clears history but preserves config" do
      conv = Conversation.new(
        system_prompt: "Be helpful.",
        tools: :all,
        workspace_root: "/tmp",
        history: [%{role: "user", content: "hi"}]
      )

      cleared = Conversation.clear(conv)

      assert cleared.history == []
      assert cleared.system_prompt == "Be helpful."
      assert cleared.tools == :all
      assert cleared.workspace_root == "/tmp"
    end
  end

  describe "send/2 dispatch" do
    test "bare conversation dispatches to Simple" do
      # We can verify the dispatch by checking that tools: :none
      # goes through Simple (which will fail at the backend call,
      # but the dispatch itself is what we're testing)
      conv = Conversation.new(
        backend_module: __MODULE__.MockBackend,
        backend_pid: self()
      )

      assert {:ok, "mock response", updated} = Conversation.send(conv, "hello")
      assert length(Conversation.history(updated)) == 2

      [user_msg, assistant_msg] = Conversation.history(updated)
      assert user_msg.role == "user"
      assert user_msg.content == "hello"
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "mock response"
    end

    test "tool conversation dispatches to ToolCalling" do
      conv = Conversation.new(
        tools: :all,
        workspace_root: File.cwd!(),
        backend_module: __MODULE__.MockBackend,
        backend_pid: self()
      )

      assert {:ok, "mock response", updated} = Conversation.send(conv, "hello")
      assert length(Conversation.history(updated)) >= 2
    end

    test "selective tools conversation dispatches to ToolCalling" do
      conv = Conversation.new(
        tools: ["read_file"],
        workspace_root: File.cwd!(),
        backend_module: __MODULE__.MockBackend,
        backend_pid: self()
      )

      assert {:ok, "mock response", updated} = Conversation.send(conv, "hello")
      assert length(Conversation.history(updated)) >= 2
    end
  end

  describe "multi-turn conversation" do
    test "history accumulates across sends" do
      conv = Conversation.new(
        backend_module: __MODULE__.MockBackend,
        backend_pid: self()
      )

      {:ok, _, conv} = Conversation.send(conv, "first")
      assert length(Conversation.history(conv)) == 2

      {:ok, _, conv} = Conversation.send(conv, "second")
      assert length(Conversation.history(conv)) == 4

      {:ok, _, conv} = Conversation.send(conv, "third")
      assert length(Conversation.history(conv)) == 6
    end
  end

  # Mock backend that returns a simple text response
  defmodule MockBackend do
    def complete(_pid, _messages, _opts) do
      {:ok, "mock response"}
    end

    def health_check(_pid), do: :ok
  end
end
