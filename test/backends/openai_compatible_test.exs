defmodule Quicksilver.Backends.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Quicksilver.Backends.OpenAICompatible
  alias Quicksilver.Tools.Formatter

  @tools [
    %{
      name: "read_file",
      description: "Read a file",
      parameters_schema: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}
    }
  ]

  describe "Formatter.to_openai_tools/1" do
    test "wraps tool info in OpenAI function format" do
      assert [
               %{
                 type: "function",
                 function: %{name: "read_file", description: "Read a file", parameters: %{type: "object"}}
               }
             ] = Formatter.to_openai_tools(@tools)
    end
  end

  describe "build_chat_payload/3" do
    test "includes model, messages and tools" do
      messages = [%{role: "user", content: "hi"}]
      payload = OpenAICompatible.build_chat_payload(%{model: "gpt-oss-120b"}, messages, tools: @tools)

      assert payload.model == "gpt-oss-120b"
      assert payload.messages == messages
      assert [%{type: "function"}] = payload.tools
      assert payload.max_tokens == 4096
    end

    test "omits tools when none are given" do
      payload = OpenAICompatible.build_chat_payload(%{}, [%{role: "user", content: "hi"}], [])
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :model)
    end

    test "leaves sampling to the server unless configured" do
      payload = OpenAICompatible.build_chat_payload(%{}, [], [])
      refute Map.has_key?(payload, :temperature)
      refute Map.has_key?(payload, :top_p)

      assert OpenAICompatible.build_chat_payload(%{temperature: 0.2}, [], []).temperature == 0.2
    end

    test "options override config defaults" do
      payload = OpenAICompatible.build_chat_payload(%{max_tokens: 1000}, [], max_tokens: 50, temperature: 0.1)
      assert payload.max_tokens == 50
      assert payload.temperature == 0.1
    end

    test "strips reasoning from history unless send_reasoning is set" do
      messages = [%{role: "assistant", content: "", reasoning_content: "hmm", tool_calls: []}]

      assert [message] = OpenAICompatible.build_chat_payload(%{}, messages, []).messages
      refute Map.has_key?(message, :reasoning_content)

      assert OpenAICompatible.build_chat_payload(%{send_reasoning: true}, messages, []).messages == messages
    end
  end

  describe "chat/3" do
    # Fake Req adapter: reports the outgoing request, replies with `response`
    defp respond_with(response) do
      test_pid = self()

      [
        adapter: fn request ->
          send(test_pid, {:request, request})
          {request, response}
        end
      ]
    end

    defp answer(text) do
      Req.Response.json(%{"choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]})
    end

    test "posts the payload to base_url/chat/completions with a bearer key from the env" do
      System.put_env("QS_TEST_KEY_POST", "sk-test")
      config = %{base_url: "https://api.example.com/v1/", api_key_env: "QS_TEST_KEY_POST", model: "m"}

      assert {:ok, "hello"} =
               OpenAICompatible.chat(config, [%{role: "user", content: "hi"}],
                 tools: @tools,
                 req_options: respond_with(answer("hello"))
               )

      assert_received {:request, request}
      assert URI.to_string(request.url) == "https://api.example.com/v1/chat/completions"
      assert Req.Request.get_header(request, "authorization") == ["Bearer sk-test"]

      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["model"] == "m"
      assert [%{"role" => "user", "content" => "hi"}] = body["messages"]
      assert [%{"function" => %{"name" => "read_file"}}] = body["tools"]
    end

    test "sends no auth header when api_key_env is nil" do
      config = %{base_url: "http://127.0.0.1:8000/v1", api_key_env: nil}
      assert {:ok, "hi"} = OpenAICompatible.chat(config, [], req_options: respond_with(answer("hi")))

      assert_received {:request, request}
      assert Req.Request.get_header(request, "authorization") == []
    end

    test "errors without sending when the API key env var is unset" do
      config = %{base_url: "https://api.example.com/v1", api_key_env: "QS_TEST_KEY_UNSET"}

      assert {:error, {:missing_api_key, "QS_TEST_KEY_UNSET"}} =
               OpenAICompatible.chat(config, [], req_options: respond_with(answer("hi")))

      refute_received {:request, _}
    end

    test "returns the status and body of non-200 replies" do
      config = %{base_url: "https://api.example.com/v1", api_key_env: nil}
      denied = Req.Response.json(%Req.Response{status: 401}, %{"error" => %{"message" => "bad key"}})

      assert {:error, {:http_status, 401, %{"error" => %{"message" => "bad key"}}}} =
               OpenAICompatible.chat(config, [], req_options: respond_with(denied))
    end
  end

  describe "parse_chat_response/1" do
    test "returns plain content for a text answer" do
      body = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "quicksilver"}}]}
      assert {:ok, "quicksilver"} = OpenAICompatible.parse_chat_response(body)
    end

    test "returns tool calls with decoded arguments and the message to echo back" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "reasoning_content" => "need to read it",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => "{\n \"path\": \"mix.exs\"\n}"}
                }
              ]
            }
          }
        ]
      }

      assert {:ok, {:tool_calls, [call], message}} = OpenAICompatible.parse_chat_response(body)
      assert call == %{id: "call_1", name: "read_file", arguments: {:ok, %{"path" => "mix.exs"}}}
      assert message.role == "assistant"
      assert message.reasoning_content == "need to read it"
      assert [%{"id" => "call_1"}] = message.tool_calls
    end

    test "flags malformed tool arguments instead of raising" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [%{"id" => "c", "function" => %{"name" => "read_file", "arguments" => "{oops"}}]
            }
          }
        ]
      }

      assert {:ok, {:tool_calls, [%{arguments: {:error, _}}], _}} = OpenAICompatible.parse_chat_response(body)
    end

    test "errors on an empty answer (e.g. token budget spent on reasoning)" do
      body = %{"choices" => [%{"finish_reason" => "length", "message" => %{"content" => ""}}]}
      assert {:error, {:empty_response, "length"}} = OpenAICompatible.parse_chat_response(body)
    end

    test "errors on unexpected bodies" do
      assert {:error, {:unexpected_response, _}} = OpenAICompatible.parse_chat_response(%{"error" => "x"})
    end
  end
end
