defmodule Quicksilver.Tools.GetRepositoryContext do
  @moduledoc """
  Tool for getting repository context map based on a task description.
  Uses PageRank-based entity scoring to provide relevant codebase context.
  """
  @behaviour Quicksilver.Tools.Behaviour

  alias Quicksilver.RepositoryMap.AgentIntegration

  @impl true
  def name, do: "get_repository_context"

  @impl true
  def description do
    """
    Get a context map of the repository relevant to a task.

    This tool analyzes the codebase structure and returns the most relevant
    entities (modules, functions, etc.) based on the task description.

    **When to use:**
    - At the start of tasks that involve multiple files or unfamiliar code
    - When you need to understand where functionality is implemented
    - Before refactoring or adding features to existing systems

    **Do NOT use if:**
    - You already know the exact file to read/edit
    - The task is simple and confined to one known location

    The repository map uses PageRank to identify important code entities based on
    call graph analysis and keyword matching.
    """
  end

  @impl true
  def parameters_schema do
    %{
      type: "object",
      properties: %{
        task_description: %{
          type: "string",
          description: "Description of the task you need to perform"
        },
        token_limit: %{
          type: "integer",
          description: "Maximum tokens for the context (default: 4000)",
          default: 4000
        }
      },
      required: ["task_description"]
    }
  end

  @impl true
  def execute(args, context) do
    task_description = Map.get(args, "task_description")
    token_limit = Map.get(args, "token_limit", 4000)
    repo_path = Map.get(context, :workspace_root, File.cwd!())

    if is_nil(task_description) or String.trim(task_description) == "" do
      {:error, "task_description is required"}
    else
      case AgentIntegration.get_or_generate(repo_path) do
        {:ok, _map_data} ->
          # Start an agent integration process
          {:ok, agent_pid} = AgentIntegration.start_link(repo_path)

          case AgentIntegration.get_context(agent_pid, task_description,
                 token_limit: token_limit
               ) do
            {:ok, context_text} ->
              # Stop the agent process
              GenServer.stop(agent_pid)

              {:ok,
               """
               Repository Context for: "#{task_description}"

               #{context_text}

               This context shows the most relevant parts of the codebase for your task.
               Use this information to understand the codebase structure and identify files to read or modify.
               """}

            {:error, reason} ->
              GenServer.stop(agent_pid)
              {:error, "Failed to generate context: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to load or generate repository map: #{inspect(reason)}"}
      end
    end
  end
end
