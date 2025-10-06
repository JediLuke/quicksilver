defmodule Quicksilver.Tools.Formatter do
  @moduledoc """
  Formats tool information for LLM prompts and parses tool calls from LLM responses.

  This module bridges the gap between human-readable tool descriptions and
  LLM-friendly formats, as well as parsing various JSON formats that different
  models might produce.
  """

  require Logger

  @doc """
  Build a system prompt that includes available tools.

  Takes a list of tool info maps (from Registry.list_tools/0) and generates
  a comprehensive system prompt instructing the LLM how to use tools.
  """
  @spec system_prompt_with_tools([map()]) :: String.t()
  def system_prompt_with_tools(tools) do
    tools_json = Jason.encode!(tools, pretty: true)

    """
    You are a helpful AI assistant with access to tools that can help you complete tasks.

    When you need to use a tool, respond with a JSON object in the following format:
    {
      "tool": "tool_name",
      "arguments": {
        "param1": "value1",
        "param2": "value2"
      }
    }

    Available tools:
    #{tools_json}

    Guidelines:
    - Only use tools when necessary to complete the task
    - Use the exact tool names as specified
    - Provide all required parameters in the arguments object
    - If you don't need a tool, respond normally with text
    - After receiving tool results, you can use additional tools or provide a final answer

    Example tool call:
    {
      "tool": "read_file",
      "arguments": {
        "path": "src/main.ex"
      }
    }
    """
  end

  @doc """
  Parse an LLM response to detect tool calls.

  Returns:
  - {:tool_call, name, args} if a tool call is detected
  - {:text_response, text} if it's a normal text response
  - {:error, reason} if parsing fails
  """
  @spec parse_tool_call(String.t()) ::
          {:tool_call, String.t(), map()}
          | {:text_response, String.t()}
          | {:error, String.t()}
  def parse_tool_call(response) do
    response = String.trim(response)

    # Strategy 1: Try to parse entire response as JSON
    case Jason.decode(response) do
      {:ok, json} when is_map(json) ->
        extract_tool_call(json)

      _ ->
        # Strategy 2: Look for JSON embedded in text
        parse_embedded_json(response)
    end
  end

  ## Private Functions

  defp extract_tool_call(%{"tool" => tool_name, "arguments" => args})
       when is_binary(tool_name) and is_map(args) do
    {:tool_call, tool_name, args}
  end

  defp extract_tool_call(%{"tool_name" => tool_name, "arguments" => args})
       when is_binary(tool_name) and is_map(args) do
    {:tool_call, tool_name, args}
  end

  defp extract_tool_call(%{"name" => tool_name, "parameters" => args})
       when is_binary(tool_name) and is_map(args) do
    {:tool_call, tool_name, args}
  end

  defp extract_tool_call(%{"function" => %{"name" => name, "arguments" => args}})
       when is_binary(name) do
    # Handle OpenAI-style function calls
    args_map =
      case args do
        args when is_map(args) -> args
        args when is_binary(args) -> Jason.decode!(args)
      end

    {:tool_call, name, args_map}
  end

  defp extract_tool_call(_json) do
    {:error, "Invalid tool call format"}
  end

  defp parse_embedded_json(text) do
    # Try to find JSON objects in the text - improved regex to handle nested braces
    # Look for { ... "tool" ... "arguments": { ... } ... }
    json_regex = ~r/\{[^{}]*"tool"[^{}]*"arguments"[^{}]*\{[^{}]*\}[^{}]*\}/s

    case Regex.run(json_regex, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, json} ->
            extract_tool_call(json)

          {:error, _} ->
            # Failed to parse, try extracting differently
            extract_json_from_text(text)
        end

      nil ->
        # Try a more permissive approach
        extract_json_from_text(text)
    end
  end

  defp extract_json_from_text(text) do
    # Find any JSON-like structure with balanced braces
    case find_balanced_json(text) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, json} -> extract_tool_call(json)
          {:error, _} -> {:text_response, text}
        end

      :error ->
        {:text_response, text}
    end
  end

  defp find_balanced_json(text) do
    # Find the first { and try to match balanced braces
    case String.split(text, "{", parts: 2) do
      [_before, after_open] ->
        case find_closing_brace(after_open, 1, "") do
          {:ok, json_content} ->
            {:ok, "{" <> json_content}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp find_closing_brace("", _depth, _acc), do: :error

  defp find_closing_brace(<<char::utf8, rest::binary>>, depth, acc) do
    cond do
      char == ?{ ->
        find_closing_brace(rest, depth + 1, acc <> <<char::utf8>>)

      char == ?} ->
        if depth == 1 do
          {:ok, acc <> <<char::utf8>>}
        else
          find_closing_brace(rest, depth - 1, acc <> <<char::utf8>>)
        end

      true ->
        find_closing_brace(rest, depth, acc <> <<char::utf8>>)
    end
  end

  @doc """
  Format tool result for inclusion in conversation history.
  """
  @spec format_tool_result(String.t(), String.t() | map()) :: String.t()
  def format_tool_result(tool_name, result) when is_binary(result) do
    """
    Tool '#{tool_name}' returned:
    #{result}
    """
  end

  def format_tool_result(tool_name, {:ok, result}) do
    format_tool_result(tool_name, result)
  end

  def format_tool_result(tool_name, {:error, reason}) do
    """
    Tool '#{tool_name}' failed:
    Error: #{reason}
    """
  end

  @doc """
  Build conversation history string for the LLM.

  Takes a list of message maps and formats them into a prompt.
  """
  @spec format_conversation_history([map()]) :: String.t()
  def format_conversation_history(history) do
    history
    |> Enum.map(&format_message/1)
    |> Enum.join("\n\n")
  end

  defp format_message(%{role: "user", content: content}) do
    "User: #{content}"
  end

  defp format_message(%{role: "assistant", content: content}) do
    "Assistant: #{content}"
  end

  defp format_message(%{role: "tool", content: content}) do
    "#{content}"
  end

  defp format_message(%{role: "system", content: content}) do
    "System: #{content}"
  end

  defp format_message(_) do
    ""
  end
end
