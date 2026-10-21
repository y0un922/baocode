// What an agent's `baocode-agent` command asks of the app: to start other
// agents beside it, send them work, wait for them and read what they said
// (the baocode-agents skill tells agents how). The command is a script
// that posts its arguments to a server of the app's, at the address each
// agent's process is given; the answer is what it prints.

import 'dart:async';
import 'dart:math' as math;

import '../chat/chat_session.dart' show ComposerMessage;
import '../kernel/agent_kernel.dart' show KernelChoiceKind;
import '../kernel/kernel_types.dart';
import '../remote/remote_location.dart';
import 'chat_grid.dart' show PaneSide;
import 'workspace.dart';

/// What the command prints, and whether it did what it was asked.
class AgentReply {
  const AgentReply(this.text, {this.ok = true});

  const AgentReply.error(this.text) : ok = false;

  final String text;
  final bool ok;
}

/// An agent another started, and what it was last sent.
class _Worker {
  _Worker(this.id, this.thread, this.owner);

  /// Its name to the command: `a1`, `a2`, …
  final String id;
  final AgentThread thread;
  final AgentThread owner;

  /// The last turn to end before its last message: its answer is in once
  /// a later one ends.
  int sentAfter = 0;
}

/// The agents' command's side in the app: who calls (each agent's process
/// is given an address of its own), and what each command does.
class AgentHost {
  AgentHost(this.workspace) {
    workspace.agentEnvironment = environmentOf;
  }

  final Workspace workspace;

  /// The server's address, once it listens (`http://127.0.0.1:<port>`).
  String? url;

  /// The command's path, once written.
  String? command;

  static const urlVariable = 'BAOCODE_AGENT_URL';
  static const commandVariable = 'BAOCODE_AGENT';

  /// How long `wait` waits by default: under the two minutes Claude Code
  /// gives a command before it stops it.
  static const defaultWait = Duration(seconds: 100);
  static const longestWait = Duration(minutes: 30);

  /// The approval mode an agent started by another works in, by kernel:
  /// asking before what it runs. A kernel not here asks nothing (pi), and
  /// is not started.
  static const _asking = {'claude-code': 'default', 'codex': 'untrusted'};

  static final _random = math.Random.secure();

  final Map<String, AgentThread> _callers = {};
  final Expando<String> _keys = Expando();
  final List<_Worker> _workers = [];
  int _started = 0;

  /// The variables [thread]'s process starts with: where to reach the app,
  /// as [thread]. None before the server listens, nor for an agent on
  /// another machine (it could not reach this one's).
  Map<String, String> environmentOf(AgentThread thread) {
    final (url, command) = (this.url, this.command);
    if (url == null ||
        command == null ||
        RemoteLocation.isRemote(thread.project.path)) {
      return const {};
    }
    final key = _keys[thread] ??= _newKey();
    _callers[key] = thread;
    return {urlVariable: '$url/$key', commandVariable: command};
  }

  static String _newKey() =>
      [for (var i = 0; i < 24; i++) _random.nextInt(256).toRadixString(16)]
          .join();

  /// What `baocode-agent` [arguments] does, called by the agent of [key].
  Future<AgentReply> run(String key, List<String> arguments) async {
    final caller = _callers[key];
    if (caller == null || !workspace.threads.contains(caller)) {
      return const AgentReply.error('This agent is no longer in BaoCode.');
    }
    final [command, ...rest] = arguments.isEmpty ? ['help'] : arguments;
    try {
      return switch (command) {
        'start' => _start(caller, rest),
        'send' => _send(_worker(caller, rest), rest.skip(1).join(' ')),
        'wait' => await _wait(_worker(caller, rest), _timeout(rest.skip(1))),
        'read' => _read(_worker(caller, rest)),
        'stop' => _stop(_worker(caller, rest)),
        'close' => _close(_worker(caller, rest)),
        'list' => _list(caller),
        'help' || '--help' || '-h' => const AgentReply(usage),
        _ => AgentReply.error('Unknown command "$command".\n\n$usage'),
      };
    } on _Refused catch (refused) {
      return AgentReply.error(refused.message);
    }
  }

  static const usage = '''
Usage: baocode-agent <command>

  start [--agent claude|codex|pi] [--model <id>] [--effort <level>] <prompt>
                       Start an agent in your project, beside you, on <prompt>.
                       Prints its id (a1, a2, …).
  send <id> <message>  Send it another message, once it is idle.
  wait <id> [--timeout <seconds>]
                       Wait until it has answered (by default up to 100s),
                       then print its answer.
  read <id>            Print its last answer.
  stop <id>            Stop what it is doing.
  close <id>           Close its pane, stopping it first: it stays in the
                       sidebar.
  list                 The agents you started, and what each is doing.''';

  AgentReply _start(AgentThread caller, List<String> arguments) {
    if (_workers.any((worker) => worker.thread == caller)) {
      throw const _Refused(
        'An agent started by another cannot start agents of its own.',
      );
    }
    String? kernelName, model, effort;
    final prompt = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      String value() => i + 1 < arguments.length
          ? arguments[++i]
          : throw _Refused('${arguments[i]} takes a value.');
      switch (arguments[i]) {
        case '--agent':
          kernelName = value();
        case '--model':
          model = value();
        case '--effort':
          effort = value();
        case '--':
          prompt.addAll(arguments.skip(i + 1));
          i = arguments.length;
        default:
          prompt.add(arguments[i]);
      }
    }
    final text = prompt.join(' ').trim();
    if (text.isEmpty) throw const _Refused('start takes a prompt.');
    final kernel = kernelName == null
        ? caller.kernel
        : workspace.kernels
              .where(
                (kernel) =>
                    kernel.id == kernelName ||
                    kernel.id == '$kernelName-code' ||
                    kernel.label.toLowerCase() == kernelName!.toLowerCase(),
              )
              .firstOrNull;
    if (kernel == null) {
      final names = [for (final kernel in workspace.kernels) kernel.id];
      throw _Refused(
        'No agent "$kernelName" here: one of ${names.join(', ')}.',
      );
    }
    final asking = _asking[kernel.id];
    if (asking == null) {
      throw _Refused(
        '${kernel.label} does not ask the user before what it runs, and '
        'agents started by another must: start another kind.',
      );
    }
    final thread = workspace.startWorker(caller.project, kernel, {
      KernelChoiceKind.mode: 'agent',
      KernelChoiceKind.permission: asking,
      KernelChoiceKind.model: ?model,
      KernelChoiceKind.effort: ?effort,
    });
    final worker = _Worker('a${++_started}', thread, caller);
    _workers.add(worker);
    _show(worker);
    _sendTo(worker, text);
    final where = workspace.grid.contains(thread)
        ? 'beside you'
        : 'in the sidebar (no room beside you)';
    return AgentReply(
      '${worker.id}\n'
      'Started ${kernel.label} as ${worker.id}, $where. It asks the user '
      'before what it runs. Wait for its answer: baocode-agent wait '
      '${worker.id}',
    );
  }

  /// Opens [worker] in half of its owner's pane, or of another of the
  /// owner's agents', the newest first; where there is no room, it is
  /// only listed.
  void _show(_Worker worker) {
    final grid = workspace.grid;
    final targets = [
      worker.owner,
      for (final other in _workers.reversed)
        if (other.owner == worker.owner && other != worker) other.thread,
    ];
    for (final target in targets) {
      if (!grid.contains(target)) continue;
      for (final side in const [PaneSide.right, PaneSide.bottom]) {
        if (grid.canSplit(target, side)) {
          workspace.openBeside(worker.thread, target, side, focus: false);
          return;
        }
      }
    }
  }

  _Worker _worker(AgentThread caller, List<String> arguments) {
    final id = arguments.firstOrNull;
    if (id == null) throw const _Refused('Which agent? Give its id (a1, …).');
    final worker = _workers
        .where((worker) => worker.id == id && worker.owner == caller)
        .firstOrNull;
    if (worker == null) {
      throw _Refused('You started no agent $id: see baocode-agent list.');
    }
    if (!workspace.threads.contains(worker.thread)) {
      throw _Refused('$id was closed by the user.');
    }
    return worker;
  }

  void _sendTo(_Worker worker, String text) {
    final session = worker.thread.session;
    worker.sentAfter = session.lastTurnEndSeq;
    session.send(ComposerMessage(text: text));
  }

  AgentReply _send(_Worker worker, String text) {
    if (text.trim().isEmpty) throw const _Refused('send takes a message.');
    if (_working(worker)) {
      throw _Refused(
        '${worker.id} is still working: baocode-agent wait ${worker.id} first.',
      );
    }
    _sendTo(worker, text);
    return AgentReply(
      'Sent. Wait for its answer: baocode-agent wait ${worker.id}',
    );
  }

  static Duration _timeout(Iterable<String> arguments) {
    final options = arguments.toList();
    final at = options.indexOf('--timeout');
    if (at < 0) return defaultWait;
    final seconds = int.tryParse(options.elementAtOrNull(at + 1) ?? '');
    if (seconds == null || seconds < 0) {
      throw const _Refused('--timeout takes a number of seconds.');
    }
    final timeout = Duration(seconds: seconds);
    return timeout > longestWait ? longestWait : timeout;
  }

  /// Whether [worker] has yet to answer its last message.
  bool _working(_Worker worker) {
    final session = worker.thread.session;
    return session.health.status != KernelHealthStatus.failed &&
        (session.isStreaming || session.lastTurnEndSeq <= worker.sentAfter);
  }

  Future<AgentReply> _wait(_Worker worker, Duration timeout) async {
    final session = worker.thread.session;
    if (_working(worker)) {
      final done = Completer<void>();
      void changed() {
        if (!_working(worker) && !done.isCompleted) done.complete();
      }

      session.addListener(changed);
      try {
        await done.future.timeout(timeout, onTimeout: () {});
      } finally {
        session.removeListener(changed);
      }
    }
    if (_working(worker)) {
      return AgentReply(
        '${worker.id} is still ${_status(worker)} after '
        '${timeout.inSeconds}s. Wait again: baocode-agent wait ${worker.id}',
      );
    }
    return _read(worker);
  }

  AgentReply _read(_Worker worker) {
    final session = worker.thread.session;
    final health = session.health;
    if (health.status == KernelHealthStatus.failed) {
      return AgentReply.error(
        '${worker.id} failed: ${health.message ?? 'it stopped'}',
      );
    }
    final reply = session.lastReply;
    final status = _working(worker)
        ? '${worker.id} is still ${_status(worker)}; its answer so far:'
        : session.lastTurnInterrupted
        ? '${worker.id} was stopped; what it said:'
        : '${worker.id} answered:';
    return AgentReply('$status\n\n${reply ?? '(nothing)'}');
  }

  AgentReply _stop(_Worker worker) {
    if (!_working(worker)) return AgentReply('${worker.id} is idle.');
    worker.thread.session.stop();
    return AgentReply('Stopping ${worker.id}.');
  }

  /// Closes [worker]'s pane, as the user would (the agent stays in the
  /// sidebar), stopping it first.
  AgentReply _close(_Worker worker) {
    if (_working(worker)) worker.thread.session.stop();
    if (!workspace.grid.contains(worker.thread)) {
      return AgentReply('${worker.id} has no pane open: it is in the sidebar.');
    }
    workspace.closePane(worker.thread);
    if (workspace.grid.contains(worker.thread)) {
      return AgentReply('${worker.id} is in the only pane left: kept open.');
    }
    return AgentReply('Closed ${worker.id}: it stays in the sidebar.');
  }

  AgentReply _list(AgentThread caller) {
    final mine = [
      for (final worker in _workers)
        if (worker.owner == caller && workspace.threads.contains(worker.thread))
          worker,
    ];
    if (mine.isEmpty) return const AgentReply('You started no agents.');
    return AgentReply(
      [
        for (final worker in mine)
          '${worker.id}  ${worker.thread.kernel.label}  ${_status(worker)}  '
              '"${worker.thread.title}"',
      ].join('\n'),
    );
  }

  /// What [worker] is doing, in a few words.
  String _status(_Worker worker) {
    final session = worker.thread.session;
    if (session.health.status == KernelHealthStatus.failed) return 'failed';
    if (!_working(worker)) return 'idle';
    if (session.pendingInteraction != null) {
      return "waiting for the user's approval";
    }
    return 'working';
  }
}

/// A command that cannot be done, and why: printed as it fails.
class _Refused implements Exception {
  const _Refused(this.message);

  final String message;
}
