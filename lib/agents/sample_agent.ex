defmodule Quicksilver.Agents.SampleAgent do
  @moduledoc """
  A simple "Hello World" agent that demonstrates basic LLM interaction loop
  """
  use GenServer
  require Logger

  defstruct [:name, :conversation_history, :loop_interval, :questions_asked]

  @trivia_questions [
    "What is the capital of France?",
    "Who wrote Romeo and Juliet?",
    "What is the largest planet in our solar system?",
    "What year did World War II end?",
    "What is the speed of light in meters per second?",
    "Who painted the Mona Lisa?",
    "What is the chemical symbol for gold?",
    "How many continents are there on Earth?"
  ]

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
      loop_interval: config[:loop_interval] || 10_000,
      questions_asked: 0
    }

    Logger.info("🤖 Agent '#{state.name}' starting up...")

    # Kick off the first interaction after a brief delay
    Process.send_after(self(), :think, 2_000)

    {:ok, state}
  end

  @impl true
  def handle_info(:think, state) do
    # Pick a random trivia question
    question = Enum.random(@trivia_questions)

    Logger.info("💭 Agent '#{state.name}' pondering: #{question}")

    # Build messages for the LLM
    messages = [
      %{
        role: "system",
        content: "You are #{state.name}, a knowledgeable AI assistant. Answer questions concisely and accurately."
      },
      %{
        role: "user",
        content: question
      }
    ]

    # Call the LLM backend
    case Quicksilver.Backends.LlamaCpp.complete(LlamaCpp, messages) do
      {:ok, response} ->
        # Clean up the response
        answer = String.trim(response)

        Logger.info("🧠 Agent '#{state.name}' answers: #{answer}")

        new_state = %{state | questions_asked: state.questions_asked + 1}

        # Schedule next thought
        Process.send_after(self(), :think, new_state.loop_interval)

        {:noreply, new_state}

      {:error, :not_ready} ->
        Logger.warning("⏸️  Agent '#{state.name}': Backend not ready yet, retrying in 5s...")
        Process.send_after(self(), :think, 5_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("❌ Agent '#{state.name}' failed to get response: #{inspect(reason)}")

        # Retry after interval with exponential backoff (max 30s)
        retry_delay = min(state.loop_interval * 2, 30_000)
        Logger.info("🔄 Retrying in #{div(retry_delay, 1000)}s...")

        Process.send_after(self(), :think, retry_delay)
        {:noreply, state}
    end
  end

  @doc """
  Ask the agent a specific question (interrupts the trivia loop)
  """
  def ask(agent_name, question) do
    GenServer.cast(via_tuple(agent_name), {:ask, question})
  end

  @doc """
  Get agent stats
  """
  def stats(agent_name) do
    GenServer.call(via_tuple(agent_name), :stats)
  end

  @impl true
  def handle_cast({:ask, question}, state) do
    Logger.info("📨 Agent '#{state.name}' received question: #{question}")

    # Build messages for the LLM
    messages = [
      %{
        role: "system",
        content: "You are #{state.name}, a knowledgeable AI assistant. Answer questions concisely and accurately."
      },
      %{
        role: "user",
        content: question
      }
    ]

    # Answer immediately
    case Quicksilver.Backends.LlamaCpp.complete(LlamaCpp, messages) do
      {:ok, response} ->
        answer = String.trim(response)
        Logger.info("🧠 Agent '#{state.name}' responds: #{answer}")

      {:error, reason} ->
        Logger.error("❌ Agent '#{state.name}' failed to answer: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      questions_asked: state.questions_asked,
      loop_interval: state.loop_interval
    }
    {:reply, stats, state}
  end

  defp via_tuple(name) do
    {:via, Registry, {Quicksilver.AgentRegistry, name}}
  end
end
