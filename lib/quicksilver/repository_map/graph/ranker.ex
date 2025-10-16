defmodule Quicksilver.RepositoryMap.Graph.Ranker do
  @moduledoc """
  PageRank implementation for entity importance scoring.
  Assigns scores to entities based on their position in the call graph.
  """

  @default_damping 0.85
  @default_iterations 100
  @default_tolerance 1.0e-6

  @doc """
  Calculate PageRank scores for all vertices in the graph.

  ## Options
    - `:damping_factor` - PageRank damping factor (default: 0.85)
    - `:max_iterations` - Maximum iterations (default: 100)
    - `:tolerance` - Convergence tolerance (default: 1.0e-6)
  """
  @spec calculate_ranks(Graph.t(), keyword()) :: map()
  def calculate_ranks(graph, opts \\ []) do
    damping = Keyword.get(opts, :damping_factor, @default_damping)
    max_iterations = Keyword.get(opts, :max_iterations, @default_iterations)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

    vertices = Graph.vertices(graph)
    num_vertices = length(vertices)

    if num_vertices == 0 do
      %{}
    else
      # Initialize scores
      initial_score = 1.0 / num_vertices
      scores = Map.new(vertices, fn v -> {v, initial_score} end)

      # Iterate until convergence
      final_scores =
        1..max_iterations
        |> Enum.reduce_while(scores, fn _iteration, prev_scores ->
          new_scores = calculate_iteration(graph, prev_scores, damping, num_vertices)

          if converged?(prev_scores, new_scores, tolerance) do
            {:halt, new_scores}
          else
            {:cont, new_scores}
          end
        end)

      # Apply weights based on entity type and location
      final_scores
      |> apply_type_weights(graph)
      |> apply_location_weights(graph)
      |> normalize_scores()
    end
  end

  defp calculate_iteration(graph, scores, damping, num_vertices) do
    Map.new(Graph.vertices(graph), fn vertex ->
      # Get incoming edges
      incoming = Graph.in_edges(graph, vertex)

      rank =
        incoming
        |> Enum.map(fn %{v1: source} ->
          out_degree = Graph.out_degree(graph, source)

          if out_degree > 0 do
            scores[source] / out_degree
          else
            0
          end
        end)
        |> Enum.sum()

      new_score = (1 - damping) / num_vertices + damping * rank
      {vertex, new_score}
    end)
  end

  defp converged?(old_scores, new_scores, tolerance) do
    old_scores
    |> Enum.all?(fn {vertex, old_score} ->
      new_score = new_scores[vertex]
      abs(new_score - old_score) < tolerance
    end)
  end

  defp apply_type_weights(scores, graph) do
    type_weights = %{
      module: 2.0,
      protocol: 1.8,
      impl: 1.6,
      struct: 1.5,
      function: 1.2,
      macro: 1.3
    }

    Map.new(scores, fn {vertex, score} ->
      weight =
        case Graph.vertex_labels(graph, vertex) do
          [entity | _] ->
            base_weight = Map.get(type_weights, entity.type, 1.0)

            # Adjust for visibility (private functions are less important)
            if entity.type in [:function, :macro] do
              case entity.metadata[:visibility] do
                :private -> base_weight * 0.8
                _ -> base_weight
              end
            else
              base_weight
            end

          _ ->
            1.0
        end

      {vertex, score * weight}
    end)
  end

  defp apply_location_weights(scores, graph) do
    # Patterns for important files (higher weight)
    important_patterns = [
      ~r/lib\/quicksilver\.ex$/,
      ~r/lib\/quicksilver\/application\.ex$/,
      ~r/lib\/.*\/supervisor\.ex$/,
      ~r/lib\/.*_web\/router\.ex$/,
      ~r/lib\/.*_web\/endpoint\.ex$/,
      ~r/lib\/.*\/core\//
    ]

    # Patterns for less important files (lower weight)
    unimportant_patterns = [
      ~r/test\//,
      ~r/deps\//,
      ~r/_build\//
    ]

    Map.new(scores, fn {vertex, score} ->
      weight =
        case Graph.vertex_labels(graph, vertex) do
          [entity | _] ->
            cond do
              Enum.any?(important_patterns, &Regex.match?(&1, entity.file_path)) ->
                1.8

              Enum.any?(unimportant_patterns, &Regex.match?(&1, entity.file_path)) ->
                0.5

              true ->
                1.0
            end

          _ ->
            1.0
        end

      # Penalize deep nesting
      depth =
        case Graph.vertex_labels(graph, vertex) do
          [entity | _] ->
            entity.file_path |> String.split("/") |> length()

          _ ->
            2
        end

      depth_penalty = :math.pow(0.95, max(depth - 2, 0))

      {vertex, score * weight * depth_penalty}
    end)
  end

  defp normalize_scores(scores) when map_size(scores) == 0, do: %{}

  defp normalize_scores(scores) do
    values = Map.values(scores)
    min_score = Enum.min(values)
    max_score = Enum.max(values)

    case {min_score, max_score} do
      {min, max} when min == max ->
        # All scores are the same, normalize to 0.5
        Map.new(scores, fn {k, _v} -> {k, 0.5} end)

      {min, max} ->
        # Min-max normalization to [0, 1]
        Map.new(scores, fn {k, v} ->
          normalized = (v - min) / (max - min)
          {k, normalized}
        end)
    end
  end
end
