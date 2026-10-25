defmodule Quicksilver.ContextLib.ElixirCodingAssistant do
  @moduledoc """
  Pre-configured conversation context for Elixir coding assistance.

  Starts a terminal chat with a coding-focused system prompt and
  relevant tools pre-selected.

  ## Usage

      Quicksilver.ContextLib.ElixirCodingAssistant.start()
      Quicksilver.ContextLib.ElixirCodingAssistant.start(backend: :claude_cli)
  """

  @tools [
    "read_file",
    "search_files",
    "list_files",
    "get_repository_context",
    "edit_file",
    "create_file",
    "run_tests"
  ]

  @system_prompt """
  You are an expert Elixir developer. You help with writing, debugging, and \
  improving Elixir code.

  Guidelines:
  - Follow Elixir conventions and idioms
  - Prefer pattern matching and pipeline operators
  - Write clear, well-structured modules
  - Use the available tools to read and understand the codebase before making changes
  - When editing code, read the file first to understand context
  - Run tests after making changes to verify correctness
  """

  @doc """
  Start a terminal chat session configured for Elixir coding.

  Accepts the same options as `Quicksilver.Interfaces.Terminal.start/1`,
  but defaults to Elixir-appropriate tools and system prompt.
  """
  def start(opts \\ []) do
    opts =
      [
        tools: @tools,
        system_prompt: @system_prompt
      ]
      |> Keyword.merge(opts)

    Quicksilver.Interfaces.Terminal.start(opts)
  end
end

defmodule CodingAssistant do
  @moduledoc """
  Short alias for `Quicksilver.ContextLib.ElixirCodingAssistant` for IEx convenience.
  """
  defdelegate start(opts \\ []), to: Quicksilver.ContextLib.ElixirCodingAssistant
end
