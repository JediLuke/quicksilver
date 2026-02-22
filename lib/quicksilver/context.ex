defmodule Quicksilver.Conversation do
  @moduledoc """
  An ephemeral conversation thread with an LLM.

  A Conversation is a data structure (not a process) that tracks message history
  and configuration. The simplest conversation is a bare chat: no tools, no system
  prompt. Send a message, get a response, history grows. A tool-calling conversation
  adds an iterative tool-execution loop before producing a final answer.

  Quicksilver provides ephemeral conversation threads, not agents. Real agents —
  things with goals, directives, persistence — belong in a layer above Quicksilver.
  Each such agent might own one or more Quicksilver conversations.

  ## Examples

      # Bare chat
      conv = Quicksilver.Conversation.new()
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Hello!")

      # Chat with a system prompt
      conv = Quicksilver.Conversation.new(system_prompt: "You are an Elixir expert.")
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "What is GenServer?")

      # Tool-calling conversation
      conv = Quicksilver.Conversation.new(
        tools: :all,
        workspace_root: File.cwd!()
      )
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Read mix.exs")

      # Selective tools
      conv = Quicksilver.Conversation.new(
        tools: ["read_file", "search_files", "list_files"]
      )

  """

  alias Quicksilver.LlmEngine.Backends.LlamaCpp

  defstruct history: [],
            system_prompt: nil,
            tools: :none,
            backend_module: LlamaCpp,
            backend_pid: LlamaCpp,
            workspace_root: nil,
            max_iterations: 50,
            per_iteration_timeout: 300_000,
            approval_policy: nil

  @type t :: %__MODULE__{
          history: [map()],
          system_prompt: String.t() | nil,
          tools: :none | :all | [String.t()],
          backend_module: module(),
          backend_pid: atom() | pid(),
          workspace_root: String.t() | nil,
          max_iterations: pos_integer(),
          per_iteration_timeout: pos_integer(),
          approval_policy: struct() | nil
        }

  @doc """
  Create a new conversation.

  ## Options

  - `:system_prompt` - System prompt prepended to every LLM call (default: nil)
  - `:tools` - `:none` (bare chat), `:all`, or list of tool name strings (default: `:none`)
  - `:backend_module` - LLM backend module (default: LlamaCpp)
  - `:backend_pid` - Backend process name/pid (default: backend module)
  - `:workspace_root` - Base directory for file operations (default: nil)
  - `:max_iterations` - Max tool-calling iterations per send (default: 50)
  - `:per_iteration_timeout` - Timeout per LLM call in ms (default: 300_000)
  - `:approval_policy` - Approval policy for destructive tools (default: nil)
  - `:history` - Initial message history (default: [])
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    backend_module = Keyword.get(opts, :backend_module, LlamaCpp)

    %__MODULE__{
      history: Keyword.get(opts, :history, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      tools: Keyword.get(opts, :tools, :none),
      backend_module: backend_module,
      backend_pid: Keyword.get(opts, :backend_pid, backend_module),
      workspace_root: Keyword.get(opts, :workspace_root),
      max_iterations: Keyword.get(opts, :max_iterations, 50),
      per_iteration_timeout: Keyword.get(opts, :per_iteration_timeout, 300_000),
      approval_policy: Keyword.get(opts, :approval_policy)
    }
  end

  @doc """
  Send a message and get a response.

  For bare conversations (tools: :none), makes a single LLM call.
  For tool-calling conversations, runs an iterative loop until the LLM
  produces a final text response.

  Returns `{:ok, response, updated_conversation}` or `{:error, reason}`.
  """
  @spec send(t(), String.t()) :: {:ok, String.t(), t()} | {:error, String.t()}
  def send(%__MODULE__{tools: :none} = conv, message) do
    Quicksilver.Conversation.Simple.send(conv, message)
  end

  def send(%__MODULE__{} = conv, message) do
    Quicksilver.Conversation.ToolCalling.send(conv, message)
  end

  @doc """
  Return the message history.
  """
  @spec history(t()) :: [map()]
  def history(%__MODULE__{history: history}), do: history

  @doc """
  Clear the message history, preserving configuration.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = conv), do: %{conv | history: []}
end
