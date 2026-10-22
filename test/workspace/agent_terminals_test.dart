import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_service.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/workspace/agent_host.dart';
import 'package:baocode/workspace/agent_server.dart';
import 'package:baocode/workspace/agent_terminals.dart';
import 'package:baocode/workspace/workspace.dart';

import '../ide/terminal/fake_pty.dart';
import '../ide/terminal/fake_terminal.dart';

/// A prompt as VS Code's shell integration reports it.
const _prompt = '\x1b]633;A\x07\$ \x1b]633;B\x07';

void main() {
  group('destructiveCommand', () {
    test('finds what could lose data, wherever it is in the line', () {
      for (final line in [
        'rm -rf /',
        'sudo rm -r /var/www',
        'ls && rm -f a.txt',
        'rm --recursive build',
        'find . -name "*.log" -delete',
        'mkfs.ext4 /dev/sdb1',
        'dd if=/dev/zero of=/dev/sda bs=1M',
        'cat x > /dev/nvme0n1',
        'sudo reboot',
        'chmod -R 777 /',
        'chown -R me /etc',
        ':(){ :|:& };:',
        'kill -9 -1',
        'crontab -r',
        'git push origin main --force',
        'git push -f',
        'git reset --hard HEAD~3',
        'git clean -fdx',
        'mysql -e "drop table users"',
        'TRUNCATE TABLE orders;',
        'docker system prune -a',
        'kubectl delete pod web-1',
      ]) {
        expect(destructiveCommand(line), isNotNull, reason: line);
      }
    });

    test('lets the everyday through', () {
      for (final line in [
        'ls -la',
        'rm notes.txt',
        'grep -r rm .',
        'npm run format',
        'git push origin main',
        'chmod -R 755 ./dist',
        'systemctl status nginx',
        'tail -f /var/log/syslog',
        'SELECT * FROM users;',
      ]) {
        expect(destructiveCommand(line), isNull, reason: line);
      }
    });
  });

  test('ssh to a server is found wherever it starts a command', () {
    for (final (command, host) in [
      ('ssh jiageng', 'jiageng'),
      ("ssh deploy@web 'systemctl status nginx'", 'deploy@web'),
      ('ssh -p 2222 -i ~/.ssh/k me@10.0.0.1 uptime', 'me@10.0.0.1'),
      ('ssh -tt -oStrictHostKeyChecking=no box ls', 'box'),
      ('ssh -NL 8080:localhost:80 box', 'box'),
      ('cd /x && ssh box "df -h"', 'box'),
      ('echo hi; sudo ssh root@db', 'root@db'),
      (r'out=$(ssh box cat /etc/os-release)', 'box'),
      ('timeout 30 ssh box true', 'box'),
      ('ssh -- box', 'box'),
    ]) {
      expect(sshDestination(command), host, reason: command);
    }
  });

  test('ssh for git, files or keys is let be', () {
    for (final command in [
      'ssh -T git@github.com',
      'ssh -T git@gitlab.com',
      'git push origin main',
      'scp a.txt box:/tmp/',
      'rsync -av ./dist box:/srv/',
      'ssh-keygen -t ed25519',
      'ssh-add -l',
      'ssh -V',
      'cat ~/.ssh/config',
      'echo ssh box',
      'grep ssh notes.md',
    ]) {
      expect(sshDestination(command), isNull, reason: command);
    }
  });

  test("the agent's ssh is turned to a terminal by its hook, through the "
      'command', () async {
    final dir = await Directory.systemTemp.createTemp('baocode-agent-');
    addTearDown(() => dir.delete(recursive: true));
    final workspace = Workspace(
      kernels: MockKernels.all,
      projects: const [Project('app', '/tmp/app')],
    );
    final host = AgentHost(workspace);
    await serveAgents(host, directory: dir.path, installSkill: false);
    final environment = host.environmentOf(workspace.create());
    Future<ProcessResult> hook(Map<String, Object?> event) async {
      final process = await Process.start(
        environment[AgentHost.commandVariable]!,
        ['hook', 'pre-tool-use'],
        environment: environment,
      );
      process.stdin.write(jsonEncode(event));
      await process.stdin.close();
      final stdout = await process.stdout.transform(utf8.decoder).join();
      return ProcessResult(process.pid, await process.exitCode, stdout, '');
    }

    final denied = await hook({
      'hook_event_name': 'PreToolUse',
      'tool_name': 'Bash',
      'tool_input': {'command': "ssh jiageng 'uptime'"},
    });
    expect(denied.exitCode, 0);
    final output = jsonDecode('${denied.stdout}') as Map;
    expect(
      output['hookSpecificOutput'],
      containsPair('permissionDecision', 'deny'),
    );
    expect(
      '${output['hookSpecificOutput']['permissionDecisionReason']}',
      contains('terminal open --ssh jiageng'),
    );

    for (final event in [
      {
        'tool_name': 'Bash',
        'tool_input': {'command': 'git push'},
      },
      {
        'tool_name': 'Read',
        'tool_input': {'file_path': '/tmp/a'},
      },
    ]) {
      final let = await hook(event);
      expect(let.exitCode, 0);
      expect(let.stdout, isEmpty, reason: '$event');
    }
  });

  test('Claude Code BaoCode can be reached from is told to use terminals '
      'for servers, and hooked; one it cannot, neither', () {
    final reached = ClaudeLaunch(
      cwd: '/tmp/app',
      variables: const {
        AgentHost.commandVariable: '/x/baocode-agent',
        AgentHost.urlVariable: 'http://127.0.0.1:1/k',
      },
    );
    expect(ClaudeLaunch.agentCommandVariable, AgentHost.commandVariable);
    expect(reached.systemPrompt, contains('<servers>'));
    expect(reached.settings['hooks'], ClaudeLaunch.sshHook);
    final prompt = reached
        .arguments[reached.arguments.indexOf('--append-system-prompt') + 1];
    expect(prompt, reached.systemPrompt);

    const apart = ClaudeLaunch(cwd: '/tmp/app');
    expect(apart.systemPrompt, ClaudeLaunch.appendedSystemPrompt);
    expect(apart.settings.containsKey('hooks'), isFalse);
  });

  test('keys as the terminal sends them', () {
    expect(keySequence('Enter'), '\r');
    expect(keySequence('C-c'), '\x03');
    expect(keySequence('ctrl-D'), '\x04');
    expect(keySequence('Esc'), '\x1b');
    expect(keySequence('Up'), '\x1b[A');
    expect(keySequence('up', applicationCursor: true), '\x1bOA');
    expect(keySequence('M-b'), '\x1bb');
    expect(keySequence('F5'), '\x1b[15~');
    expect(keySequence('q'), 'q');
    expect(keySequence('中'), '中');
    expect(keySequence('Hyper-x'), isNull);
  });

  test('ssh runs bash with the shell integration, from its command alone', () {
    final arguments = sshArguments('me@server', 'the-nonce');
    expect(arguments.take(3), ['-t', '--', 'me@server']);
    expect(arguments.last, contains('VSCODE_NONCE=the-nonce'));
    expect(arguments.last, startsWith("exec sh -c '"));
    expect(arguments.last, contains(r'exec bash --init-file "$f" -i'));
  });

  test("the command ssh gives the server's shell starts bash reporting its "
      'commands', () async {
    final home = await Directory.systemTemp.createTemp('agent-terminal-');
    addTearDown(() => home.delete(recursive: true));
    final tmp = Directory('${home.path}/tmp')..createSync();
    // Each time: it once read its script from a pipe, which bash now and
    // then found empty.
    for (var i = 0; i < 5; i++) {
      // As sshd runs it: the user's shell, given the command.
      final process = await Process.start(
        '/bin/sh',
        ['-c', sshArguments('server', 'n0nce').last],
        environment: {
          'HOME': home.path,
          'PATH': '/usr/bin:/bin',
          'TMPDIR': tmp.path,
        },
        includeParentEnvironment: false,
      );
      process.stdin.writeln('echo from-the-server');
      process.stdin.writeln('exit');
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      final output = '${await stdout}${await stderr}';
      expect(code, 0, reason: output);
      expect(output, contains('from-the-server'));
      expect(output, contains('\x1b]633;A'), reason: output);
      expect(output, contains('\x1b]633;D'), reason: output);
      // Nothing left on the server.
      expect(tmp.listSync(), isEmpty);
    }
  }, skip: Platform.isWindows || !File('/bin/bash').existsSync());

  group('baocode-agent terminal', () {
    late Workspace workspace;
    late AgentHost host;
    late AgentThread caller;
    late TerminalService service;
    late List<FakePty> started;
    late List<TerminalInstance> shown;
    late String key;

    setUp(() {
      workspace = Workspace(
        kernels: MockKernels.all,
        projects: const [Project('app', '/tmp/app')],
      );
      started = [];
      service = TerminalService(
        root: '/tmp/app',
        backend: fakeTerminalBackend(started),
      );
      addTearDown(service.dispose);
      shown = [];
      workspace.agentTerminals = (_) => (service: service, show: shown.add);
      host = AgentHost(workspace)
        ..url = 'http://127.0.0.1:4100'
        ..command = '/tmp/bin/baocode-agent';
      host.terminals
        ..quiet = const Duration(milliseconds: 100)
        ..settle = const Duration(milliseconds: 20)
        ..opening = const Duration(milliseconds: 300);
      caller = workspace.create();
      key = host.environmentOf(caller)[AgentHost.urlVariable]!.split('/').last;
    });

    Future<AgentReply> run(List<String> arguments) =>
        host.run(key, ['terminal', ...arguments]);

    /// Opens t1, its shell at a prompt it reports.
    Future<FakePty> open([List<String> options = const []]) async {
      final opening = run(['open', ...options]);
      await pumpEventQueue();
      final pty = started.last..emitText(_prompt);
      final reply = await opening;
      expect(reply.ok, isTrue, reason: reply.text);
      expect(reply.text.split('\n').first, 't1');
      return pty;
    }

    test('opens a terminal in the panel, on a server over ssh', () async {
      final pty = await open(['--ssh', 'deploy@web']);
      expect(pty.launch!.executable, 'ssh');
      expect(pty.launch!.arguments.take(3), ['-t', '--', 'deploy@web']);
      expect(service.instances.single.title, 'ssh deploy@web');
      expect(shown, [service.instances.single]);
      expect((await run(['list'])).text, startsWith('t1  ssh deploy@web'));

      final refused = await run(['open', '--ssh', '-oProxyCommand=x']);
      expect(refused.ok, isFalse);
    });

    test('runs a command, and tells its output and exit code', () async {
      final pty = await open();
      final running = run(['run', 't1', 'ls']);
      await pumpEventQueue();
      expect(pty.written, endsWith('ls\r'));
      pty.emitText(
        'ls\r\n\x1b]633;C\x07a.txt\r\nb.txt\r\n\x1b]633;D;2\x07$_prompt',
      );
      final reply = await running;
      expect(reply.text, contains('exited 2'));
      expect(reply.text, contains('a.txt\nb.txt'));
    });

    test('one still running after its timeout is said to be, and waited '
        'for', () async {
      final pty = await open();
      final running = run(['run', 't1', 'sleep 9', '--timeout', '0.05']);
      await pumpEventQueue();
      pty.emitText('sleep 9\r\n\x1b]633;C\x07');
      final reply = (await running).text;
      expect(reply, contains('still running'));
      expect(reply, contains('after 0.05s'));
      final waiting = run(['wait', 't1']);
      await pumpEventQueue();
      pty.emitText('\x1b]633;C\x07\x1b]633;D;0\x07$_prompt');
      expect((await waiting).text, contains('exited 0'));
    });

    test('one done between run giving up and wait is still told', () async {
      final pty = await open();
      final running = run(['run', 't1', 'make', '--timeout', '0.05']);
      await pumpEventQueue();
      pty.emitText('make\r\n\x1b]633;C\x07');
      expect((await running).text, contains('still running'));
      pty.emitText('built\r\n\x1b]633;D;1\x07$_prompt');
      await pumpEventQueue();
      final waited = (await run(['wait', 't1'])).text;
      expect(waited, contains('exited 1'));
      expect(waited, contains('built'));
      // Told once.
      expect((await run(['wait', 't1'])).text, contains('running nothing'));
    });

    test("opens with the prompt drawn, and says when ssh could not", () async {
      final opening = run(['open']);
      await pumpEventQueue();
      final pty = started.last..emitText('\x1b]633;A\x07');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      pty.emitText('user@host \$ \x1b]633;B\x07');
      expect((await opening).text, contains('user@host \$'));

      final failing = run(['open', '--ssh', 'nowhere']);
      await pumpEventQueue();
      started.last
        ..emitText('ssh: Could not resolve hostname nowhere\r\n')
        ..exit(255);
      final failed = await failing;
      expect(failed.ok, isFalse);
      expect(failed.text, startsWith('t2\n'));
      expect(failed.text, contains('exited (255)'));
      expect(failed.text, contains('Could not resolve hostname'));
    });

    test('a destructive command is only typed: Enter is the user\'s', () async {
      final pty = await open();
      final reply = await run(['run', 't1', 'sudo rm -rf /srv/old']);
      expect(reply.text, contains('only typed'));
      expect(pty.written, contains('sudo rm -rf /srv/old'));
      // Brought in sight again, for the user to see it waits for them.
      expect(shown, hasLength(2));
      expect(pty.written, isNot(contains('\r')));

      // Nor does the agent press Enter on it.
      pty.emitText('sudo rm -rf /srv/old');
      await pumpEventQueue();
      final waiting = await run(['wait', 't1', '--timeout', '0.05']);
      expect(waiting.text, contains('the user has not run'));
      final enter = await run(['keys', 't1', 'Enter']);
      expect(enter.ok, isFalse, reason: enter.text);
      expect(pty.written, isNot(contains('\r')));
      final typed = await run(['type', 't1', 'rm -r x\n']);
      expect(typed.ok, isFalse);
    });

    test('types and presses keys, and reads the screen', () async {
      final pty = await open();
      await run(['type', 't1', 'python3']);
      expect(pty.written, endsWith('python3'));
      await run(['keys', 't1', 'Enter', 'C-c']);
      expect(pty.written, endsWith('python3\r\x03'));
      pty.emitText('\r\n>>> ');
      await pumpEventQueue();
      final read = await run(['read', 't1']);
      expect(read.text, contains('>>>'));
      expect((await run(['keys', 't1', 'Hyper-x'])).ok, isFalse);
    });

    test('without shell integration, a command is done once the terminal is '
        'quiet', () async {
      final opening = run(['open']);
      await pumpEventQueue();
      final pty = started.last..emitText('server login banner\r\n# ');
      expect((await opening).text, contains('no shell integration'));
      final running = run(['run', 't1', 'uptime']);
      await pumpEventQueue();
      pty.emitText('uptime\r\n 10:00 up 3 days\r\n# ');
      final reply = await running;
      expect(reply.text, contains('a guess'));
      expect(reply.text, contains('up 3 days'));
    });

    test('waits for what it is told to', () async {
      final pty = await open();
      final waiting = run(['wait', 't1', '--match', r'Listening on \d+']);
      await pumpEventQueue();
      pty.emitText('starting\r\nListening on 8080\r\n');
      expect((await waiting).text, contains('it shows'));
    });

    test('only its own terminals, and not once closed', () async {
      await open();
      final other = workspace.startAgent(const Project('app', '/tmp/app'));
      final otherKey = host
          .environmentOf(other)[AgentHost.urlVariable]!
          .split('/')
          .last;
      expect(
        (await host.run(otherKey, ['terminal', 'read', 't1'])).ok,
        isFalse,
      );
      service.kill(service.instances.single);
      final read = await run(['read', 't1']);
      expect(read.text, contains('closed by the user'));
      expect((await run(['list'])).text, 'You opened no terminals.');
    });

    test('close ends it', () async {
      final pty = await open();
      expect((await run(['close', 't1'])).text, 'Closed t1.');
      expect(service.instances, isEmpty);
      expect(pty.kills, isNotEmpty);
    });

    test('none without a window for them', () async {
      workspace.agentTerminals = null;
      final reply = await run(['open']);
      expect(reply.ok, isFalse);
    });
  });
}
