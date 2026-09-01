#!/bin/bash

claude --settings '{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hook.py"
          }
        ]
      }
    ]
  }
}'
