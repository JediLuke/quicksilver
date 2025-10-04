defmodule Quicksilver.Agents.SampleAgent do
  @moduledoc """
  A simple "Hello World" agent that demonstrates basic LLM interaction loop
  """
  use GenServer
  require Logger

  defstruct [:name, :conversation_history, :loop_interval]



  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config[:name]))
  end

  @impl true
  @spec init(nil | maybe_improper_list() | map()) ::
          {:ok, %__MODULE__{}}
  def init(config) do
    state = %__MODULE__{
      name: config[:name],
      conversation_history: [],
      loop_interval: config[:loop_interval] || 5_000
    }

    Logger.info("🤖 Agent '#{state.name}' starting up...")

    # Kick off the first interaction
    send(self(), :think)

    {:ok, state}
  end

  @impl true
  def handle_info(:think, state) do
    Logger.info("💭 Agent '#{state.name}' thinking...")

    # Build messages for the LLM
    # messages = build_messages(state)

    # Call the LLM backend
    # case Quicksilver.Backends.Backend.complete(state.backend_pid, messages) do
    #   {:ok, response} ->
    #     Logger.info("🧠 Agent '#{state.name}' says: #{response}")

    #     # Update conversation history
    #     new_history = state.conversation_history ++ [
    #       %{role: "assistant", content: response}
    #     ]

    #     # Schedule next thought
    #     Process.send_after(self(), :think, state.loop_interval)

    #     {:noreply, %{state | conversation_history: new_history}}

    #   {:error, reason} ->
    #     Logger.error("❌ Agent '#{state.name}' failed to get response: #{inspect(reason)}")

    #     # Retry after interval
    #

    #     {:noreply, state}
    # end

    Process.send_after(self(), :think, state.loop_interval)

    {:noreply, state}
  end

  @doc """
  Send a message to the agent
  """
  def send_message(agent_name, content) do
    GenServer.call(via_tuple(agent_name), {:add_message, content})
  end

  @impl true
  def handle_call({:add_message, content}, _from, state) do
    new_history = state.conversation_history ++ [
      %{role: "user", content: content}
    ]

    Logger.info("📨 Agent '#{state.name}' received message: #{content}")

    # Trigger immediate thinking (for now)
    send(self(), :think)

    {:reply, :ok, %{state | conversation_history: new_history}}
  end

  # defp build_messages(state) do
  #   system_message = %{
  #     role: "system",
  #     content: """
  #     You are #{state.name}, a helpful AI assistant built with Quicksilver.
  #     Keep your responses concise and helpful.
  #     This is a proof of concept - just demonstrate that you're alive and thinking!
  #     """
  #   }

  #   # If no conversation history, start with a greeting prompt
  #   if state.conversation_history == [] do
  #     [
  #       system_message,
  #       %{role: "user", content: "Hello! Please introduce yourself briefly."}
  #     ]
  #   else
  #     [system_message | state.conversation_history]
  #   end
  # end

  defp via_tuple(name) do
    {:via, Registry, {Quicksilver.AgentRegistry, name}}
  end
end
