defmodule Quicksilver.BackendsTest do
  # Changes application env
  use ExUnit.Case, async: false

  alias Quicksilver.Backends

  setup do
    original = Application.get_env(:quicksilver, :backend)
    on_exit(fn -> Application.put_env(:quicksilver, :backend, original) end)
  end

  test "resolves backend names given as strings or atoms" do
    Application.put_env(:quicksilver, :backend, "openai_compatible")
    assert {Quicksilver.Backends.OpenAICompatible, _server} = Backends.configured()

    Application.put_env(:quicksilver, :backend, :llama_cpp)
    assert {Quicksilver.Backends.LlamaCpp, LlamaCpp} = Backends.configured()
  end

  test "rejects unknown backends" do
    Application.put_env(:quicksilver, :backend, "nope")
    assert_raise ArgumentError, ~r/unknown backend "nope"/, fn -> Backends.configured() end
  end
end
