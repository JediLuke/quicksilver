defmodule Quicksilver.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Quicksilver.Tools.Registry

  defmodule WhoAmITool do
    @behaviour Quicksilver.Tools.Behaviour
    def name, do: "test_who_am_i"
    def description, do: "Reports the process it runs in"
    def parameters_schema, do: %{"type" => "object", "properties" => %{}}

    def execute(_args, %{test_pid: test_pid}) do
      send(test_pid, {:ran_in, self()})
      {:ok, "done"}
    end
  end

  # Stands in for a tool waiting on the user at an approval prompt
  defmodule BlockingTool do
    @behaviour Quicksilver.Tools.Behaviour
    def name, do: "test_blocking"
    def description, do: "Blocks until released"
    def parameters_schema, do: %{"type" => "object", "properties" => %{}}

    def execute(_args, %{test_pid: test_pid}) do
      send(test_pid, {:blocked, self()})

      receive do
        :release -> {:ok, "released"}
      end
    end
  end

  defmodule RaisingTool do
    @behaviour Quicksilver.Tools.Behaviour
    def name, do: "test_raising"
    def description, do: "Always raises"
    def parameters_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _context), do: raise("boom")
  end

  setup_all do
    for tool <- [WhoAmITool, BlockingTool, RaisingTool], do: {:ok, _} = Registry.register(tool)
    :ok
  end

  test "runs tools in the caller's process, not the registry's" do
    assert {:ok, "done"} = Registry.execute_tool("test_who_am_i", %{}, %{test_pid: self()})

    test_pid = self()
    assert_received {:ran_in, ^test_pid}
  end

  test "registry stays responsive while a tool is blocked" do
    test_pid = self()
    task = Task.async(fn -> Registry.execute_tool("test_blocking", %{}, %{test_pid: test_pid}) end)
    assert_receive {:blocked, tool_pid}

    assert {:ok, %{name: "test_who_am_i"}} = Registry.get_tool("test_who_am_i")

    send(tool_pid, :release)
    assert {:ok, "released"} = Task.await(task)
  end

  test "turns exceptions into tool errors" do
    assert {:error, "Tool execution failed: boom"} = Registry.execute_tool("test_raising", %{}, %{})
  end

  test "errors on unknown tools" do
    assert {:error, "Tool 'no_such_tool' not found"} = Registry.execute_tool("no_such_tool", %{}, %{})
  end
end
