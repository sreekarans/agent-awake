def command_group($action):
  {
    "hooks": [
      {
        "type": "command",
        "command": (($binary | @sh) + " hook auto " + $action),
        "timeout": 5
      }
    ]
  };

def is_agent_awake_command:
  (. // "") as $command
  | ($command | startswith($binary + " hook "))
    or ($command | startswith(($binary | @sh) + " hook "));

def without_agent_awake:
  map(
    select(
      any(.hooks[]?; (.command | is_agent_awake_command))
      | not
    )
  );

.hooks = (.hooks // {})
| .hooks.UserPromptSubmit = (
    ((.hooks.UserPromptSubmit // []) | without_agent_awake)
    + [command_group("start")]
  )
| .hooks.PostToolUse = (
    ((.hooks.PostToolUse // []) | without_agent_awake)
    + [command_group("heartbeat")]
  )
| .hooks.PostToolUseFailure = (
    ((.hooks.PostToolUseFailure // []) | without_agent_awake)
    + [command_group("heartbeat")]
  )
| .hooks.Stop = (
    ((.hooks.Stop // []) | without_agent_awake)
    + [command_group("stop")]
  )
| .hooks.StopFailure = (
    ((.hooks.StopFailure // []) | without_agent_awake)
    + [command_group("stop")]
  )
| .hooks.SessionEnd = (
    ((.hooks.SessionEnd // []) | without_agent_awake)
    + [command_group("stop-session")]
  )
