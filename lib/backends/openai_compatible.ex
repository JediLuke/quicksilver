defmodule Quicksilver.Backends.OpenAICompatible do
  @moduledoc """
  Backend for any server speaking the OpenAI chat completions API with tool
  calling: hosted (OpenRouter, OpenAI, Mistral, Groq, Together, ...) or local
  (vLLM, Ollama, LM Studio, llama.cpp).

  Configured under `:openai_compatible` in `config/config.exs`:

  - `base_url` - API root, e.g. `"https://openrouter.ai/api/v1"`
  - `api_key_env` - name of the env var holding the API key; `nil` for
    servers without auth. The key itself never goes in config.
  - `model` - model name sent with each request
  - `max_tokens`, `temperature`, `top_p` - optional; see `build_chat_payload/3`
  - `send_reasoning` - echo the model's `reasoning_content` back in history.
    Off by default: strict providers reject unknown message fields.

  The process only holds config; requests run in the caller's process, so a
  caller that times out and kills its task also cancels the HTTP request.
  """
  use GenServer
  @behaviour Quicksilver.Backends.Backend
  require Logger

  @default_request_timeout 300_000

  def start_link(_opts \\ []) do
    config = Application.get_env(:quicksilver, :openai_compatible, %{})
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Quicksilver.Backends.Backend
  def complete(server, messages, options \\ []) do
    server
    |> GenServer.call(:config)
    |> chat(messages, options)
  end

  @impl Quicksilver.Backends.Backend
  def stream(_server, _messages, _options), do: {:error, :not_implemented}

  @impl Quicksilver.Backends.Backend
  def health_check(server) do
    config = GenServer.call(server, :config)

    with {:ok, headers} <- auth_headers(config),
         {:ok, %{status: 200}} <- Req.get(url(config, "/models"), headers: headers, retry: false) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Quicksilver.Backends.Backend
  def native_tools?, do: true

  @doc """
  POST a chat completion to `config.base_url` and parse the reply with
  `parse_chat_response/1`.

  Options: everything `build_chat_payload/3` takes, plus `:timeout` (ms) and
  `:req_options` (extra options passed to `Req.post/2`).
  """
  def chat(config, messages, options) do
    timeout = Keyword.get(options, :timeout, @default_request_timeout)

    with {:ok, headers} <- auth_headers(config) do
      req_options =
        [
          json: build_chat_payload(config, messages, options),
          headers: headers,
          receive_timeout: timeout
        ] ++ Keyword.get(options, :req_options, [])

      case Req.post(url(config, "/chat/completions"), req_options) do
        {:ok, %{status: 200, body: body}} -> parse_chat_response(body)
        {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Build the request body for `/chat/completions`.

  Options: `:tools` (list of tool info maps from the registry), `:max_tokens`,
  `:temperature`, `:top_p`.
  """
  def build_chat_payload(config, messages, options) do
    messages =
      if Map.get(config, :send_reasoning, false),
        do: messages,
        else: Enum.map(messages, &Map.delete(&1, :reasoning_content))

    payload = %{
      messages: messages,
      # Reasoning models spend tokens thinking before they answer
      max_tokens: Keyword.get(options, :max_tokens, Map.get(config, :max_tokens, 4096))
    }

    # Sampling params are only sent when set, so the server's per-model
    # defaults (e.g. --temp/--top-p in its launch script) apply otherwise
    payload =
      Enum.reduce([:temperature, :top_p], payload, fn key, acc ->
        maybe_put(acc, key, Keyword.get(options, key, Map.get(config, key)))
      end)

    payload = maybe_put(payload, :model, config[:model])

    case Keyword.get(options, :tools, []) do
      [] -> payload
      tools -> Map.put(payload, :tools, Quicksilver.Tools.Formatter.to_openai_tools(tools))
    end
  end

  @doc """
  Parse a `/chat/completions` response body.

  Returns `{:ok, text}` for a plain answer, or
  `{:ok, {:tool_calls, calls, assistant_message}}` where each call is
  `%{id, name, arguments: {:ok, map} | {:error, reason}}` and
  `assistant_message` must be appended to the history before the tool results.
  """
  def parse_chat_response(%{"choices" => [%{"message" => message} = choice | _]}) do
    case message["tool_calls"] do
      [_ | _] = raw_calls ->
        calls =
          Enum.map(raw_calls, fn call ->
            %{
              id: call["id"],
              name: get_in(call, ["function", "name"]),
              arguments: decode_tool_arguments(get_in(call, ["function", "arguments"]))
            }
          end)

        assistant_message =
          %{role: "assistant", content: message["content"] || "", tool_calls: raw_calls}
          |> maybe_put(:reasoning_content, message["reasoning_content"])

        {:ok, {:tool_calls, calls, assistant_message}}

      _ ->
        case message["content"] do
          content when is_binary(content) and content != "" -> {:ok, content}
          _ -> {:error, {:empty_response, choice["finish_reason"]}}
        end
    end
  end

  def parse_chat_response(body), do: {:error, {:unexpected_response, body}}

  ## Server Callbacks

  @impl GenServer
  def init(config) do
    Logger.info("OpenAI-compatible backend: #{config[:model]} at #{config[:base_url]}")
    {:ok, config}
  end

  @impl GenServer
  def handle_call(:config, _from, config), do: {:reply, config, config}

  ## Private Functions

  defp url(config, path), do: String.trim_trailing(config.base_url, "/") <> path

  defp auth_headers(config) do
    case Map.get(config, :api_key_env) do
      nil ->
        {:ok, []}

      env ->
        case System.get_env(env) do
          key when key in [nil, ""] -> {:error, {:missing_api_key, env}}
          key -> {:ok, [{"authorization", "Bearer " <> key}]}
        end
    end
  end

  defp decode_tool_arguments(args) when is_map(args), do: {:ok, args}
  defp decode_tool_arguments(args) when args in [nil, ""], do: {:ok, %{}}

  defp decode_tool_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, "arguments must be a JSON object, got: #{inspect(other)}"}
      {:error, error} -> {:error, "invalid JSON arguments: #{Exception.message(error)}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
