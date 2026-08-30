#!/bin/bash

claude --settings '{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/user-prompt-submit.sh 50"
          }
        ]
      }
    ],
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/stop.py"
              }
            ]
          }
        ]
  }
}'