defmodule Quicksilver.Backends do
  @moduledoc """
  Resolves which LLM backend Quicksilver uses, from the `:backend` config key.
  """

  # name => {module, registered process name}
  @backends %{
    "llama_cpp" => {Quicksilver.Backends.LlamaCpp, LlamaCpp},
    "openai_compatible" => {Quicksilver.Backends.OpenAICompatible, Quicksilver.Backends.OpenAICompatible}
  }

  @doc """
  Returns `{module, server}` for the configured backend (default `"llama_cpp"`).
  `server` is the registered name to pass to `module.complete/3`.
  """
  @spec configured() :: {module(), atom()}
  def configured do
    name = Application.get_env(:quicksilver, :backend, "llama_cpp") |> to_string()

    case Map.fetch(@backends, name) do
      {:ok, backend} ->
        backend

      :error ->
        raise ArgumentError,
              "unknown backend #{inspect(name)}, expected one of: #{Enum.join(Map.keys(@backends), ", ")}"
    end
  end

  @doc """
  Send messages to the configured backend.
  """
  def complete(messages, options \\ []) do
    {module, server} = configured()
    module.complete(server, messages, options)
  end
end
