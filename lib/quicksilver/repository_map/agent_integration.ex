defmodule Quicksilver.RepositoryMap.AgentIntegration do
  @moduledoc """
  High-level API for integrating repository maps with coding agents.
  Manages repository map lifecycle and provides context generation.
  """
  use GenServer
  require Logger

  alias Quicksilver.RepositoryMap.{Parser, Graph, Cache, Formatter}

  defstruct [:repo_path, :map, :graph, :scores, :last_updated]

  # Client API

  @doc """
  Start an agent integration process for a repository.
  """
  def start_link(repo_path, opts \\ []) do
    GenServer.start_link(__MODULE__, {repo_path, opts})
  end

  @doc """
  Get context for a specific task description.
  Extracts keywords and finds relevant entities.
  """
  @spec get_context(pid(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_context(pid, task_description, opts \\ []) do
    GenServer.call(pid, {:get_context, task_description, opts}, :timer.seconds(30))
  end

  @doc """
  Find entities matching a pattern.
  """
  @spec find_entities(pid(), String.t()) :: {:ok, list(Entity.t())} | {:error, term()}
  def find_entities(pid, pattern) do
    GenServer.call(pid, {:find_entities, pattern})
  end

  @doc """
  Get related entities (neighbors in the call graph).
  """
  @spec get_related(pid(), String.t(), integer()) :: {:ok, list({String.t(), integer()})} | {:error, term()}
  def get_related(pid, entity_id, depth \\ 1) do
    GenServer.call(pid, {:get_related, entity_id, depth})
  end

  @doc """
  Refresh the repository map (re-parse the codebase).
  """
  @spec refresh(pid()) :: :ok
  def refresh(pid) do
    GenServer.cast(pid, :refresh)
  end

  @doc """
  Get the repository map for a given path.
  Uses cache if available, otherwise generates it.
  """
  @spec get_or_generate(String.t()) :: {:ok, map()} | {:error, term()}
  def get_or_generate(repo_path) do
    case Cache.Server.get(repo_path) do
      nil ->
        Logger.info("Generating repository map for #{repo_path}")
        generate_map(repo_path)

      cached_map ->
        Logger.debug("Using cached repository map for #{repo_path}")
        {:ok, cached_map}
    end
  end

  # Server Callbacks

  @impl true
  def init({repo_path, _opts}) do
    # Try to load from cache first
    state = %__MODULE__{
      repo_path: repo_path,
      last_updated: nil
    }

    case Cache.Server.get(repo_path) do
      nil ->
        {:ok, state, {:continue, :generate_map}}

      cached_map ->
        state = %{
          state
          | map: cached_map.map,
            graph: cached_map.graph,
            scores: cached_map.scores,
            last_updated: cached_map.timestamp
        }

        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:generate_map, state) do
    new_state = do_generate_map(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_context, task_description, opts}, _from, state) do
    context = build_task_context(task_description, state, opts)
    {:reply, {:ok, context}, state}
  end

  @impl true
  def handle_call({:find_entities, pattern}, _from, state) do
    matches = find_matching_entities(pattern, state.map.entities)
    {:reply, {:ok, matches}, state}
  end

  @impl true
  def handle_call({:get_related, entity_id, depth}, _from, state) do
    related = get_related_entities(entity_id, depth, state.graph)
    {:reply, {:ok, related}, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = do_generate_map(state)
    {:noreply, new_state}
  end

  # Private Functions

  defp do_generate_map(state) do
    Logger.info("Generating repository map for #{state.repo_path}")

    case generate_map(state.repo_path) do
      {:ok, map_data} ->
        %{
          state
          | map: map_data.map,
            graph: map_data.graph,
            scores: map_data.scores,
            last_updated: map_data.timestamp
        }

      {:error, reason} ->
        Logger.error("Failed to generate repository map: #{inspect(reason)}")
        state
    end
  end

  defp generate_map(repo_path) do
    with {:ok, parse_result} <- Parser.RepositoryParser.parse(repo_path),
         graph <- Graph.Builder.build(parse_result.entities),
         scores <- Graph.Ranker.calculate_ranks(graph) do
      map_data = %{
        map: parse_result,
        graph: graph,
        scores: scores,
        timestamp: DateTime.utc_now()
      }

      # Cache the result
      Cache.Server.put(repo_path, map_data)

      {:ok, map_data}
    end
  end

  defp build_task_context(task_description, state, opts) do
    # Extract keywords from task description
    keywords = extract_keywords(task_description)

    # Find relevant entities based on keywords and scores
    relevant_entities = find_relevant_entities(keywords, state)

    # Get relevant files
    relevant_files =
      relevant_entities
      |> Enum.map(& &1.file_path)
      |> Enum.uniq()
      |> Enum.take(20)

    # Build focused map for formatting
    focused_map = %{
      entities: Map.new(relevant_entities, fn e -> {e.id, e} end),
      files: relevant_files,
      stats: state.map.stats,
      scores: state.scores
    }

    # Format for LLM
    token_limit = Keyword.get(opts, :token_limit, 4000)

    Formatter.LLM.format(focused_map,
      token_limit: token_limit,
      focus_keywords: keywords
    )
  end

  defp extract_keywords(text) do
    stop_words = ~w(the and for with from into about need want fix change update modify add remove delete)

    text
    |> String.downcase()
    |> String.split(~r/\W+/)
    |> Enum.filter(fn word ->
      String.length(word) > 2 and word not in stop_words
    end)
    |> Enum.uniq()
  end

  defp find_relevant_entities(keywords, state) do
    state.map.entities
    |> Map.values()
    |> Enum.map(fn entity ->
      relevance_score = calculate_relevance_score(entity, keywords, state.scores[entity.id] || 0)
      {entity, relevance_score}
    end)
    |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
    |> Enum.take(30)
    |> Enum.map(fn {entity, _score} -> entity end)
  end

  defp calculate_relevance_score(entity, keywords, base_score) do
    keyword_score =
      Enum.reduce(keywords, 0.0, fn keyword, acc ->
        score = 0.0

        score = if String.contains?(String.downcase(entity.name), keyword), do: score + 2.0, else: score

        score = if entity.signature && String.contains?(String.downcase(entity.signature), keyword),
          do: score + 1.5,
          else: score

        score = if entity.doc && String.contains?(String.downcase(entity.doc), keyword),
          do: score + 1.0,
          else: score

        score = if String.contains?(String.downcase(entity.file_path), keyword),
          do: score + 0.5,
          else: score

        acc + score
      end)

    # Combine keyword relevance with PageRank score
    keyword_score * (1.0 + base_score)
  end

  defp find_matching_entities(pattern, entities) do
    regex =
      case Regex.compile(pattern, "i") do
        {:ok, r} -> r
        _ -> ~r/#{Regex.escape(pattern)}/i
      end

    entities
    |> Map.values()
    |> Enum.filter(fn entity ->
      Regex.match?(regex, entity.name) or
        (entity.signature && Regex.match?(regex, entity.signature))
    end)
    |> Enum.take(20)
  end

  defp get_related_entities(entity_id, depth, graph) do
    # BFS to find related entities
    visited = MapSet.new([entity_id])
    queue = :queue.in({entity_id, 0}, :queue.new())

    collect_related(queue, visited, graph, depth, [])
  end

  defp collect_related(queue, visited, graph, max_depth, acc) do
    case :queue.out(queue) do
      {{:value, {vertex, depth}}, rest_queue} when depth < max_depth ->
        # Get neighbors (both incoming and outgoing)
        neighbors =
          (Graph.out_neighbors(graph, vertex) ++ Graph.in_neighbors(graph, vertex))
          |> Enum.uniq()

        # Filter unvisited
        unvisited = Enum.reject(neighbors, &MapSet.member?(visited, &1))

        # Add to queue
        new_queue =
          Enum.reduce(unvisited, rest_queue, fn neighbor, q ->
            :queue.in({neighbor, depth + 1}, q)
          end)

        # Update visited
        new_visited =
          Enum.reduce(unvisited, visited, fn neighbor, v ->
            MapSet.put(v, neighbor)
          end)

        # Add to results
        new_acc = [{vertex, depth} | acc]

        collect_related(new_queue, new_visited, graph, max_depth, new_acc)

      {{:value, {vertex, depth}}, rest_queue} ->
        # Max depth reached, just add to results
        collect_related(rest_queue, visited, graph, max_depth, [{vertex, depth} | acc])

      {:empty, _} ->
        Enum.reverse(acc)
    end
  end
end
