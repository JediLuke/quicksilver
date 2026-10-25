defmodule Quicksilver.SessionReaper do
  @moduledoc """
  Makes sure headless `claude` processes spawned by Quicksilver don't outlive
  the Elixir process that started them.

  `ClaudeCli` registers each CLI process together with the process that owns
  it (the one reading its output). If the owner exits without deregistering -
  e.g. its task was killed by a per-iteration timeout - the reaper kills the
  CLI process. Anything still registered is killed when the reaper shuts down.

  Only registered processes are ever touched, so other Claude Code sessions on
  the machine (IDE, desktop app, other scripts) are left alone.
  """

  use GenServer
  require Logger

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Track `os_pid`, killing it if `owner` exits before `deregister/1`.
  """
  def register(os_pid, owner \\ self()) when is_integer(os_pid) and is_pid(owner) do
    GenServer.cast(__MODULE__, {:register, os_pid, owner})
  end

  @doc """
  Stop tracking `os_pid` (it exited normally).
  """
  def deregister(os_pid) when is_integer(os_pid) do
    GenServer.cast(__MODULE__, {:deregister, os_pid})
  end

  @doc """
  Stop tracking `os_pid` and kill it now (timeouts, user aborts).
  """
  def kill(os_pid) when is_integer(os_pid) do
    GenServer.cast(__MODULE__, {:kill, os_pid})
  end

  def list_active do
    GenServer.call(__MODULE__, :list_active)
  end

  # --- Callbacks ---

  @impl true
  def init(:ok) do
    # So terminate/2 runs on shutdown and kills what's left
    Process.flag(:trap_exit, true)
    {:ok, %{active: %{}}}
  end

  @impl true
  def handle_cast({:register, os_pid, owner}, state) do
    Logger.debug("SessionReaper: registered PID #{os_pid}")
    ref = Process.monitor(owner)
    {:noreply, put_in(state, [:active, os_pid], ref)}
  end

  def handle_cast({:deregister, os_pid}, state) do
    Logger.debug("SessionReaper: deregistered PID #{os_pid}")
    {:noreply, untrack(state, os_pid)}
  end

  def handle_cast({:kill, os_pid}, state) do
    kill_os_process(os_pid)
    {:noreply, untrack(state, os_pid)}
  end

  @impl true
  def handle_call(:list_active, _from, state) do
    {:reply, state.active |> Map.keys() |> MapSet.new(), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, state) do
    case Enum.find(state.active, fn {_os_pid, r} -> r == ref end) do
      {os_pid, _ref} ->
        Logger.warning("SessionReaper: owner of claude PID #{os_pid} exited, killing it")
        kill_os_process(os_pid)
        {:noreply, %{state | active: Map.delete(state.active, os_pid)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.active |> Map.keys() |> Enum.each(&kill_os_process/1)
  end

  # --- Internals ---

  defp untrack(state, os_pid) do
    case Map.pop(state.active, os_pid) do
      {nil, _} ->
        state

      {ref, active} ->
        Process.demonitor(ref, [:flush])
        %{state | active: active}
    end
  end

  defp kill_os_process(os_pid) do
    case System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> :ok
      # Already gone
      {_, _} -> :ok
    end
  end
end
