defmodule Quicksilver.SessionReaper do
  @moduledoc """
  Tracks intentionally-spawned headless `claude` processes and periodically
  reaps orphans — headless claude PIDs that aren't in our active set.
  """

  use GenServer
  require Logger

  @reap_interval_ms 60_000

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def register(os_pid) when is_integer(os_pid) do
    GenServer.cast(__MODULE__, {:register, os_pid})
  end

  def deregister(os_pid) when is_integer(os_pid) do
    GenServer.cast(__MODULE__, {:deregister, os_pid})
  end

  def list_active do
    GenServer.call(__MODULE__, :list_active)
  end

  # --- Callbacks ---

  @impl true
  def init(:ok) do
    schedule_reap()
    {:ok, %{active: MapSet.new()}}
  end

  @impl true
  def handle_cast({:register, os_pid}, state) do
    Logger.info("SessionReaper: registered PID #{os_pid}")
    {:noreply, %{state | active: MapSet.put(state.active, os_pid)}}
  end

  def handle_cast({:deregister, os_pid}, state) do
    Logger.info("SessionReaper: deregistered PID #{os_pid}")
    {:noreply, %{state | active: MapSet.delete(state.active, os_pid)}}
  end

  @impl true
  def handle_call(:list_active, _from, state) do
    {:reply, state.active, state}
  end

  @impl true
  def handle_info(:reap, state) do
    new_state = do_reap(state)
    schedule_reap()
    {:noreply, new_state}
  end

  # --- Internals ---

  defp schedule_reap do
    Process.send_after(self(), :reap, @reap_interval_ms)
  end

  defp do_reap(state) do
    headless_pids = find_headless_claude_pids()
    orphans = MapSet.difference(headless_pids, state.active)

    for pid <- orphans do
      pid_str = Integer.to_string(pid)
      Logger.warning("SessionReaper: reaping headless claude orphan PID #{pid_str}")

      case System.cmd("kill", [pid_str], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {err, _} -> Logger.warning("SessionReaper: kill #{pid_str} failed: #{String.trim(err)}")
      end
    end

    # Also prune active set — remove any PIDs that are no longer alive
    still_alive =
      MapSet.filter(state.active, fn pid ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
      end)

    %{state | active: still_alive}
  end

  defp find_headless_claude_pids do
    case System.cmd("ps", ["-eo", "pid,tty,comm"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.reduce(MapSet.new(), fn line, acc ->
          case parse_ps_line(line) do
            {:ok, pid} -> MapSet.put(acc, pid)
            :skip -> acc
          end
        end)

      {err, _} ->
        Logger.warning("SessionReaper: ps command failed: #{String.trim(err)}")
        MapSet.new()
    end
  end

  defp parse_ps_line(line) do
    trimmed = String.trim(line)

    case String.split(trimmed, ~r/\s+/, parts: 3) do
      [pid_str, tty, comm] ->
        if tty == "?" and String.contains?(comm, "claude") do
          case Integer.parse(pid_str) do
            {pid, ""} -> {:ok, pid}
            _ -> :skip
          end
        else
          :skip
        end

      _ ->
        :skip
    end
  end
end
