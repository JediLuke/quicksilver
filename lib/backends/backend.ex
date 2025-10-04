defmodule Quicksilver.Backends.Backend do
  @moduledoc """
  Behaviour for LLM backends
  """

  @type config :: map()
  @type message :: %{role: String.t(), content: String.t()}
  @type options :: keyword()

  @callback start_link(config) :: {:ok, pid} | {:error, term}
  @callback complete(pid, messages :: [message], options) :: {:ok, String.t()} | {:error, term}
  @callback stream(pid, messages :: [message], options) :: {:ok, Enumerable.t()} | {:error, term}
  @callback health_check(pid) :: :ok | {:error, term}
end
