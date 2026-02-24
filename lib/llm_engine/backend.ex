defmodule Quicksilver.LlmEngine.Backend do
  @moduledoc """
  Behaviour for LLM backends.

  Backends implement `complete/2` for stateless completions.
  Stateful backends (like Claude CLI with session tracking) additionally
  implement `complete_with_state/3`.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type options :: keyword()

  @callback complete(messages :: [message], options) :: {:ok, String.t()} | {:error, term}
  @callback health_check(options) :: :ok | {:error, term}

  @doc """
  Optional callback for backends that need to track state across calls
  (e.g., Claude CLI session_id). Returns updated state along with response.
  """
  @callback complete_with_state(messages :: [message], state :: map(), options) ::
              {:ok, String.t(), map()} | {:error, term}

  @optional_callbacks [complete_with_state: 3]
end
