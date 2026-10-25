defmodule Quicksilver.Backends.Backend do
  @moduledoc """
  Behaviour for LLM backends.
  """

  @type config :: map()
  @type message :: %{role: String.t(), content: String.t()}
  @type options :: keyword()

  @callback complete(pid, messages :: [message], options) :: {:ok, String.t()} | {:error, term}
  @callback stream(pid, messages :: [message], options) :: {:ok, Enumerable.t()} | {:error, term}
  @callback health_check(pid) :: :ok | {:error, term}

  @doc """
  True when the backend takes structured messages plus a `:tools` option and
  can return `{:ok, {:tool_calls, calls, assistant_message}}` from
  `complete/3`. Backends without it get the JSON-in-text tool protocol.
  """
  @callback native_tools?() :: boolean()

  @optional_callbacks native_tools?: 0
end
