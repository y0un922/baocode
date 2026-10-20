import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/agent_host.dart';
import 'package:baocode/workspace/agent_server.dart';
import 'package:baocode/workspace/agent_skill.dart';
import 'package:baocode/workspace/workspace.dart';

void main() {
  test(
    'the command posts its arguments as given, and prints the answer',
    () async {
      final dir = await Directory.systemTemp.createTemp('baocode-agent-');
      addTearDown(() => dir.delete(recursive: true));
      final workspace = Workspace(
        kernels: MockKernels.all,
        projects: const [Project('app', '/tmp/app')],
      );
      final host = AgentHost(workspace);
      await serveAgents(host, directory: dir.path, installSkill: false);
      final caller = workspace.create();
      final environment = host.environmentOf(caller);
      Future<ProcessResult> run(
        List<String> arguments, {
        Map<String, String>? variables,
      }) => Process.run(
        environment[AgentHost.commandVariable]!,
        arguments,
        environment: variables ?? environment,
        includeParentEnvironment: variables == null,
      );

      expect((await run(['list'])).stdout, 'You started no agents.\n');
      const prompt = 'it\'s "quoted" & a=b%20 ünïcode\nand a line';
      final started = await run(['start', '--agent', 'codex', prompt]);
      expect(started.exitCode, 0, reason: '${started.stdout}');
      expect('${started.stdout}'.split('\n').first, 'a1');
      final worker = workspace.threads.last;
      expect((worker.session.itemAt(0) as UserMessageItem).text, prompt);

      final unknown = await run(['fly']);
      expect(unknown.exitCode, 1);
      expect('${unknown.stdout}', startsWith('Unknown command "fly".'));
      final outside = await run(['list'], variables: {'PATH': '/usr/bin:/bin'});
      expect(outside.exitCode, 2);
      worker.session.stop();
    },
  );

  late Workspace workspace;
  late AgentHost host;
  late AgentThread caller;
  late String key;

  /// [caller]'s key, as its process is given it.
  String keyOf(AgentThread thread) =>
      host.environmentOf(thread)[AgentHost.urlVariable]!.split('/').last;

  setUp(() {
    workspace = Workspace(
      kernels: MockKernels.all,
      projects: const [Project('app', '/tmp/app')],
    );
    host = AgentHost(workspace)
      ..url = 'http://127.0.0.1:4100'
      ..command = '/tmp/bin/baocode-agent';
    caller = workspace.create();
    key = keyOf(caller);
  });

  test("each agent's process is told where to reach the app, as itself", () {
    final environment = host.environmentOf(caller);
    expect(environment[AgentHost.commandVariable], '/tmp/bin/baocode-agent');
    expect(
      environment[AgentHost.urlVariable],
      startsWith('http://127.0.0.1:4100/'),
    );
    expect(host.environmentOf(caller), environment);
    final other = workspace.startAgent(const Project('other', '/tmp/other'));
    expect(keyOf(other), isNot(key));
    // As its session opens, it is given them.
    expect(caller.session.kernelContext.environment, environment);
    // One on another machine could not reach this one's app.
    final remote = workspace.startAgent(
      const Project('remote', 'ssh://server/srv/app'),
    );
    expect(host.environmentOf(remote), isEmpty);
  });

  testWidgets('an agent starts another beside it, waits for it and reads it', (
    tester,
  ) async {
    expect((await host.run('nobody', ['list'])).ok, isFalse);
    expect((await host.run(key, ['list'])).text, 'You started no agents.');
    expect((await host.run(key, ['start'])).ok, isFalse);

    final started = await host.run(key, [
      'start',
      '--agent',
      'codex',
      'Look',
      'at @lib/a.dart',
    ]);
    expect(started.ok, isTrue, reason: started.text);
    expect(started.text.split('\n').first, 'a1');
    final worker = workspace.threads.firstWhere(
      (thread) => thread.kernel == MockKernels.codex,
    );
    // Beside it, the caller still focused; asking before what it runs.
    expect(workspace.grid.panes, [caller, worker]);
    expect(workspace.selected, caller);
    expect(worker.session.selected(KernelChoiceKind.permission), 'untrusted');

    // The mock asks before running the tests.
    final waiting = host.run(key, ['wait', 'a1', '--timeout', '20']);
    await tester.pump(const Duration(seconds: 21));
    expect(
      (await waiting).text,
      "a1 is still waiting for the user's approval after 20s. "
      'Wait again: baocode-agent wait a1',
    );
    expect(
      (await host.run(key, ['list'])).text,
      'a1  Codex  waiting for the user\'s approval  "${worker.title}"',
    );
    expect((await host.run(key, ['send', 'a1', 'more'])).ok, isFalse);

    worker.session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
    final answered = host.run(key, ['wait', 'a1']);
    await tester.pump(const Duration(seconds: 30));
    final reply = await answered;
    expect(reply.text, startsWith('a1 answered:\n\n'));
    expect(reply.text, contains(worker.session.lastReply!));
    expect((await host.run(key, ['read', 'a1'])).text, reply.text);

    // Another message, stopped.
    expect((await host.run(key, ['send', 'a1', 'Again'])).ok, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect((await host.run(key, ['stop', 'a1'])).text, 'Stopping a1.');
    final stopped = host.run(key, ['wait', 'a1']);
    await tester.pump(const Duration(seconds: 1));
    expect((await stopped).text, startsWith('a1 was stopped'));

    // Its agents start none of their own.
    expect(
      (await host.run(keyOf(worker), ['start', 'Go'])).text,
      'An agent started by another cannot start agents of its own.',
    );
    expect((await host.run(key, ['wait', 'a2'])).ok, isFalse);
    worker.session.stop();
    await tester.pump(const Duration(seconds: 5));
  });

  test('the skill names the command and the variable it needs', () {
    final text = AgentSkill.text;
    expect(text, startsWith('---\nname: baocode-agents\n'));
    expect(text, contains('"\$BAOCODE_AGENT" start --agent codex'));
    expect(text, contains(r'test -n "${BAOCODE_AGENT_URL:-}"'));
    expect(AgentSkill.stale(null, text), isTrue);
    expect(AgentSkill.stale(text, text), isFalse);
    expect(AgentSkill.stale('my own', text), isFalse);
  });
}
