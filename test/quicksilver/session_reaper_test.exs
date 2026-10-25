defmodule Quicksilver.SessionReaperTest do
  use ExUnit.Case, async: true

  alias Quicksilver.SessionReaper

  # An OS process that outlives its port (sleep ignores closed pipes), owned
  # by a spawned Elixir process that waits until told to exit
  defp start_owned_sleep do
    test_pid = self()

    owner =
      spawn(fn ->
        port = Port.open({:spawn, "sleep 60"}, [:binary])
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(test_pid, {:os_pid, os_pid})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:os_pid, os_pid}
    {owner, os_pid}
  end

  defp alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp eventually_dead?(os_pid, attempts \\ 50) do
    cond do
      not alive?(os_pid) -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually_dead?(os_pid, attempts - 1)
    end
  end

  test "kills a registered process when its owner exits" do
    {owner, os_pid} = start_owned_sleep()
    SessionReaper.register(os_pid, owner)
    assert alive?(os_pid)

    send(owner, :exit)
    assert eventually_dead?(os_pid)
  end

  test "leaves deregistered processes alone" do
    {owner, os_pid} = start_owned_sleep()
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true) end)

    SessionReaper.register(os_pid, owner)
    SessionReaper.deregister(os_pid)
    send(owner, :exit)

    # Let the reaper see the owner exit, if it were still watching it
    Process.sleep(200)
    assert alive?(os_pid)
    refute MapSet.member?(SessionReaper.list_active(), os_pid)
  end

  test "kill/1 stops a process immediately" do
    {owner, os_pid} = start_owned_sleep()
    SessionReaper.register(os_pid, owner)

    SessionReaper.kill(os_pid)
    assert eventually_dead?(os_pid)
    send(owner, :exit)
  end
end
