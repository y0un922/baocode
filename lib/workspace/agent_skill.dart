import 'dart:convert';

import 'agent_host.dart';

/// The skill that tells agents of `baocode-agent` (see [AgentHost]): in
/// Claude Code's skills and the Agent Skills folder Codex and pi read
/// (`~/.agents/skills/`). The user's as any skill is; BaoCode writes it
/// anew only while its [marker] is in it.
abstract final class AgentSkill {
  static const name = 'baocode-agents';

  /// Its line that says BaoCode wrote it; a skill without it is left as
  /// it is.
  static const marker =
      '<!-- Written by BaoCode, which keeps it up to date. '
      'Delete this line to keep your own changes. -->';

  /// Whether [existing] (its file's text, null for none) is to be written
  /// as [text]: none, or BaoCode's and not the same.
  static bool stale(String? existing, String text) =>
      existing == null || (existing.contains(marker) && existing != text);

  static const _description =
      'Start other coding agents (Codex, Claude Code) beside you in BaoCode, '
      'send them work, wait for them and read their answers; and work in '
      'terminals the user watches in BaoCode, on this machine or on a '
      'server over ssh with nothing installed there. Use only when the user '
      'asks for another agent to do something, to work with other agents in '
      'BaoCode, or to work in a terminal or on a server through BaoCode. '
      'Requires BAOCODE_AGENT_URL (an agent BaoCode started).';

  static String get text {
    const command = '"\$${AgentHost.commandVariable}"';
    return '''
---
name: $name
description: ${jsonEncode(_description)}
---
$marker

# Agents in BaoCode

BaoCode runs you, and can run other coding agents beside you: you hand them work and read what they answer, as the user would. Each shows in a pane of its own in BaoCode, beside yours, where the user watches it and approves what it runs.

Before anything else, check that BaoCode started you:

```bash
test -n "\${${AgentHost.urlVariable}:-}"
```

If it is not set, say that you are not running in BaoCode and stop.

## The command

Run it as `$command`, a path BaoCode gives you:

```bash
$command start --agent codex "Review the change in lib/auth.dart for bugs"
$command wait a1
$command send a1 "Now write a test for the bug you found"
$command wait a1 --timeout 300
$command read a1
$command stop a1
$command close a1
$command list
$command help
```

- `start [--agent claude|codex|pi] [--model <id>] [--effort <level>] <prompt>` starts an agent in your project on `<prompt>` and prints its id (`a1`, `a2`, …) on its first line. Without `--agent`, it is your own kind.
- `wait <id> [--timeout <seconds>]` waits until it has answered, then prints its answer. By default it waits up to 100 seconds; if the agent is still working it says so: run `wait` again. A longer `--timeout` must stay under how long your shell lets a command run.
- `send <id> <message>` sends it another message, once it has answered.
- `read <id>` prints its last answer; `stop <id>` stops it; `close <id>` closes its pane (stopping it first; it stays in the sidebar); `list` shows the agents you started and what each is doing.

## How to work with them

- Write a prompt that stands on its own: the agent sees none of your conversation. Say what to do, where, and what to answer with.
- The agents work in the same folder as you. Give each a part of its own, and do not change the same files at the same time.
- They ask the user before what they run. While one waits for the user's approval, `wait` says so: tell the user, and wait again.
- Start only as many as the work needs. An agent you started cannot start agents of its own.
- Check what an agent says it did before relying on it.
- Close the panes of the agents you are done with (`close <id>`).
- In Codex's sandbox, the command cannot reach BaoCode: run it with escalated permissions (outside the sandbox).

## Terminals

You can also work in terminals in BaoCode's side panel, which the user watches and can type in. Use one for a server (ssh, nothing installed there), or for what a one-off shell command cannot do: a program that keeps running, one that asks questions, a REPL, an editor.

```bash
$command terminal open --ssh deploy@my-server
$command terminal run t1 "systemctl status nginx"
$command terminal run t1 "tail -n 50 /var/log/nginx/error.log"
$command terminal type t1 "SELECT count(*) FROM users;"
$command terminal keys t1 Enter
$command terminal read t1 --lines 100
$command terminal wait t1 --match "Listening on" --timeout 120
$command terminal keys t1 C-c
$command terminal close t1
```

- `open [--ssh <host>] [--name <name>]` opens a terminal in your project, or on `<host>` as `ssh` reaches it (`user@host`, a Host of `~/.ssh/config`), and prints its id (`t1`, …) on its first line, then its screen. Where ssh asks for a password or a passphrase, ask the user to type it in the terminal, and `wait` for the prompt.
- `run <id> <command> [--timeout <seconds>]` runs a command at the prompt, waits until it is done, and prints its output and exit code. Where the shell does not report its commands (no bash on the server), it waits until the terminal is quiet: check the output.
- A command that looks destructive (`rm -r`, `dd`, `mkfs`, `DROP TABLE`, `git push --force`, …) is only typed at the prompt, not run: the user runs it with Enter, or not. Tell the user why it is needed, then `wait <id>`. `type` and `keys` do not press Enter on one.
- `type <id> <text>` types without Enter; `keys <id> <key>...` presses keys (`Enter`, `C-c`, `C-d`, `Esc`, `Tab`, `Up`, `q`, …): for programs that read keys, and to stop one (`C-c`). Each prints the screen after.
- `read <id> [--lines <n>]` prints the screen, or its last `<n>` lines with the scrollback. `wait <id>` waits until the running command is done; `--match <regex>` until it shows, `--idle <seconds>` until nothing is printed for that long.
- `list` shows your terminals; `close <id>` closes one, ending what runs in it. Close those you are done with.
''';
  }
}
