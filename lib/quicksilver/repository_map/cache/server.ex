defmodule Quicksilver.RepositoryMap.Cache.Server do
  @moduledoc """
  GenServer for caching repository maps with ETS backend.
  Provides fast concurrent reads and automatic invalidation.
  """
  use GenServer
  require Logger

  @table_name :repository_map_cache
  @ttl_ms :timer.hours(24)

  # Client API

  @doc """
  Start the cache server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached repository map.
  Returns nil if not found or expired.
  """
  @spec get(String.t()) :: map() | nil
  def get(repo_path) do
    case :ets.lookup(@table_name, repo_path) do
      [{^repo_path, map, timestamp}] ->
        if expired?(timestamp) do
          :ets.delete(@table_name, repo_path)
          nil
        else
          map
        end

      [] ->
        nil
    end
  end

  @doc """
  Put a repository map in the cache.
  """
  @spec put(String.t(), map()) :: :ok
  def put(repo_path, map) do
    GenServer.cast(__MODULE__, {:put, repo_path, map})
  end

  @doc """
  Invalidate a cached repository map.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(repo_path) do
    GenServer.cast(__MODULE__, {:invalidate, repo_path})
  end

  @doc """
  Clear all cached maps.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # Create ETS table with concurrent read optimization
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Start cleanup timer
    schedule_cleanup()

    state = %{
      ttl: Keyword.get(opts, :ttl, @ttl_ms),
      max_size: Keyword.get(opts, :max_size, 100),
      hits: 0,
      misses: 0
    }

    Logger.info("Repository map cache started")

    {:ok, state}
  end

  @impl true
  def handle_cast({:put, repo_path, map}, state) do
    timestamp = System.monotonic_time(:millisecond)

    # Check size limit
    state =
      if :ets.info(@table_name, :size) >= state.max_size do
        evict_oldest()
        state
      else
        state
      end

    :ets.insert(@table_name, {repo_path, map, timestamp})

    Logger.debug("Cached repository map for #{repo_path}")

    {:noreply, state}
  end

  @impl true
  def handle_cast({:invalidate, repo_path}, state) do
    :ets.delete(@table_name, repo_path)
    Logger.debug("Invalidated cache for #{repo_path}")

    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("Cleared all cached repository maps")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      size: :ets.info(@table_name, :size),
      memory: :ets.info(@table_name, :memory),
      hits: state.hits,
      misses: state.misses
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp expired?(timestamp) do
    age = System.monotonic_time(:millisecond) - timestamp
    age > @ttl_ms
  end

  defp cleanup_expired do
    current_time = System.monotonic_time(:millisecond)

    deleted =
      :ets.select_delete(@table_name, [
        {
          {:"$1", :"$2", :"$3"},
          [{:<, :"$3", current_time - @ttl_ms}],
          [true]
        }
      ])

    if deleted > 0 do
      Logger.debug("Cleaned up #{deleted} expired cache entries")
    end
  end

  defp evict_oldest do
    # Find the oldest entry and delete it
    case :ets.match(@table_name, {:"$1", :_, :"$2"}) do
      [] ->
        :ok

      entries ->
        [{repo_path, _timestamp} | _] = Enum.sort_by(entries, &List.last/1)
        :ets.delete(@table_name, repo_path)
        Logger.debug("Evicted oldest cache entry: #{repo_path}")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(15))
  end
end
