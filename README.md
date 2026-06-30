# Agent Awake

Agent Awake keeps a Mac awake while a local desktop coding agent is working, and only while at least one such agent remains active. It currently integrates with Codex, Cursor, and Claude through their lifecycle hooks and uses Amphetamine to manage the macOS power assertion.

The display may sleep, including when the lid is closed, while the agent continues running. Agent Awake asks Amphetamine to allow display sleep and enable closed-display mode whenever it starts an owned session.

## How it works

Each desktop app sends lifecycle events to one local controller:

1. A prompt starts a source- and session-specific lease.
2. Tool or agent activity refreshes that lease.
3. Stop and session-end events release the matching lease.
4. The controller keeps one Amphetamine session alive while any lease exists.
5. The controller ends only the Amphetamine session it started, after the final lease ends and a short grace period elapses.

Leases also expire after eight hours and are removed when their owning desktop-app process exits. A LaunchAgent reconciles stale state every 30 seconds, so a crashed app or missed stop hook cannot keep the machine awake indefinitely.

## Requirements

- macOS
- [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) installed and allowed to run AppleScript automation
- Xcode Command Line Tools, including Swift
- `jq` available on `PATH`

Amphetamine and macOS may require their own permissions or power configuration for closed-display operation. Agent Awake enables the Amphetamine mode; it does not bypass macOS hardware or security requirements.

## Install

```zsh
./install.zsh
```

The installer builds the controller from source, installs it under `~/Library/Application Support/AgentAwake`, installs a per-user LaunchAgent, and safely merges hooks into:

- `~/.codex/hooks.json`
- `~/.cursor/hooks.json`
- `~/.claude/settings.json`

Existing configuration is preserved. Timestamped backups are written under `~/Library/Application Support/AgentAwake/backups` before every install.

Restart Codex, Cursor, and Claude after the first install so their desktop processes reload the hook configuration.

## Verify

Run the isolated test suite:

```zsh
./test.zsh
```

Inspect the live controller state:

```zsh
"$HOME/Library/Application Support/AgentAwake/agent-awake" status | jq
```

Start a local agent turn in one of the supported desktop apps. `leaseCount` should become positive and `amphetamineOwned` should be `true` unless an unrelated Amphetamine session was already active. Finish every active turn; after the grace period, `leaseCount` should reach zero and an Agent Awake-owned session should end.

To verify multi-app behavior, start turns in two apps and stop only one. Amphetamine must remain active until the second app's lease also ends.

## Build directly

```zsh
./build.zsh
./build/agent-awake status
```

Build output is intentionally excluded from Git.

## Safety properties

- Hook failures fail open and never block the agent protocol.
- Session identifiers are stored only as SHA-256 hashes.
- State and logs use user-only filesystem permissions.
- Remote/background Cursor events are ignored.
- Existing non-Agent-Awake hooks survive repeated installs.
- A pre-existing or externally changed Amphetamine session is left alone.
