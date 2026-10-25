defmodule Quicksilver.ConversationNativeToolsTest do
  use ExUnit.Case, async: true

  alias Quicksilver.Conversation

  defp tool_call(id, args) do
    raw = %{"id" => id, "type" => "function", "function" => %{"name" => "list_files", "arguments" => Jason.encode!(args)}}
    call = %{id: id, name: "list_files", arguments: {:ok, args}}
    {:ok, {:tool_calls, [call], %{role: "assistant", content: "", tool_calls: [raw]}}}
  end

  # Calls list_files once, then answers with what the tool returned
  defmodule OneCallBackend do
    def native_tools?, do: true
    def health_check(_opts), do: :ok

    def complete([%{role: "system"} | _] = messages, opts) do
      cond do
        opts[:tools] in [nil, []] -> {:error, :tools_not_sent}
        List.last(messages).role == "tool" -> {:ok, "done: " <> List.last(messages).content}
        true -> Quicksilver.ConversationNativeToolsTest.call_list_files("call_1")
      end
    end

    def complete(_messages, _opts), do: {:error, :system_prompt_not_first}
  end

  # Repeats the same call until nudged, then gives up
  defmodule LoopingBackend do
    def native_tools?, do: true
    def health_check(_opts), do: :ok

    def complete(messages, _opts) do
      last = List.last(messages)

      if last.role == "tool" and last.content =~ "already called" do
        {:ok, "gave up"}
      else
        Quicksilver.ConversationNativeToolsTest.call_list_files("call_#{length(messages)}")
      end
    end
  end

  def call_list_files(id), do: tool_call(id, %{"directory" => "lib", "pattern" => "*.ex"})

  test "runs structured tool calls and records them in history" do
    ctx = Conversation.new(tools: ["list_files"], workspace_root: File.cwd!(), backend: OneCallBackend)

    assert {:ok, "done: " <> result, updated} = Conversation.send(ctx, "what's in lib?")
    assert result =~ "Tool 'list_files' returned"
    assert result =~ "quicksilver.ex"

    assert [
             %{role: "user"},
             %{role: "assistant", tool_calls: [%{"id" => "call_1"}]},
             %{role: "tool", tool_call_id: "call_1"},
             %{role: "assistant", content: "done: " <> _}
           ] = Conversation.history(updated)
  end

  test "answers a repeated call with a nudge as that call's result" do
    ctx = Conversation.new(tools: ["list_files"], workspace_root: File.cwd!(), backend: LoopingBackend, max_iterations: 6)

    assert {:ok, "gave up", updated} = Conversation.send(ctx, "loop")

    tool_results = for %{role: "tool"} = msg <- Conversation.history(updated), do: msg.content
    assert [first, second, nudge] = tool_results
    assert first =~ "Tool 'list_files' returned" and second =~ "Tool 'list_files' returned"
    assert nudge =~ "already called list_files"
  end
end
