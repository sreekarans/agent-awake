def command_hook($action):
  {
    "command": (($binary | @sh) + " hook auto " + $action),
    "timeout": 5
  };

def is_agent_awake_command:
  (. // "") as $command
  | ($command | startswith($binary + " hook "))
    or ($command | startswith(($binary | @sh) + " hook "));

def without_agent_awake:
  map(
    select(
      (.command | is_agent_awake_command)
      | not
    )
  );

.version = 1
| .hooks = (.hooks // {})
| .hooks.beforeSubmitPrompt = (
    ((.hooks.beforeSubmitPrompt // []) | without_agent_awake)
    + [command_hook("start")]
  )
| .hooks.afterAgentThought = (
    ((.hooks.afterAgentThought // []) | without_agent_awake)
    + [command_hook("heartbeat")]
  )
| .hooks.afterAgentResponse = (
    ((.hooks.afterAgentResponse // []) | without_agent_awake)
    + [command_hook("heartbeat")]
  )
| .hooks.postToolUse = (
    ((.hooks.postToolUse // []) | without_agent_awake)
    + [command_hook("heartbeat")]
  )
| .hooks.postToolUseFailure = (
    ((.hooks.postToolUseFailure // []) | without_agent_awake)
    + [command_hook("heartbeat")]
  )
| .hooks.stop = (
    ((.hooks.stop // []) | without_agent_awake)
    + [command_hook("stop")]
  )
| .hooks.sessionEnd = (
    ((.hooks.sessionEnd // []) | without_agent_awake)
    + [command_hook("stop-session")]
  )
