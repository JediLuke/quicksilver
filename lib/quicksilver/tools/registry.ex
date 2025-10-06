defmodule Quicksilver.Tools.Registry do
  @moduledoc """
  GenServer that maintains a registry of available tools and handles tool execution.

  The registry allows dynamic registration of tools and provides a centralized
  point for tool discovery and execution.
  """

  use GenServer
  require Logger

  @type tool_info :: %{
          name: String.t(),
          description: String.t(),
          parameters_schema: map()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @doc """
  Register a tool module that implements the Tools.Behaviour.

  Returns {:ok, tool_name} on success or {:error, reason} if the module
  doesn't implement the required behaviour.
  """
  @spec register(module()) :: {:ok, String.t()} | {:error, String.t()}
  def register(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end

  @doc """
  List all registered tools with their metadata.

  Returns a list of maps containing name, description, and parameters_schema.
  """
  @spec list_tools() :: [tool_info()]
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Execute a tool by name with the given arguments and context.

  Returns {:ok, result} on success or {:error, reason} on failure.
  """
  @spec execute_tool(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_tool(tool_name, args, context \\ %{}) do
    GenServer.call(__MODULE__, {:execute, tool_name, args, context}, 30_000)
  end

  @doc """
  Get a specific tool's information by name.
  """
  @spec get_tool(String.t()) :: {:ok, tool_info()} | {:error, :not_found}
  def get_tool(tool_name) do
    GenServer.call(__MODULE__, {:get_tool, tool_name})
  end

  ## Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{tools: %{}}}
  end

  @impl true
  def handle_call({:register, tool_module}, _from, state) do
    # Verify the module implements the behaviour
    if implements_behaviour?(tool_module) do
      tool_name = tool_module.name()

      tool_info = %{
        module: tool_module,
        name: tool_name,
        description: tool_module.description(),
        parameters_schema: tool_module.parameters_schema()
      }

      new_state = put_in(state, [:tools, tool_name], tool_info)
      Logger.info("Registered tool: #{tool_name}")
      {:reply, {:ok, tool_name}, new_state}
    else
      {:reply, {:error, "Module does not implement Quicksilver.Tools.Behaviour"}, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools =
      state.tools
      |> Enum.map(fn {_name, info} ->
        %{
          name: info.name,
          description: info.description,
          parameters_schema: info.parameters_schema
        }
      end)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:get_tool, tool_name}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      tool_info ->
        {:reply, {:ok, tool_info}, state}
    end
  end

  @impl true
  def handle_call({:execute, tool_name, args, context}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil ->
        {:reply, {:error, "Tool '#{tool_name}' not found"}, state}

      tool_info ->
        Logger.debug("Executing tool: #{tool_name} with args: #{inspect(args)}")

        result =
          try do
            tool_info.module.execute(args, context)
          rescue
            e ->
              Logger.error("Tool execution error: #{inspect(e)}")
              {:error, "Tool execution failed: #{Exception.message(e)}"}
          end

        Logger.debug("Tool result: #{inspect(result)}")
        {:reply, result, state}
    end
  end

  ## Private Functions

  defp implements_behaviour?(module) do
    # Check if module exports the required callbacks
    behaviours = module.module_info(:attributes)[:behaviour] || []
    Quicksilver.Tools.Behaviour in behaviours
  rescue
    _e -> false
  end
end
