#!/bin/bash

claude --settings '{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/bighead/scripts/hooks/hook.py"
          }
        ]
      }
    ]
  }
}'
