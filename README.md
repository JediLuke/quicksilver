# Quicksilver

🧪 Quicksilver – The Alchemical Agentic Framework for Elixir

Quicksilver is an Elixir-native AI sidekick framework for building intelligent, modular agents powered by local and remote LLMs. Designed for hackers, researchers, and builders, Quicksilver lets you:

⚡ Run interchangeable agents with distinct personalities and goals
🧠 Plug into any LLM backend (e.g. llama.cpp, OpenAI, Together.ai)
🔮 Craft tools and memory systems your agents can use to reason and act
🚀 Harness Elixir’s concurrency to orchestrate many agents at once
🦾 Stay in control — run powerful open models on your own GPU

Whether you're creating an autonomous research assistant, a conversational sidekick, or a multi-agent system, Quicksilver is your spellbook for building agentic intelligence in Elixir.

### Talk to backend directly via Llama.cpp

```
{:ok, backend_pid} = Quicksilver.start_backend()
{:ok, response} = Quicksilver.Backends.LlamaCpp.complete(backend_pid, [%{role: "user", content: "Hello!"}])

IO.puts(response)
```
