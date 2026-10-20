import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/queued_messages.dart';
import 'package:baocode/kernel/transcript.dart';

import 'pi_kernel_test.dart' show shown;

/// What `codex app-server` 0.162.1 said in a turn of a real thread (in
/// `/project`, its hooks' and MCP servers' notices left out).
List<Map<String, Object?>> recorded(String name) => [
  for (final line in File('test/fixtures/codex/$name.jsonl').readAsLinesSync())
    if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast(),
];

const _thread = '01a156f5-758d-7360-a6e1-7633365d8ed3';

const _sol = {
  'id': 'gpt-6-sol',
  'displayName': 'GPT-6-Sol',
  'description': 'Frontier',
  'hidden': false,
  'supportedReasoningEfforts': [
    {'reasoningEffort': 'low', 'description': ''},
    {'reasoningEffort': 'medium', 'description': ''},
    {'reasoningEffort': 'xhigh', 'description': ''},
  ],
  'defaultReasoningEffort': 'medium',
  'isDefault': true,
};

const _luna = {
  'id': 'gpt-6-luna',
  'displayName': 'GPT-6-Luna',
  'description': 'Fast',
  'hidden': false,
  'supportedReasoningEfforts': [
    {'reasoningEffort': 'low', 'description': ''},
  ],
  'defaultReasoningEffort': 'low',
  'isDefault': false,
};

/// Codex as the tests speak it: answers requests the way the app server
/// does, plays [turn] after `turn/start`, and records what was written.
class FakeCodex implements CodexTransport {
  FakeCodex({this.turn = const [], this.history = const []});

  final List<Map<String, Object?>> turn;
  final List<Map<String, Object?>> history;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();
  final List<Map<String, Object?>> written = [];
  int _turns = 0;

  /// The requests written, by method.
  List<Map<String, Object?>> sent(String method) => [
    for (final m in written)
      if (m['method'] == method && m.containsKey('id'))
        (m['params'] as Map).cast(),
  ];

  /// The turn [turn] starts with: the recorded one's, else a new one.
  String get _turnId => switch (turn.firstOrNull) {
    {'params': {'turn': {'id': final String id}}} => id,
    _ => 'st${++_turns}',
  };

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    final id = message['id'];
    if (method == null || id == null) return;
    final params = (message['params'] as Map?) ?? const {};
    final thread = {'id': _thread, 'path': '/codex/$_thread.jsonl'};
    final turnId = method == 'turn/start' ? _turnId : null;
    final result = switch (method) {
      'model/list' => {
        'data': [_sol, _luna],
        'nextCursor': null,
      },
      'skills/list' => {
        'data': [
          {
            'cwd': '/project',
            'skills': [
              {
                'name': 'tidy',
                'description': 'Tidy up',
                'path': '/skills/tidy/SKILL.md',
                'enabled': true,
              },
            ],
          },
        ],
      },
      'account/rateLimits/read' => {
        'rateLimits': {
          'primary': {
            'usedPercent': 5,
            'windowDurationMins': 10080,
            'resetsAt': 1792893537,
          },
        },
      },
      'thread/start' => {'thread': thread},
      'thread/resume' => {
        'thread': thread,
        'model': 'gpt-6-luna',
        'reasoningEffort': 'low',
        'approvalPolicy': 'untrusted',
        'sandbox': {'type': 'workspaceWrite'},
      },
      'thread/turns/list' => _page(params),
      'thread/fork' => {
        'thread': {'id': 'forked', 'path': '/codex/forked.jsonl'},
      },
      'turn/start' => {
        'turn': {'id': turnId, 'status': 'inProgress'},
      },
      // As Codex has them: one configured in the user's file, one turned
      // off there, and its own.
      'config/read' => {
        'config': {
          'mcp_servers': {
            'fs': {'command': 'npx'},
            'off': {'command': 'false', 'enabled': false},
          },
        },
        'origins': {
          for (final key in ['fs.command', 'off.command', 'off.enabled'])
            'mcp_servers.$key': {
              'name': {'type': 'user', 'file': '/home/.codex/config.toml'},
              'version': 'sha256:1',
            },
        },
      },
      'mcpServerStatus/list' => {
        'data': [
          {
            'name': 'fs',
            'authStatus': 'unsupported',
            'runtimeStatus': params['threadId'] == null ? null : 'connected',
            'tools': {'read': {}, 'write': {}},
            'serverInfo': {'name': 'fs', 'version': '1.0.0'},
          },
          {
            'name': 'off',
            'authStatus': 'unsupported',
            'runtimeStatus': params['threadId'] == null ? null : 'disabled',
            'tools': {},
          },
          {
            'name': 'codex_apps',
            'authStatus': 'notLoggedIn',
            'runtimeStatus': null,
            'tools': {},
          },
        ],
        'nextCursor': null,
      },
      'mcpServer/oauth/login' => {
        'authorizationUrl': 'https://example.com/authorize',
        'loginId': 'l1',
      },
      _ => <String, Object?>{},
    };
    if (method == 'turn/interrupt') {
      // The turn ends before the server answers.
      emit({
        'method': 'turn/completed',
        'params': {
          'threadId': _thread,
          'turn': {'id': params['turnId'], 'status': 'interrupted'},
        },
      });
    }
    emit({'id': id, 'result': result});
    if (method == 'turn/start') {
      if (turn.isEmpty) {
        emit({
          'method': 'turn/started',
          'params': {
            'threadId': _thread,
            'turn': {'id': turnId, 'status': 'inProgress'},
          },
        });
      }
      turn.forEach(emit);
    }
  }

  /// [history] as Codex pages it: newest first when `desc`, [limit] at a
  /// time from the cursor on.
  Map<String, Object?> _page(Map<Object?, Object?> params) {
    final turns = params['sortDirection'] == 'desc'
        ? history.reversed.toList()
        : history;
    final from = int.tryParse('${params['cursor']}') ?? 0;
    final to = math.min(
      turns.length,
      from + ((params['limit'] as int?) ?? turns.length),
    );
    return {
      'data': turns.sublist(from, to),
      'nextCursor': to < turns.length ? '$to' : null,
    };
  }

  void emit(Map<String, Object?> message) => _out.add(message);

  /// The server asks [method] of the client.
  void ask(Object id, String method, Map<String, Object?> params) =>
      emit({'id': id, 'method': method, 'params': params});

  /// The responses written to the server's request [id].
  List<Object?> answers(Object id) => [
    for (final m in written)
      if (m['id'] == id && !m.containsKey('method')) m['result'],
  ];

  @override
  void close() => _out.close();
}

final _descriptor = KernelDescriptor(
  id: 'codex',
  label: 'Codex',
  icon: Icons.data_object_rounded,
  description: '',
  create: (_) => throw UnimplementedError(),
);

({CodexKernel kernel, Transcript transcript, List<KernelEvent> events})
codexKernel(
  List<FakeCodex> servers, {
  KernelContext context = const KernelContext(cwd: '/project'),
}) {
  var started = 0;
  final kernel = CodexKernel(
    _descriptor,
    context,
    start: (cwd, {environment = const {}}) async => servers[started++],
  );
  final transcript = Transcript();
  final events = <KernelEvent>[];
  kernel.events.listen((event) {
    events.add(event);
    transcript.apply(event);
  });
  addTearDown(kernel.dispose);
  return (kernel: kernel, transcript: transcript, events: events);
}

void main() {
  group('Codex adapter', () {
    test('a recorded turn: a listing, a command, the answer', () async {
      final codex = FakeCodex(turn: recorded('commands'));
      final (:kernel, :transcript, :events) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Edit a.txt'));
      await pumpEventQueue();

      expect(shown(transcript), [
        'user: Edit a.txt',
        'tool: listDir . succeeded',
        'terminal: python3 -c \'from pathlib import Path; p=Path("a.txt"); '
            'p.write_text(p.read_text().replace("line two", "line 2"))\' → '
            ' succeeded',
        'text: done',
      ]);
      expect(transcript.activeTurn, isNull);
      expect(
        [
          for (final m in codex.written)
            if (m['method'] case final String method) method,
        ].take(3),
        ['initialize', 'initialized', 'model/list'],
      );
      final thread = codex.sent('thread/start').single;
      expect(thread['cwd'], '/project');
      expect(thread['sandbox'], 'workspace-write');
      expect(thread['approvalPolicy'], 'on-request');
      final turn = codex.sent('turn/start').single;
      expect(turn['threadId'], _thread);
      expect(turn['clientUserMessageId'], 't1');
      expect(turn['model'], 'gpt-6-sol');
      expect(turn['effort'], 'medium');
      expect(turn.containsKey('sandboxPolicy'), isFalse);
      expect(kernel.sessionId, _thread);

      // What its requests spent, summed.
      final ended = events.whereType<TurnEnded>().single;
      expect(ended.usage?.inputTokens, 14708 + 14771 + 14867);
      expect(ended.usage?.outputTokens, 37 + 73 + 5);
      expect(
        events.whereType<UsageReported>().last.usage,
        isA<ContextUsage>()
            .having((u) => u.used, 'used', 14872)
            .having((u) => u.window, 'window', 258400),
      );
      expect(kernel.contextWindow, 258400);
      // The account's weekly window.
      expect(kernel.accountLimits.single.label, 'Weekly limit');
      expect(kernel.accountLimits.single.utilization, closeTo(.05, 1e-9));
    });

    test(
      'TPS waits for actual usage and includes reasoning and TTFT',
      () async {
        final codex = FakeCodex();
        final (:kernel, transcript: _, :events) = codexKernel([codex]);
        final beforeSend = DateTime.now();
        kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
        await pumpEventQueue();
        final waiting = DateTime.now();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        codex.emit({
          'method': 'item/started',
          'params': {
            'threadId': _thread,
            'turnId': 'st1',
            'item': {'id': 'a1', 'type': 'agentMessage'},
          },
        });
        codex.emit({
          'method': 'item/agentMessage/delta',
          'params': {
            'threadId': _thread,
            'turnId': 'st1',
            'itemId': 'a1',
            'delta': 'tiny answer',
          },
        });
        await pumpEventQueue();
        expect(
          events.whereType<OutputReported>().last.output.tokensPerSecond,
          isNull,
        );
        final beforeUsage = DateTime.now();
        codex.emit({
          'method': 'thread/tokenUsage/updated',
          'params': {
            'threadId': _thread,
            'turnId': 'st1',
            'tokenUsage': {
              'last': {'outputTokens': 500, 'reasoningOutputTokens': 400},
            },
          },
        });
        await pumpEventQueue();
        final output = events.whereType<OutputReported>().last.output;
        expect(output.tokens, 500);
        // Bound the observed request time, without assuming timer precision.
        expect(
          output.tokensPerSecond,
          greaterThanOrEqualTo(
            500e6 / DateTime.now().difference(beforeSend).inMicroseconds,
          ),
        );
        expect(
          output.tokensPerSecond,
          lessThanOrEqualTo(
            500e6 / beforeUsage.difference(waiting).inMicroseconds,
          ),
        );
      },
    );

    test(
      'parallel tools and approval waits are excluded before delayed usage',
      () async {
        final codex = FakeCodex();
        final (:kernel, transcript: _, :events) = codexKernel([codex]);
        final beforeSend = DateTime.now();
        kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
        await pumpEventQueue();
        void item(String method, String id) => codex.emit({
          'method': method,
          'params': {
            'threadId': _thread,
            'turnId': 'st1',
            'item': {'id': id, 'type': 'fileChange', 'changes': []},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 40));
        item('item/started', 'p1');
        item('item/started', 'p2');
        await pumpEventQueue();
        final paused = DateTime.now();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        item('item/completed', 'p1');
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        codex.emit({
          'id': 901,
          'method': 'item/permissions/requestApproval',
          'params': {'threadId': _thread, 'turnId': 'st1', 'permissions': {}},
        });
        item('item/completed', 'p2');
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final excluded = DateTime.now().difference(paused);
        kernel.answer(
          'codex-request:901',
          const ApprovalAnswer(ApprovalDecision.allowOnce),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        codex.emit({
          'method': 'thread/tokenUsage/updated',
          'params': {
            'threadId': _thread,
            'turnId': 'st1',
            'tokenUsage': {
              'last': {'outputTokens': 500},
            },
          },
        });
        await pumpEventQueue();
        final output = events.whereType<OutputReported>().last.output;
        final elapsed = DateTime.now().difference(beforeSend) - excluded;
        expect(output.tokens, 500);
        expect(
          output.tokensPerSecond,
          greaterThanOrEqualTo(500e6 / elapsed.inMicroseconds),
        );
      },
    );

    test('partial usage does not finish the request or lose TTFT', () async {
      final codex = FakeCodex();
      final (:kernel, transcript: _, :events) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
      await pumpEventQueue();
      final waiting = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      codex.emit({
        'method': 'thread/tokenUsage/updated',
        'params': {
          'threadId': _thread,
          'turnId': 'st1',
          'tokenUsage': {
            'last': {'inputTokens': 100},
          },
        },
      });
      await pumpEventQueue();
      expect(events.whereType<OutputReported>(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final beforeUsage = DateTime.now();
      codex.emit({
        'method': 'thread/tokenUsage/updated',
        'params': {
          'threadId': _thread,
          'turnId': 'st1',
          'tokenUsage': {
            'last': {'inputTokens': 100, 'outputTokens': 100},
          },
        },
      });
      await pumpEventQueue();
      expect(
        events.whereType<OutputReported>().single.output.tokensPerSecond,
        lessThanOrEqualTo(
          100e6 / beforeUsage.difference(waiting).inMicroseconds,
        ),
      );
      codex.emit({
        'method': 'turn/completed',
        'params': {
          'threadId': _thread,
          'turn': {'id': 'st1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.usage?.inputTokens, 100);
    });

    test('repeated cumulative usage is not another model request', () async {
      final codex = FakeCodex();
      final (:kernel, transcript: _, :events) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
      await pumpEventQueue();
      void usage(int total) => codex.emit({
        'method': 'thread/tokenUsage/updated',
        'params': {
          'threadId': _thread,
          'turnId': 'st1',
          'tokenUsage': {
            'total': {'totalTokens': total},
            'last': {'inputTokens': 100, 'outputTokens': 100},
          },
        },
      });
      usage(200);
      await pumpEventQueue();
      final first = events.whereType<OutputReported>().single.output;
      usage(200);
      await pumpEventQueue();
      expect(events.whereType<OutputReported>().length, 1);
      expect(events.whereType<OutputReported>().last.output.tokens, 100);
      expect(
        events.whereType<OutputReported>().last.output.tokensPerSecond,
        first.tokensPerSecond,
      );
      usage(400); // Same last counts, but genuinely another request.
      await pumpEventQueue();
      expect(events.whereType<OutputReported>().last.output.tokens, 200);
      codex.emit({
        'method': 'turn/completed',
        'params': {
          'threadId': _thread,
          'turn': {'id': 'st1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.usage?.inputTokens, 200);
      expect(events.whereType<TurnEnded>().single.usage?.outputTokens, 200);
    });

    test('a recorded patch: its diff to review', () async {
      final codex = FakeCodex(turn: recorded('patch'));
      final (:kernel, :transcript, :events) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Add a line'));
      await pumpEventQueue();

      expect(shown(transcript), [
        'user: Add a line',
        'text: I’ll use `apply_patch` on `a.txt` as requested.',
        'diff: /project/a.txt +1 -0',
        'text: ok',
      ]);
      final edited = events.whereType<FileEdited>().single;
      expect(edited.change.path, '/project/a.txt');
      expect(edited.turnId, 't1');
      expect(
        (edited.original! as OriginalByPatch).diff,
        '@@ -2 +2,2 @@\n line 2\n+line three\n',
      );
    });

    test('models with their makers\' logos and efforts; modes and '
        'approvals as the thread starts', () async {
      final codex = FakeCodex();
      final (:kernel, transcript: _, events: _) = codexKernel([codex]);
      kernel.prepare();
      await pumpEventQueue();

      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(
        [for (final o in kernel.model.options) o.id],
        ['gpt-6-sol', 'gpt-6-luna'],
      );
      expect(kernel.model.options.first.iconBuilder, isNotNull);
      expect(kernel.model.selected, 'gpt-6-sol');
      expect(
        [for (final o in kernel.effort.optionsFor('gpt-6-sol')) o.id],
        ['low', 'medium', 'xhigh'],
      );
      expect(kernel.effort.selectedFor('gpt-6-luna'), 'low');
      expect(
        [for (final c in kernel.commands) c.name],
        ['compact', 'review', 'tidy'],
      );

      kernel.mode.select('ask');
      kernel.effort.select('gpt-6-sol', 'xhigh');
      kernel.send(const KernelTurn(id: 't1', text: 'Explain'));
      await pumpEventQueue();
      final thread = codex.sent('thread/start').single;
      expect(thread['sandbox'], 'read-only');
      expect(thread['approvalPolicy'], 'never');
      expect(codex.sent('turn/start').single['effort'], 'xhigh');
      codex.emit({
        'method': 'turn/completed',
        'params': {
          'threadId': _thread,
          'turn': {'id': 'st1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      // Another picked since: the next turn says so.
      kernel.mode.select('agent');
      kernel.permission.select('full');
      kernel.send(const KernelTurn(id: 't2', text: '/tidy the tests'));
      await pumpEventQueue();
      final turn = codex.sent('turn/start').last;
      expect(turn['sandboxPolicy'], {'type': 'dangerFullAccess'});
      expect(turn['approvalPolicy'], 'never');
      // A skill, named first.
      expect(turn['input'], [
        {'type': 'skill', 'name': 'tidy', 'path': '/skills/tidy/SKILL.md'},
        {'type': 'text', 'text': 'the tests', 'text_elements': <Object?>[]},
      ]);
    });

    test(
      'not started yet: its models asked of a server of their own',
      () async {
        CodexKernel.forgetModels();
        final lister = FakeCodex();
        final (:kernel, transcript: _, events: _) = codexKernel([lister]);
        expect([for (final o in kernel.model.options) o.id], ['default']);
        await pumpEventQueue();

        expect(lister.sent('model/list'), isNotEmpty);
        expect(kernel.health.status, KernelHealthStatus.idle);
        expect(
          [for (final o in kernel.model.options) o.id],
          ['gpt-6-sol', 'gpt-6-luna'],
        );
        kernel.effort.select('gpt-6-luna', 'medium');
        expect(kernel.model.selected, 'gpt-6-luna');
      },
    );

    test('MCP servers: where they stand, turned off in their own file, '
        'and signed in to', () async {
      final codex = FakeCodex();
      final (:kernel, transcript: _, events: _) = codexKernel([codex]);
      expect(kernel.mcpServers, isNull);
      kernel.refreshMcpServers();
      await pumpEventQueue();

      String shown(McpServer s) =>
          '${s.name} ${s.status.name} ${s.scope} ${s.tools.length} '
          '${s.version} ${s.toggles}';
      // No thread yet: as listing them found them.
      expect(kernel.mcpServers!.map(shown), [
        'fs connected user 2 1.0.0 true',
        'off disabled user 0 null true',
        // Codex's own: not the user's to turn off.
        'codex_apps needsAuth null 0 null false',
      ]);

      kernel.setMcpServerEnabled('fs', false);
      expect(kernel.mcpServers!.first.status, McpServerStatus.disabled);
      await pumpEventQueue();
      expect(codex.sent('config/value/write').single, {
        'keyPath': 'mcp_servers.fs.enabled',
        'value': false,
        'mergeStrategy': 'upsert',
        'filePath': '/home/.codex/config.toml',
      });
      expect(codex.sent('config/mcpServer/reload'), hasLength(1));
      kernel.setMcpServerEnabled('codex_apps', false);
      await pumpEventQueue();
      expect(codex.sent('config/value/write'), hasLength(1));

      // As the thread's servers start: failing, up.
      kernel.send(const KernelTurn(id: 't1', text: 'Hi'));
      await pumpEventQueue();
      kernel.refreshMcpServers();
      await pumpEventQueue();
      expect(kernel.mcpServers!.first.status, McpServerStatus.connected);
      codex.emit({
        'method': 'mcpServer/startupStatus/updated',
        'params': {
          'threadId': _thread,
          'name': 'fs',
          'status': 'failed',
          'error': 'handshake failed',
        },
      });
      await pumpEventQueue();
      expect(kernel.mcpServers!.first.status, McpServerStatus.failed);
      expect(kernel.mcpServers!.first.error, 'handshake failed');
      kernel.reconnectMcpServer('fs');
      codex.emit({
        'method': 'mcpServer/startupStatus/updated',
        'params': {'threadId': _thread, 'name': 'fs', 'status': 'ready'},
      });
      await pumpEventQueue();
      expect(codex.sent('config/mcpServer/reload'), hasLength(2));
      expect(kernel.mcpServers!.first.status, McpServerStatus.connected);
      expect(kernel.mcpServers!.first.error, isNull);

      expect(
        await kernel.authenticateMcpServer('codex_apps'),
        Uri.parse('https://example.com/authorize'),
      );
      expect(codex.sent('mcpServer/oauth/login').single, {
        'name': 'codex_apps',
        'threadId': _thread,
      });
    });

    test('a new session starts on what new Codex agents start on', () async {
      final codex = FakeCodex();
      final (:kernel, transcript: _, events: _) = codexKernel(
        [codex],
        context: const KernelContext(
          cwd: '/project',
          settings: {'model': 'opus', 'codex:model': 'gpt-6-luna'},
        ),
      );
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.model.selected, 'gpt-6-luna');
    });

    test('Codex asks: leave for a command, and a question', () async {
      final codex = FakeCodex();
      final (:kernel, :transcript, events: _) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Test it'));
      await pumpEventQueue();

      codex.ask(7, 'item/commandExecution/requestApproval', {
        'threadId': _thread,
        'turnId': 'st1',
        'itemId': 'c1',
        'command': '/bin/zsh -lc "flutter test"',
        'cwd': '/project',
        'reason': 'Run the tests',
      });
      await pumpEventQueue();
      final approval = transcript.pendingInteraction as ApprovalRequest;
      expect((approval.preview as CommandPreview).command, 'flutter test');
      expect(approval.reason, 'Run the tests');
      kernel
        ..answer(
          approval.id,
          const ApprovalAnswer(ApprovalDecision.allowAlways),
        )
        ..answer(approval.id, const ApprovalAnswer(ApprovalDecision.deny));
      expect(codex.answers(7), [
        {'decision': 'acceptForSession'},
      ]);

      codex.ask(8, 'item/tool/requestUserInput', {
        'threadId': _thread,
        'turnId': 'st1',
        'itemId': 'q',
        'isBlocking': true,
        'questions': [
          {
            'id': 'db',
            'header': 'Database',
            'question': 'Which one?',
            'isOther': true,
            'isSecret': false,
            'options': [
              {'label': 'SQLite', 'description': 'Local'},
            ],
          },
        ],
      });
      await pumpEventQueue();
      final question = transcript.pendingInteraction as QuestionRequest;
      expect(question.questions.single.prompt, 'Which one?');
      expect(question.questions.single.allowOther, isTrue);
      kernel.answer(
        question.id,
        const QuestionAnswer([
          ['SQLite'],
        ]),
      );
      expect(codex.answers(8), [
        {
          'answers': {
            'db': {
              'answers': ['SQLite'],
            },
          },
        },
      ]);

      // Of a thread forked from it: not this session's.
      codex.ask(9, 'item/commandExecution/requestApproval', {
        'threadId': 'other',
        'turnId': 'x',
      });
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
    });

    test('cancelled during startup: the turn is never sent', () async {
      final codex = FakeCodex();
      final started = Completer<CodexTransport>();
      final kernel = CodexKernel(
        _descriptor,
        const KernelContext(cwd: '/project'),
        start: (cwd, {environment = const {}}) => started.future,
      );
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 't1', text: 'Cancelled'));
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.starting);

      kernel.cancel();
      started.complete(codex);
      await pumpEventQueue();
      expect(codex.sent('turn/start'), isEmpty);

      kernel.send(const KernelTurn(id: 't2', text: 'Second'));
      await pumpEventQueue();
      expect(codex.sent('turn/start').single['clientUserMessageId'], 't2');
    });

    test(
      'cancelled before dispatch: the next turn does not deadlock',
      () async {
        final codex = FakeCodex();
        final (:kernel, :transcript, events: _) = codexKernel([codex]);
        kernel.prepare();
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.ready);

        kernel.send(const KernelTurn(id: 't1', text: 'Cancelled'));
        kernel.cancel();
        kernel.send(const KernelTurn(id: 't2', text: 'Second'));
        await pumpEventQueue();
        expect(codex.sent('turn/start'), hasLength(1));
        expect(codex.sent('turn/start').single['clientUserMessageId'], 't2');
        expect(transcript.activeTurn, 't2');
      },
    );

    test('sent while a turn runs: queued; stopped, the next goes once the '
        'server has stopped it', () async {
      final codex = FakeCodex();
      final (:kernel, :transcript, events: _) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't2', text: 'Second'));
      kernel.send(const KernelTurn(id: 't3', text: 'Third'));
      await pumpEventQueue();
      expect([for (final (id, _) in transcript.queued) id], ['t2', 't3']);
      expect(await kernel.cancelQueued('t3'), isTrue);

      kernel.cancel();
      await pumpEventQueue();
      final methods = [
        for (final m in codex.written)
          if (m['method'] case final String method) method,
      ];
      expect(
        methods.indexOf('turn/interrupt'),
        lessThan(methods.lastIndexOf('turn/start')),
      );
      expect(transcript.activeTurn, 't2');
      expect(codex.sent('turn/start').last['clientUserMessageId'], 't2');
      expect(shown(transcript), ['user: First', 'user: Second']);
    });

    test('queued to join the turn running: steered in, shown as Codex takes '
        'it up', () async {
      final before = QueuedMessages.current;
      QueuedMessages.current = () => QueuedMessages.duringTurn;
      addTearDown(() => QueuedMessages.current = before);
      final codex = FakeCodex();
      final (:kernel, :transcript, events: _) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't2', text: 'Also this'));
      await pumpEventQueue();
      final steer = codex.sent('turn/steer').single;
      expect(steer['expectedTurnId'], 'st1');
      expect(steer['clientUserMessageId'], 't2');
      expect([for (final (id, _) in transcript.queued) id], ['t2']);

      codex.emit({
        'method': 'item/started',
        'params': {
          'threadId': _thread,
          'turnId': 'st1',
          'item': {
            'type': 'userMessage',
            'id': 'u2',
            'clientId': 't2',
            'content': const <Object?>[],
          },
        },
      });
      await pumpEventQueue();
      expect(transcript.queued, isEmpty);
      expect(shown(transcript), ['user: First', 'user: Also this']);
    });

    test('forking before the first running turn is refused', () async {
      final codex = FakeCodex();
      final (:kernel, :transcript, events: _) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      expect(transcript.activeTurn, 't1');
      expect(kernel.canFork, isTrue);

      expect(await kernel.fork(before: 't1', title: 'Empty'), isNull);
      expect(codex.sent('thread/fork'), isEmpty);
      expect(transcript.activeTurn, 't1');
      expect(
        shown(transcript).last,
        startsWith('notice error: Could not fork:'),
      );
    });

    test('a thread resumed: its history; a message edited reverts the '
        'thread before it; forked, a thread of its own', () async {
      final codex = FakeCodex(
        history: [
          for (final (turn, user, answer) in [
            ('h1', 'One', 'Uno'),
            ('h2', 'Two', 'Dos'),
          ])
            {
              'id': turn,
              'status': 'completed',
              'items': [
                {
                  'type': 'userMessage',
                  'id': 'u-$turn',
                  'content': [
                    {'type': 'text', 'text': user},
                  ],
                },
                {
                  'type': 'commandExecution',
                  'id': 'c-$turn',
                  'command': '/bin/zsh -lc "git status"',
                  'status': 'completed',
                  'aggregatedOutput': 'clean',
                  'exitCode': 0,
                },
                {'type': 'agentMessage', 'id': 'a-$turn', 'text': answer},
              ],
            },
        ],
      );
      final (:kernel, :transcript, :events) = codexKernel(
        [codex],
        context: KernelContext(
          resume: SessionRecord(
            id: _thread,
            title: 'One',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
        ),
      );
      kernel.prepare();
      await pumpEventQueue();

      expect(codex.sent('thread/resume').single['threadId'], _thread);
      expect(shown(transcript), [
        'user: One',
        'terminal: git status → clean succeeded',
        'text: Uno',
        'user: Two',
        'terminal: git status → clean succeeded',
        'text: Dos',
      ]);
      // Kept from before: not this session's to review.
      expect(events.whereType<FileEdited>(), isEmpty);
      // On what the thread was on.
      expect(kernel.model.selected, 'gpt-6-luna');
      expect(kernel.permission.selected, 'untrusted');

      final record = await kernel.fork(before: 'u-h2', title: 'Try B');
      expect(codex.sent('thread/fork').single['lastTurnId'], 'h1');
      expect(codex.sent('thread/name/set').single, {
        'threadId': 'forked',
        'name': 'Try B',
      });
      expect(record?.id, 'forked');

      expect(await kernel.rewind(itemId: 'u-h2', index: 3, turns: 1), isTrue);
      expect(codex.sent('thread/revert').single, {
        'threadId': _thread,
        'beforeTurnId': 'h2',
      });
      expect(shown(transcript), [
        'user: One',
        'terminal: git status → clean succeeded',
        'text: Uno',
      ]);
    });

    test(
      'a long thread resumed: its last turns shown, the rest on asking',
      () async {
        final codex = FakeCodex(
          history: [
            for (var turn = 1; turn <= 12; turn++)
              {
                'id': 'h$turn',
                'status': 'completed',
                'items': [
                  {
                    'type': 'userMessage',
                    'id': 'u-h$turn',
                    'content': [
                      {'type': 'text', 'text': 'Ask $turn'},
                    ],
                  },
                  {'type': 'agentMessage', 'id': 'a-h$turn', 'text': 'Answer'},
                ],
              },
          ],
        );
        final (:kernel, :transcript, events: _) = codexKernel(
          [codex],
          context: KernelContext(
            resume: SessionRecord(
              id: _thread,
              title: 'Ask 1',
              updatedAt: DateTime(2026),
              cwd: '/project',
            ),
          ),
        );
        expect(kernel.loadingHistory, isTrue);
        kernel.prepare();
        await pumpEventQueue();

        expect(kernel.loadingHistory, isFalse);
        expect(shown(transcript).first, 'user: Ask 3');
        expect(transcript.length, 20);
        expect(kernel.hasEarlierHistory, isTrue);

        // Forked from the first shown: from the turn before it, not read yet.
        await kernel.fork(before: 'u-h3', title: 'Fork');
        expect(codex.sent('thread/fork').single['lastTurnId'], 'h2');
        expect(transcript.length, 20);

        await kernel.loadEarlier();
        expect(shown(transcript).take(3), [
          'user: Ask 1',
          'text: Answer',
          'user: Ask 2',
        ]);
        expect(transcript.length, 24);
        expect(kernel.hasEarlierHistory, isFalse);
        // Edited, an earlier one reverts the thread before its turn.
        expect(
          await kernel.rewind(itemId: 'u-h2', index: 2, turns: 11),
          isTrue,
        );
        expect(codex.sent('thread/revert').single['beforeTurnId'], 'h2');
      },
    );

    test('Codex gone mid-turn: the turn ends saying why', () async {
      final codex = FakeCodex();
      final (:kernel, :transcript, events: _) = codexKernel([codex]);
      kernel.send(const KernelTurn(id: 't1', text: 'Hi'));
      await pumpEventQueue();
      codex.emit(CodexExit.message(1, 'Error: not logged in'));
      await pumpEventQueue();
      expect(shown(transcript), [
        'user: Hi',
        'notice error: Codex stopped:\nError: not logged in',
      ]);
      expect(transcript.activeTurn, isNull);
      expect(kernel.health.status, KernelHealthStatus.failed);
    });
  });

  group('Codex catalog', () {
    test('threads by folder, titled by their name or first message', () async {
      final server = FakeCodex();
      final listed = <Map<String, Object?>>[];
      server.messages.listen((_) {});
      final catalog = CodexCatalog(
        start: (cwd, {environment = const {}}) async =>
            _ListingServer(server, listed),
      );
      final projects = await catalog.projects();
      expect([for (final p in projects) p.path], ['/a', '/b']);
      expect(
        [for (final s in projects.first.sessions) s.title],
        ['Named', 'First message'],
      );
      expect(
        projects.first.sessions.first.updatedAt.millisecondsSinceEpoch,
        1000,
      );
      // Not the threads agents spawned.
      expect(listed.single['sourceKinds'], isNot(contains('subAgent')));
    });
  });
}

/// A server with threads to list.
class _ListingServer implements CodexTransport {
  _ListingServer(this._inner, this.listed);

  final FakeCodex _inner;
  final List<Map<String, Object?>> listed;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    _inner.written.add(message);
    final id = message['id'];
    if (id == null) return;
    if (message['method'] == 'thread/list') {
      listed.add((message['params'] as Map).cast());
      Map<String, Object?> thread(String id, String cwd, String? name) => {
        'id': id,
        'cwd': cwd,
        'name': name,
        'preview': 'First  message',
        'updatedAt': 1,
        'path': '/codex/$id.jsonl',
        'ephemeral': false,
      };
      _out.add({
        'id': id,
        'result': {
          'data': [
            thread('t1', '/a', 'Named'),
            thread('t2', '/a', null),
            thread('t3', '/b', ''),
          ],
          'nextCursor': null,
        },
      });
    } else {
      _out.add({'id': id, 'result': <String, Object?>{}});
    }
  }

  @override
  void close() => _out.close();
}
