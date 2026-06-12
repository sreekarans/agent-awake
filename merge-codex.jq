def command_group($action; $timeout):
  {
    "hooks": [
      {
        "type": "command",
        "command": (($binary | @sh) + " hook auto " + $action),
        "timeout": $timeout
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
    + [command_group("start"; 5)]
  )
| .hooks.PostToolUse = (
    ((.hooks.PostToolUse // []) | without_agent_awake)
    + [command_group("heartbeat"; 5)]
  )
| .hooks.Stop = (
    ((.hooks.Stop // []) | without_agent_awake)
    + [command_group("stop"; 5)]
  )
| .hooks.SessionEnd = (
    ((.hooks.SessionEnd // []) | without_agent_awake)
    + [command_group("stop-session"; 3)]
  )
