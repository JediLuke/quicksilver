#!/usr/bin/env elixir

# Convenience script to start the terminal chat with the coding tools
# Run with: mix run start_chat.exs
# Other backend: QUICKSILVER_BACKEND=claude_cli mix run start_chat.exs

Quicksilver.ContextLib.ElixirCodingAssistant.start()
