defmodule Quicksilver.LlmEngineTest do
  # Changes application env
  use ExUnit.Case, async: false

  alias Quicksilver.LlmEngine

  setup do
    original = Application.get_env(:quicksilver, :backend)
    on_exit(fn -> Application.put_env(:quicksilver, :backend, original) end)
  end

  describe "default_backend/0" do
    test "resolves names given as strings (env var) or atoms" do
      Application.put_env(:quicksilver, :backend, "openai_compatible")
      assert LlmEngine.default_backend() == :openai_compatible

      Application.put_env(:quicksilver, :backend, :claude_cli)
      assert LlmEngine.default_backend() == :claude_cli
    end

    test "rejects unknown names" do
      Application.put_env(:quicksilver, :backend, "nope")
      assert_raise ArgumentError, ~r/unknown backend "nope"/, fn -> LlmEngine.default_backend() end
    end
  end

  describe "native_tools?/1" do
    test "is true for chat-completions backends and false for the others" do
      assert LlmEngine.native_tools?(:openai_compatible)
      assert LlmEngine.native_tools?(:openai)
      refute LlmEngine.native_tools?(:anthropic)
      refute LlmEngine.native_tools?(:claude_cli)
    end

    test "is false for modules without the callback" do
      refute LlmEngine.native_tools?(String)
    end
  end
end
