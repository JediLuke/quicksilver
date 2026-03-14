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

  test "top-level facade delegates" do
    assert function_exported?(Quicksilver, :list_tools, 0)
    assert function_exported?(Quicksilver, :register_tool, 1)
    assert function_exported?(Quicksilver, :execute_tool, 2)
    assert function_exported?(Quicksilver, :execute_tool, 3)
  end

  test "llm engine facade delegates" do
    assert function_exported?(Quicksilver.LlmEngine, :complete, 1)
    assert function_exported?(Quicksilver.LlmEngine, :complete, 2)
    assert function_exported?(Quicksilver.LlmEngine, :health_check, 0)
    assert function_exported?(Quicksilver.LlmEngine, :health_check, 1)
  end

  test "tools are registered on startup" do
    tools = Quicksilver.Tools.list_tools()
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
      ctx = Conversation.new()

      assert ctx.history == []
      assert ctx.system_prompt == nil
      assert ctx.tools == :none
      assert ctx.backend == :llama_cpp
      assert ctx.backend_state == %{}
      assert ctx.workspace_root == nil
      assert ctx.max_iterations == 50
      assert ctx.per_iteration_timeout == 300_000
      assert ctx.approve == nil
    end

    test "creates a conversation with system prompt" do
      ctx = Conversation.new(system_prompt: "You are helpful.")

      assert ctx.system_prompt == "You are helpful."
      assert ctx.tools == :none
    end

    test "creates a tool-calling conversation" do
      ctx = Conversation.new(tools: :all, workspace_root: "/tmp")

      assert ctx.tools == :all
      assert ctx.workspace_root == "/tmp"
    end

    test "creates a conversation with selective tools" do
      ctx = Conversation.new(tools: ["read_file", "search_files"])

      assert ctx.tools == ["read_file", "search_files"]
    end

    test "accepts custom backend" do
      ctx = Conversation.new(backend: :openai)

      assert ctx.backend == :openai
    end

    test "accepts initial history" do
      history = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
      ctx = Conversation.new(history: history)

      assert ctx.history == history
    end

    test "accepts custom iteration settings" do
      ctx = Conversation.new(max_iterations: 10, per_iteration_timeout: 60_000)

      assert ctx.max_iterations == 10
      assert ctx.per_iteration_timeout == 60_000
    end
  end

  describe "history/1" do
    test "returns empty history for new conversation" do
      ctx = Conversation.new()
      assert Conversation.history(ctx) == []
    end

    test "returns history from conversation" do
      history = [%{role: "user", content: "hi"}]
      ctx = Conversation.new(history: history)
      assert Conversation.history(ctx) == history
    end
  end

  describe "clear/1" do
    test "clears history but preserves config" do
      ctx = Conversation.new(
        system_prompt: "Be helpful.",
        tools: :all,
        workspace_root: "/tmp",
        history: [%{role: "user", content: "hi"}]
      )

      cleared = Conversation.clear(ctx)

      assert cleared.history == []
      assert cleared.system_prompt == "Be helpful."
      assert cleared.tools == :all
      assert cleared.workspace_root == "/tmp"
    end
  end

  describe "send/2 dispatch" do
    test "bare conversation makes a single LLM call" do
      ctx = Conversation.new(backend: __MODULE__.MockBackend)

      assert {:ok, "mock response", updated} = Conversation.send(ctx, "hello")
      assert length(Conversation.history(updated)) == 2

      [user_msg, assistant_msg] = Conversation.history(updated)
      assert user_msg.role == "user"
      assert user_msg.content == "hello"
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "mock response"
    end

    test "tool conversation runs iterative tool loop" do
      ctx = Conversation.new(
        tools: :all,
        workspace_root: File.cwd!(),
        backend: __MODULE__.MockBackend
      )

      assert {:ok, "mock response", updated} = Conversation.send(ctx, "hello")
      assert length(Conversation.history(updated)) >= 2
    end

    test "selective tools conversation runs iterative tool loop" do
      ctx = Conversation.new(
        tools: ["read_file"],
        workspace_root: File.cwd!(),
        backend: __MODULE__.MockBackend
      )

      assert {:ok, "mock response", updated} = Conversation.send(ctx, "hello")
      assert length(Conversation.history(updated)) >= 2
    end
  end

  describe "multi-turn conversation" do
    test "history accumulates across sends" do
      ctx = Conversation.new(backend: __MODULE__.MockBackend)

      {:ok, _, ctx} = Conversation.send(ctx, "first")
      assert length(Conversation.history(ctx)) == 2

      {:ok, _, ctx} = Conversation.send(ctx, "second")
      assert length(Conversation.history(ctx)) == 4

      {:ok, _, ctx} = Conversation.send(ctx, "third")
      assert length(Conversation.history(ctx)) == 6
    end
  end

  # Mock backend that returns a simple text response (new pidless API)
  defmodule MockBackend do
    def complete(_messages, _opts) do
      {:ok, "mock response"}
    end

    def health_check(_opts), do: :ok
  end
end
