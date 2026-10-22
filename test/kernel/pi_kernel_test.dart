import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/pi/pi_catalog.dart';
import 'package:baocode/kernel/pi/pi_kernel.dart';
import 'package:baocode/kernel/pi/pi_transport.dart';
import 'package:baocode/kernel/queued_messages.dart';
import 'package:baocode/kernel/transcript.dart';

/// A turn pi 1.3.0 ran in RPC mode (recorded in `/project`, its system
/// prompt and extension statuses left out).
List<Map<String, Object?>> recordedTurn() => [
  for (final line in File('test/fixtures/pi/turn.jsonl').readAsLinesSync())
    if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast(),
];

const _flash = {
  'id': 'cline-pass/deepseek-v4.1-flash',
  'name': 'DeepSeek Flash',
  'provider': 'cline',
  'reasoning': true,
  'thinkingLevelMap': {'minimal': null, 'medium': null, 'max': 'max'},
  'contextWindow': 100000,
};

const _gpt = {
  'id': 'gpt-x',
  'name': 'GPT X',
  'provider': 'openai-codex',
  'reasoning': true,
  'thinkingLevelMap': {'off': null, 'minimal': 'low', 'xhigh': 'xhigh'},
  'contextWindow': 400000,
};

const _claude = {
  'id': 'claude-x',
  'name': 'Claude X',
  'provider': 'anthropic',
  'reasoning': false,
  'contextWindow': 200000,
};

/// pi as the tests speak it: answers commands the way it does, plays
/// [turn] after a prompt, and records what the kernel wrote.
class FakePi implements PiTransport {
  FakePi({
    this.turn = const [],
    this.history = const [],
    this.sessionFile = '/sessions/s1.jsonl',
  });

  final List<Map<String, Object?>> turn;
  final List<Map<String, Object?>> history;
  final String sessionFile;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();
  final List<Map<String, Object?>> written = [];
  final Completer<void> _exited = Completer();

  /// The commands written, by type.
  List<Map<String, Object?>> sent(String type) =>
      written.where((m) => m['type'] == type).toList();

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final type = message['type'] as String;
    if (type == 'extension_ui_response') return;
    final data = switch (type) {
      'get_state' => {
        'sessionId': 's1',
        'sessionFile': sessionFile,
        'model': _flash,
        'thinkingLevel': 'medium',
      },
      'get_available_models' => {
        'models': [_flash, _claude, _gpt],
      },
      'get_commands' => {
        'commands': [
          {'name': 'skill:review', 'description': 'Review', 'source': 'skill'},
        ],
      },
      'get_session_stats' => {
        'cost': 0.25,
        'contextUsage': {'tokens': 1234, 'contextWindow': 100000},
      },
      'get_messages' => {'messages': history},
      'prompt' => {'disposition': 'started'},
      'steer' => {'disposition': 'queued'},
      'clear_queue' => {'steering': const [], 'followUp': const []},
      _ => null,
    };
    // The run it stops ends before it answers.
    if (type == 'abort') emit({'type': 'agent_settled', 'aborted': true});
    emit({
      'id': message['id'],
      'type': 'response',
      'command': type,
      'success': true,
      'data': ?data,
    });
    if (type == 'prompt') turn.forEach(emit);
  }

  void emit(Map<String, Object?> message) => _out.add(message);

  /// The process ends, having printed [stderr].
  void exit(int code, String stderr) {
    emit(PiExit.message(code, stderr));
    unawaited(_out.close());
    _exited.complete();
  }

  @override
  void close() {
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  Future<void> get exited => _exited.future;
}

final _descriptor = KernelDescriptor(
  id: 'pi',
  label: 'pi',
  icon: Icons.pie_chart_outline_rounded,
  description: '',
  create: (_) => throw UnimplementedError(),
);

/// A kernel on the fakes [pis] (one each start), its events applied to a
/// transcript; what it was started with in [starts].
({
  PiKernel kernel,
  Transcript transcript,
  List<KernelEvent> events,
  List<({String cwd, String? session})> starts,
})
piKernel(
  List<FakePi> pis, {
  KernelContext context = const KernelContext(cwd: '/project'),
}) {
  final starts = <({String cwd, String? session})>[];
  final kernel = PiKernel(
    _descriptor,
    context,
    start: (cwd, {session, environment = const {}}) async {
      starts.add((cwd: cwd, session: session));
      return pis[starts.length - 1];
    },
  );
  final transcript = Transcript();
  final events = <KernelEvent>[];
  kernel.events.listen((event) {
    events.add(event);
    transcript.apply(event);
  });
  return (
    kernel: kernel,
    transcript: transcript,
    events: events,
    starts: starts,
  );
}

/// What the history shows, one line an item; thoughts left out.
List<String> shown(Transcript transcript) => [
  for (var i = 0; i < transcript.length; i++)
    switch (transcript.itemAt(i)) {
      UserMessageItem(:final text) => 'user: $text',
      AssistantTextItem(:final text) => 'text: ${text.split('\n').first}',
      ThinkingItem() => '',
      ToolCallItem(:final kind, :final label, :final target, :final status) =>
        'tool: ${label ?? kind.name} $target ${status.name}',
      TerminalItem(:final command, :final output, :final status) =>
        'terminal: $command → ${output.trim()} ${status.name}',
      CodeDiffItem(:final path, :final added, :final removed) =>
        'diff: $path +$added -$removed',
      NoticeItem(:final kind, :final text) => 'notice ${kind.name}: $text',
      final other => '$other',
    },
].where((line) => line.isNotEmpty).toList();

void main() {
  group('pi adapter', () {
    test('a recorded turn: a command, a read, an edit to review', () async {
      final pi = FakePi(turn: recordedTurn());
      final (:kernel, :transcript, :events, starts: _) = piKernel([pi]);
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 't1', text: 'Edit a.txt'));
      await pumpEventQueue();

      expect(shown(transcript), [
        'user: Edit a.txt',
        "text: I'll start by listing the directory contents.",
        'terminal: ls → a.txt succeeded',
        'text: Reading a.txt before editing.',
        'tool: read a.txt succeeded',
        'diff: /project/a.txt +1 -1',
        'text: done',
      ]);
      expect(pi.sent('prompt').single['message'], 'Edit a.txt');

      // Thought, without the colors an extension gave it.
      final thoughts = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case ThinkingItem(:final text)) text,
      ];
      expect(thoughts, isNotEmpty);
      expect(thoughts.any((text) => text.contains('\x1B')), isFalse);
      expect(transcript.hasStreamingItem, isFalse);

      // The edit is pending review, undone by its own patch.
      final edit = events.whereType<FileEdited>().single;
      expect(edit.change.path, '/project/a.txt');
      expect((edit.change.added, edit.change.removed), (1, 1));
      expect(edit.turnId, 't1');
      expect(
        (edit.original as OriginalByPatch).diff,
        contains('-line two\n+line 2'),
      );

      final ended = events.whereType<TurnEnded>().single;
      expect(ended.interrupted, isFalse);
      expect(ended.usage?.outputTokens, 211);
      // pi's full request durations: 3799 + 1973 + 3591 + 2062 ms.
      expect(ended.usage?.tokensPerSecond, closeTo(211 / 11.425, 1e-9));
      expect(
        events.whereType<OutputReported>().last.output.tokensPerSecond,
        closeTo(211 / 11.425, 1e-9),
      );
      expect(transcript.activeTurn, isNull);
      expect(transcript.usage?.used, 1234);
      expect(transcript.stats?.costUsd, 0.25);
      expect(kernel.sessionId, 's1');
    });

    for (final (thought, reasoning) in [
      (true, 80),
      (false, 80),
      (true, null),
      (false, null),
    ]) {
      test(
        'actual TPS includes reasoning: thought=$thought, reasoning=$reasoning',
        () async {
          final pi = FakePi();
          final (:kernel, transcript: _, :events, starts: _) = piKernel([pi]);
          addTearDown(kernel.dispose);
          kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
          await pumpEventQueue();

          void startMessage() => pi.emit({
            'type': 'message_start',
            'message': {'role': 'assistant'},
          });
          void text() {
            pi.emit({
              'type': 'message_update',
              'assistantMessageEvent': {
                'type': 'text_start',
                'contentIndex': 0,
              },
            });
            pi.emit({
              'type': 'message_update',
              'assistantMessageEvent': {
                'type': 'text_delta',
                'contentIndex': 0,
                'delta': 'a' * 300,
              },
            });
          }

          startMessage();
          text();
          await pumpEventQueue();
          expect(
            events.whereType<OutputReported>().last.output.tokensPerSecond,
            isNull,
          );
          pi.emit({
            'type': 'message_end',
            'message': {
              'role': 'assistant',
              'durationMs': 250,
              'content': [
                if (thought) {'type': 'thinking', 'thinking': 'A summary'},
              ],
              'usage': {'output': 100, 'reasoning': ?reasoning},
            },
          });
          await pumpEventQueue();
          startMessage();
          text();
          pi.emit({
            'type': 'message_end',
            'message': {
              'role': 'assistant',
              'content': [],
              'durationMs': 10000,
            },
          });
          pi.emit({'type': 'agent_settled', 'aborted': false});
          await pumpEventQueue();
          final output = events.whereType<OutputReported>().last.output;
          expect(output.tokens, 200);
          // Unknown usage can estimate count, but cannot change TPS.
          expect(output.tokensPerSecond, 400);
          expect(
            events.whereType<TurnEnded>().single.usage?.tokensPerSecond,
            400,
          );
        },
      );
    }

    for (final usage in [
      null,
      {'input': 10, 'reasoning': 80},
    ]) {
      test('missing output usage never supplies TPS: $usage', () async {
        final pi = FakePi();
        final (:kernel, transcript: _, :events, starts: _) = piKernel([pi]);
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
        await pumpEventQueue();
        pi
          ..emit({
            'type': 'message_start',
            'message': {'role': 'assistant'},
          })
          ..emit({
            'type': 'message_update',
            'assistantMessageEvent': {'type': 'text_start', 'contentIndex': 0},
          })
          ..emit({
            'type': 'message_update',
            'assistantMessageEvent': {
              'type': 'text_delta',
              'contentIndex': 0,
              'delta': 'a' * 300,
            },
          })
          ..emit({
            'type': 'message_end',
            'message': {
              'role': 'assistant',
              'durationMs': 250,
              'usage': ?usage,
            },
          });
        await pumpEventQueue();
        final output = events.whereType<OutputReported>().last.output;
        expect(output.tokens, 100);
        expect(output.tokensPerSecond, isNull);
        kernel.cancel();
        await pumpEventQueue();
        expect(
          events.whereType<TurnEnded>().single.usage?.tokensPerSecond,
          isNull,
        );
      });
    }

    for (final duration in [0, -1, double.nan, double.infinity, '250']) {
      test('invalid supplied duration never supplies TPS: $duration', () async {
        final pi = FakePi(
          turn: [
            {'type': 'turn_start'},
            {
              'type': 'message_end',
              'message': {
                'role': 'assistant',
                'durationMs': duration,
                'usage': {'output': 100},
              },
            },
            {'type': 'agent_settled', 'aborted': false},
          ],
        );
        final (:kernel, transcript: _, :events, starts: _) = piKernel([pi]);
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
        await pumpEventQueue();
        final output = events.whereType<OutputReported>().last.output;
        expect(output.tokens, 100);
        expect(output.tokensPerSecond, isNull);
        final usage = events.whereType<TurnEnded>().single.usage;
        expect(usage?.outputTokens, 100);
        expect(usage?.tokensPerSecond, isNull);
      });
    }

    test('older pi fallback includes TTFT, not tools or compaction', () async {
      final pi = FakePi();
      final (:kernel, transcript: _, :events, starts: _) = piKernel([pi]);
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 't1', text: 'Hello'));
      await pumpEventQueue();
      final requestTime = Stopwatch()..start();
      // No turn_start on the first request: prompt dispatch starts timing.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      pi
        ..emit({
          'type': 'message_start',
          'message': {'role': 'assistant'},
        })
        ..emit({
          'type': 'message_end',
          'message': {
            'role': 'assistant',
            'usage': {'output': 100},
          },
        });
      await pumpEventQueue();
      requestTime.stop();
      expect(
        events.whereType<OutputReported>().last.output.tokensPerSecond,
        closeTo(100 / (requestTime.elapsedMicroseconds / 1e6), 300),
      );

      pi.emit({
        'type': 'tool_execution_start',
        'toolCallId': 'c1',
        'toolName': 'bash',
        'args': {'command': 'slow tool'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 180));
      pi
        ..emit({
          'type': 'tool_execution_end',
          'toolCallId': 'c1',
          'toolName': 'bash',
        })
        ..emit({'type': 'turn_start'})
        ..emit({'type': 'compaction_start'});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      pi
        ..emit({'type': 'compaction_end'})
        ..emit({'type': 'turn_start'});
      requestTime.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      pi
        ..emit({
          'type': 'message_start',
          'message': {'role': 'assistant'},
        })
        ..emit({
          'type': 'message_end',
          'message': {
            'role': 'assistant',
            'usage': {'output': 100},
          },
        })
        ..emit({'type': 'agent_settled', 'aborted': false});
      await pumpEventQueue();
      requestTime.stop();
      expect(
        events.whereType<TurnEnded>().single.usage?.tokensPerSecond,
        closeTo(200 / (requestTime.elapsedMicroseconds / 1e6), 300),
      );
    });

    test('models by provider; a pick tells pi which', () async {
      final pi = FakePi();
      final (:kernel, transcript: _, events: _, starts: _) = piKernel([pi]);
      kernel.prepare();
      await pumpEventQueue();

      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(
        [for (final o in kernel.model.options) o.id],
        [
          'cline/cline-pass/deepseek-v4.1-flash',
          'anthropic/claude-x',
          'openai-codex/gpt-x',
        ],
      );
      expect(kernel.model.selected, 'cline/cline-pass/deepseek-v4.1-flash');
      expect(kernel.contextWindow, 100000);
      // Each model's levels as pi works them out; none for a model that
      // does not think.
      List<String> levels(String model) => [
        for (final o in kernel.effort.optionsFor(model)) o.id,
      ];
      expect(levels(kernel.model.selected!), ['off', 'low', 'high', 'max']);
      expect(levels('openai-codex/gpt-x'), [
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(kernel.effort.optionsFor('anthropic/claude-x'), isEmpty);
      expect(kernel.effort.selected, 'medium');
      // A level a model does not take: the nearest it does, higher first.
      expect(kernel.effort.selectedFor(kernel.model.selected!), 'high');
      expect(kernel.effort.selectedFor('openai-codex/gpt-x'), 'medium');
      expect(
        [for (final c in kernel.commands) c.name],
        ['compact', 'skill:review'],
      );

      kernel.model.select('anthropic/claude-x');
      await pumpEventQueue();
      expect(
        pi.sent('set_model').single,
        containsPair('provider', 'anthropic'),
      );
      expect(pi.sent('set_model').single, containsPair('modelId', 'claude-x'));

      kernel.effort.select('anthropic/claude-x', 'off');
      await pumpEventQueue();
      expect(pi.sent('set_thinking_level').single['level'], 'off');
    });

    test('a new session starts on what new pi agents start on, not on '
        'what Claude Code ones do', () async {
      final pi = FakePi();
      final (:kernel, transcript: _, events: _, starts: _) = piKernel(
        [pi],
        context: const KernelContext(
          cwd: '/project',
          settings: {
            'model': 'opus',
            'effort': 'none',
            'pi:model': 'anthropic/claude-x',
            'pi:effort': 'high',
          },
        ),
      );
      expect(kernel.model.selected, 'anthropic/claude-x');
      kernel.prepare();
      await pumpEventQueue();
      expect(pi.sent('set_model').single['modelId'], 'claude-x');
      expect(pi.sent('set_thinking_level').single['level'], 'high');
      expect(kernel.model.selected, 'anthropic/claude-x');
    });

    test('an extension asks: a question, its answer back to pi', () async {
      final pi = FakePi();
      final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
      kernel.prepare();
      await pumpEventQueue();
      pi.emit({
        'type': 'extension_ui_request',
        'id': 'u1',
        'method': 'confirm',
        'title': 'Allow?',
        'message': 'Run rm -rf build?',
      });
      await pumpEventQueue();
      final request = transcript.pendingInteraction as QuestionRequest;
      expect(request.questions.single.prompt, 'Run rm -rf build?');
      expect(
        [for (final o in request.questions.single.options) o.label],
        ['Yes', 'No'],
      );

      kernel.answer(
        request.id,
        const QuestionAnswer([
          ['Yes'],
        ]),
      );
      expect(pi.written.last, {
        'type': 'extension_ui_response',
        'id': 'u1',
        'confirmed': true,
      });
      expect(transcript.pendingInteraction, isNull);

      // Free text: typed in.
      pi.emit({
        'type': 'extension_ui_request',
        'id': 'u2',
        'method': 'input',
        'title': 'Name?',
        'placeholder': 'a name',
      });
      await pumpEventQueue();
      final input = transcript.pendingInteraction as QuestionRequest;
      expect(input.questions.single.options, isEmpty);
      expect(input.questions.single.allowOther, isTrue);
      expect(input.questions.single.otherLabel, 'a name');
      kernel.answer(
        input.id,
        const QuestionAnswer([
          ['Ada'],
        ]),
      );
      expect(pi.written.last, {
        'type': 'extension_ui_response',
        'id': 'u2',
        'value': 'Ada',
      });
    });

    group('pi plugin UI', () {
      const questions = [
        {
          'question': 'Which layout?',
          'header': 'Layout',
          'options': [
            {
              'label': 'Compact',
              'description': 'Less space',
              'preview': 'A | B',
            },
            {'label': 'Wide', 'description': 'More space'},
          ],
        },
        {
          'question': 'Which features?',
          'header': 'Features',
          'multiSelect': true,
          'options': [
            {'label': 'Search', 'description': 'Find things'},
            {'label': 'History', 'description': 'Keep things'},
          ],
        },
        {
          'question': 'What name?',
          'header': 'Name',
          'options': [
            {'label': 'Alpha', 'description': 'First'},
            {'label': 'Beta', 'description': 'Second'},
          ],
        },
      ];
      const tasks = [
        {'id': 1, 'subject': 'Read code', 'status': 'completed'},
        {
          'id': 2,
          'subject': 'Align UI',
          'activeForm': 'Aligning UI',
          'status': 'in_progress',
        },
        {'id': 3, 'subject': 'Run tests', 'status': 'pending'},
        {'id': 4, 'subject': 'Removed task', 'status': 'deleted'},
      ];

      void startTool(
        FakePi pi,
        String id,
        String name,
        Map<String, Object?> args,
      ) => pi.emit({
        'type': 'tool_execution_start',
        'toolCallId': id,
        'toolName': name,
        'args': args,
      });

      void dialog(FakePi pi, String id, String method, String title) =>
          pi.emit({
            'type': 'extension_ui_request',
            'id': id,
            'method': method,
            'title': title,
            if (method == 'select') 'options': ['An RPC option'],
          });

      test('todo snapshots feed the shared task panel, including clear and '
          'custom entries from nested calls', () async {
        final pi = FakePi();
        final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 't1', text: 'Work'));
        await pumpEventQueue();

        startTool(pi, 'todo1', 'todo', {'action': 'list'});
        pi.emit({
          'type': 'tool_execution_end',
          'toolCallId': 'todo1',
          'toolName': 'todo',
          'isError': false,
          'result': {
            'content': [
              {'type': 'text', 'text': 'Tasks'},
            ],
            'details': {'tasks': tasks},
          },
        });
        await pumpEventQueue();
        expect(transcript.todos.map((todo) => todo.content), [
          'Read code',
          'Align UI',
          'Run tests',
        ]);
        expect(transcript.todos.map((todo) => todo.status), [
          TodoStatus.completed,
          TodoStatus.inProgress,
          TodoStatus.pending,
        ]);
        expect(transcript.todos[1].activeForm, 'Aligning UI');
        expect((transcript.itemAt(1) as ToolCallItem).kind, ToolKind.todo);

        // A failed tool without a snapshot must not erase the task list.
        startTool(pi, 'todo2', 'todo', {'action': 'update', 'id': 99});
        pi.emit({
          'type': 'tool_execution_end',
          'toolCallId': 'todo2',
          'toolName': 'todo',
          'isError': true,
          'result': {
            'content': [
              {'type': 'text', 'text': 'No such task'},
            ],
          },
        });
        await pumpEventQueue();
        expect(transcript.todos, hasLength(3));
        final failed = transcript.itemAt(2) as ToolCallItem;
        expect(failed.status, ToolStatus.failed);
        expect(failed.output, 'No such task');

        pi.emit({
          'type': 'entry_appended',
          'entry': {
            'type': 'custom',
            'customType': 'rpiv-todo-state',
            'data': {'tasks': const []},
          },
        });
        await pumpEventQueue();
        expect(transcript.todos, isEmpty);
      });

      test(
        'full questionnaire keeps descriptions, previews and multiple '
        'selection; answers drive subsequent RPC dialogs invisibly',
        () async {
          final pi = FakePi();
          final (:kernel, :transcript, :events, starts: _) = piKernel([pi]);
          addTearDown(kernel.dispose);
          kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
          await pumpEventQueue();
          startTool(pi, 'ask1', 'ask_user_question', {'questions': questions});
          dialog(
            pi,
            'q1',
            'select',
            '[Layout] Which layout?\n\n--- 1. Compact preview ---\nA | B',
          );
          await pumpEventQueue();

          final request = transcript.pendingInteraction as QuestionRequest;
          expect(request.questions, hasLength(3));
          expect(request.questions.first.prompt, 'Which layout?');
          expect(request.questions.first.header, 'Layout');
          expect(
            request.questions.first.options.first.description,
            'Less space',
          );
          expect(request.questions.first.options.first.preview, 'A | B');
          expect(request.questions[1].allowMultiple, isTrue);
          expect(request.questions.every((q) => q.allowOther), isTrue);
          final tool = transcript.itemAt(1) as ToolCallItem;
          expect(tool.kind, ToolKind.question);
          expect(tool.target, 'Layout · Features · Name');

          kernel.answer(
            request.id,
            const QuestionAnswer([
              ['Compact'],
              ['Search', 'History', 'Custom; text'],
              ['My project'],
            ]),
          );
          expect(pi.sent('extension_ui_response').last, {
            'type': 'extension_ui_response',
            'id': 'q1',
            'value': 'Compact',
          });
          expect(transcript.pendingInteraction, isNull);

          dialog(pi, 'q2', 'input', '[Features] Which features?\n\n1. Search');
          dialog(pi, 'q3', 'select', '[Name] What name?');
          await pumpEventQueue();
          expect(pi.sent('extension_ui_response').map((m) => m['value']), [
            'Compact',
            '1,2; Custom; text',
            'My project',
          ]);
          expect(events.whereType<InteractionRequested>(), hasLength(1));
          expect(transcript.pendingInteraction, isNull);
        },
      );

      test('normalizes question text the same way as the plugin', () async {
        final pi = FakePi();
        final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
        await pumpEventQueue();
        startTool(pi, 'ask1', 'ask_user_question', {
          'questions': [
            {
              'question': 'Which\r\nlayout?',
              'header': 'Lay\rout',
              'options': [
                {'label': 'Com\rpact', 'description': 'Less\r\nspace'},
                {'label': 'Wide', 'description': 'More space'},
              ],
            },
          ],
        });
        dialog(pi, 'q1', 'select', '[Layout] Which\nlayout?');
        await pumpEventQueue();
        final request = transcript.pendingInteraction as QuestionRequest;
        expect(request.questions.single.options.first.label, 'Compact');
        expect(
          request.questions.single.options.first.description,
          'Less\nspace',
        );
        kernel.answer(
          request.id,
          const QuestionAnswer([
            ['Compact'],
          ]),
        );
        expect(pi.sent('extension_ui_response').single['value'], 'Compact');
      });

      test('unvalidated tool arguments do not break the transcript', () async {
        final pi = FakePi();
        final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
        await pumpEventQueue();
        for (final (id, args) in [
          ('ask1', {'questions': 'invalid'}),
          (
            'ask2',
            {
              'questions': [
                {'question': 'Which?', 'options': 123},
              ],
            },
          ),
        ]) {
          // pi emits tool_execution_start before validating its arguments.
          startTool(pi, id, 'ask_user_question', args);
          pi.emit({
            'type': 'tool_execution_end',
            'toolCallId': id,
            'toolName': 'ask_user_question',
            'isError': true,
            'result': {
              'content': [
                {'type': 'text', 'text': 'Invalid tool arguments'},
              ],
            },
          });
        }
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isNull);
        expect(transcript.length, 3);
        expect(
          (transcript.itemAt(2) as ToolCallItem).status,
          ToolStatus.failed,
        );
      });

      test(
        'multi-select first and numeric custom text remain structured',
        () async {
          final pi = FakePi();
          final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
          addTearDown(kernel.dispose);
          kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
          await pumpEventQueue();
          startTool(pi, 'ask1', 'ask_user_question', {
            'questions': [questions[1]],
          });
          dialog(pi, 'q1', 'input', '[Features] Which features?\n\n1. Search');
          await pumpEventQueue();
          final request = transcript.pendingInteraction as QuestionRequest;
          expect(request.questions.single.allowMultiple, isTrue);
          kernel.answer(
            request.id,
            const QuestionAnswer([
              ['1,2; not option numbers'],
            ]),
          );
          expect(
            pi.sent('extension_ui_response').single['value'],
            '; 1,2; not option numbers',
          );
        },
      );

      test(
        'skipping cancels the plugin and a later call gets fresh answers',
        () async {
          final pi = FakePi();
          final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
          addTearDown(kernel.dispose);
          kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
          await pumpEventQueue();
          startTool(pi, 'ask1', 'ask_user_question', {'questions': questions});
          dialog(pi, 'q1', 'select', '[Layout] Which layout?');
          await pumpEventQueue();
          kernel.answer(
            transcript.pendingInteraction!.id,
            const QuestionAnswer([], skipped: true),
          );
          expect(pi.sent('extension_ui_response').single, {
            'type': 'extension_ui_response',
            'id': 'q1',
            'cancelled': true,
          });
          pi.emit({
            'type': 'tool_execution_end',
            'toolCallId': 'ask1',
            'toolName': 'ask_user_question',
            'isError': false,
            'result': {'content': const []},
          });
          startTool(pi, 'ask2', 'ask_user_question', {'questions': questions});
          dialog(pi, 'q2', 'select', '[Layout] Which layout?');
          await pumpEventQueue();
          expect(transcript.pendingInteraction, isA<QuestionRequest>());
          expect(pi.sent('extension_ui_response'), hasLength(1));

          // A tool ending unexpectedly dismisses its still-open panel.
          pi.emit({
            'type': 'tool_execution_end',
            'toolCallId': 'ask2',
            'toolName': 'ask_user_question',
            'isError': true,
            'result': {'content': const []},
          });
          await pumpEventQueue();
          expect(transcript.pendingInteraction, isNull);
        },
      );

      test(
        'other extension dialogs are not replaced by the questionnaire',
        () async {
          final pi = FakePi();
          final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
          addTearDown(kernel.dispose);
          kernel.send(const KernelTurn(id: 't1', text: 'Ask'));
          await pumpEventQueue();
          startTool(pi, 'ask1', 'ask_user_question', {'questions': questions});
          dialog(pi, 'other', 'select', 'Another extension');
          await pumpEventQueue();
          final other = transcript.pendingInteraction as QuestionRequest;
          expect(other.questions.single.prompt, 'Another extension');
          expect(other.questions.single.allowOther, isFalse);
          kernel.answer(
            other.id,
            const QuestionAnswer([
              ['An RPC option'],
            ]),
          );
          dialog(pi, 'q1', 'select', '[Layout] Which layout?');
          await pumpEventQueue();
          expect(
            (transcript.pendingInteraction as QuestionRequest).questions,
            hasLength(3),
          );
          kernel.cancel();
          dialog(
            pi,
            'late',
            'input',
            '[Features] Which features?\n\n1. Search',
          );
          await pumpEventQueue();
          expect(transcript.pendingInteraction, isNull);
          expect(pi.sent('extension_ui_response').skip(1), [
            {'type': 'extension_ui_response', 'id': 'q1', 'cancelled': true},
            {'type': 'extension_ui_response', 'id': 'late', 'cancelled': true},
          ]);
        },
      );

      test('todo history restores the last snapshot outside the visible page '
          'and loading older calls cannot roll it back', () async {
        final pi = FakePi(
          history: [
            for (var i = 0; i < 25; i++) ...[
              {'role': 'user', 'content': 'Turn $i'},
              if (i < 2) ...[
                {
                  'role': 'assistant',
                  'content': [
                    {
                      'type': 'toolCall',
                      'id': 'todo$i',
                      'name': 'todo',
                      'arguments': {'action': 'list'},
                    },
                  ],
                },
                {
                  'role': 'toolResult',
                  'toolCallId': 'todo$i',
                  'toolName': 'todo',
                  'content': const [],
                  'details': {'tasks': tasks.take(i + 1).toList()},
                },
              ],
            ],
            {
              'role': 'toolResult',
              'toolCallId': 'invalid',
              'toolName': 'todo',
              'isError': true,
              'content': const [],
            },
          ],
        );
        final (:kernel, :transcript, events: _, starts: _) = piKernel(
          [pi],
          context: KernelContext(
            resume: SessionRecord(
              id: 's0',
              title: 'Old',
              updatedAt: DateTime(2026),
              cwd: '/project',
              path: '/missing/session.jsonl',
            ),
          ),
        );
        addTearDown(kernel.dispose);
        kernel.prepare();
        await pumpEventQueue();
        expect(transcript.todos.map((t) => t.content), [
          'Read code',
          'Align UI',
        ]);
        expect(kernel.hasEarlierHistory, isTrue);
        await kernel.loadEarlier();
        expect(transcript.todos.map((t) => t.content), [
          'Read code',
          'Align UI',
        ]);
      });

      test(
        'custom todo snapshots follow the saved branch and rewind',
        () async {
          final dir = Directory.systemTemp.createTempSync('pi_todos_');
          addTearDown(() => dir.deleteSync(recursive: true));
          final file = File('${dir.path}/s1.jsonl')
            ..writeAsStringSync(
              [
                {'type': 'session', 'id': 's1', 'cwd': '/project'},
                {
                  'type': 'message',
                  'id': 'u1',
                  'parentId': null,
                  'message': {'role': 'user', 'content': 'First'},
                },
                {
                  'type': 'custom',
                  'id': 's1',
                  'parentId': 'u1',
                  'customType': 'rpiv-todo-state',
                  'data': {
                    'tasks': [tasks.first],
                  },
                },
                {
                  'type': 'message',
                  'id': 'u2',
                  'parentId': 's1',
                  'message': {'role': 'user', 'content': 'Second'},
                },
                {
                  'type': 'custom',
                  'id': 'abandoned',
                  'parentId': 'u2',
                  'customType': 'rpiv-todo-state',
                  'data': {'tasks': const []},
                },
                {
                  'type': 'custom',
                  'id': 'current',
                  'parentId': 'u2',
                  'customType': 'rpiv-todo-state',
                  'data': {'tasks': tasks},
                },
              ].map(jsonEncode).join('\n'),
            );
          final (:kernel, :transcript, events: _, :starts) = piKernel(
            [FakePi(sessionFile: file.path)],
            context: KernelContext(
              resume: SessionRecord(
                id: 's1',
                title: 'First',
                updatedAt: DateTime(2026),
                cwd: '/project',
                path: file.path,
              ),
            ),
          );
          addTearDown(kernel.dispose);
          for (var i = 0; i < 100 && kernel.loadingHistory; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(starts, isEmpty);
          expect(transcript.todos, hasLength(3));
          expect(shown(transcript), ['user: First', 'user: Second']);
          expect(
            await kernel.rewind(itemId: 'pi:history:2', index: 1, turns: 1),
            isTrue,
          );
          expect(transcript.todos.map((t) => t.content), ['Read code']);
          expect(
            await kernel.rewind(itemId: 'pi:history:0', index: 0, turns: 1),
            isTrue,
          );
          expect(transcript.todos, isEmpty);
        },
      );
    });

    test('pi gone mid-turn: the turn ends saying why; restarted, it goes '
        'on with the session', () async {
      final first = FakePi();
      final second = FakePi();
      final (:kernel, :transcript, events: _, :starts) = piKernel([
        first,
        second,
      ]);
      kernel.send(const KernelTurn(id: 't1', text: 'Hi'));
      await pumpEventQueue();
      first.exit(1, 'Error: \x1B[31mno API key\x1B[39m');
      await pumpEventQueue();

      expect(shown(transcript), [
        'user: Hi',
        'notice error: pi stopped:\nError: no API key',
      ]);
      expect(transcript.activeTurn, isNull);
      expect(kernel.health.status, KernelHealthStatus.failed);

      kernel.restart();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(starts.last, (cwd: '/project', session: '/sessions/s1.jsonl'));
    });

    test('a session resumed shows what pi kept of it', () async {
      final pi = FakePi(
        history: [
          {'role': 'user', 'content': 'Fix a.txt'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'thinking', 'thinking': '\x1B[2mEasy.\x1B[22m'},
              {'type': 'text', 'text': 'Fixing it.'},
              {
                'type': 'toolCall',
                'id': 'c1',
                'name': 'edit',
                'arguments': {'path': 'a.txt'},
              },
            ],
          },
          {
            'role': 'toolResult',
            'toolCallId': 'c1',
            'toolName': 'edit',
            'content': [
              {'type': 'text', 'text': 'Done'},
            ],
            'details': {
              'patch': '--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n',
            },
            'isError': false,
          },
          {
            'role': 'bashExecution',
            'command': 'git status',
            'output': 'clean',
            'exitCode': 0,
          },
        ],
      );
      final (:kernel, :transcript, :events, :starts) = piKernel(
        [pi],
        context: KernelContext(
          resume: SessionRecord(
            id: 's0',
            title: 'Fix a.txt',
            updatedAt: DateTime(2026),
            cwd: '/project',
            path: '/sessions/s0.jsonl',
          ),
        ),
      );
      kernel.prepare();
      await pumpEventQueue();

      expect(starts.single, (cwd: '/project', session: '/sessions/s0.jsonl'));
      expect(shown(transcript), [
        'user: Fix a.txt',
        'text: Fixing it.',
        'diff: /project/a.txt +1 -1',
        'terminal: git status → clean succeeded',
      ]);
      // Kept from before: not this session's to review.
      expect(events.whereType<FileEdited>(), isEmpty);
    });

    test('a session resumed: its branch read from its file, before pi has '
        'started', () async {
      final dir = Directory.systemTemp.createTempSync('pi_history_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Map<String, Object?> message(
        String id,
        String? parent,
        String role,
        String text,
      ) => {
        'type': 'message',
        'id': id,
        'parentId': parent,
        'message': {
          'role': role,
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      };
      final file = File('${dir.path}/s0.jsonl')
        ..writeAsStringSync(
          [
            {'type': 'session', 'id': 's0', 'cwd': '/project'},
            message('a', null, 'user', 'First'),
            message('b', 'a', 'assistant', 'One'),
            {'type': 'compaction', 'id': 'c', 'parentId': 'b'},
            message('d', 'c', 'user', 'Abandoned'),
            // Gone back to before it: the branch pi goes on with.
            {'type': 'custom', 'id': 'e', 'parentId': 'c'},
            message('f', 'e', 'user', 'Second'),
          ].map(jsonEncode).join('\n'),
        );
      final pi = FakePi();
      final (:kernel, :transcript, events: _, :starts) = piKernel(
        [pi],
        context: KernelContext(
          resume: SessionRecord(
            id: 's0',
            title: 'First',
            updatedAt: DateTime(2026),
            cwd: '/project',
            path: file.path,
          ),
        ),
      );
      for (var i = 0; i < 100 && transcript.length == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(starts, isEmpty);
      expect(shown(transcript), [
        'user: First',
        'text: One',
        'notice compaction: Conversation compacted',
        'user: Second',
      ]);

      kernel.prepare();
      await pumpEventQueue();
      expect(starts, hasLength(1));
      expect(pi.sent('get_messages'), isEmpty);
      expect(transcript.length, 4);
    });

    test('a long session resumed: its last turns shown, the rest on '
        'asking; any of them to go back to', () async {
      final dir = Directory.systemTemp.createTempSync('pi_history_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/s0.jsonl')
        ..writeAsStringSync(
          [
            {'type': 'session', 'id': 's0', 'cwd': '/project'},
            for (var turn = 0; turn < 25; turn++) ...[
              {
                'type': 'message',
                'id': 'u$turn',
                'parentId': turn == 0 ? null : 'a${turn - 1}',
                'message': {'role': 'user', 'content': 'Ask $turn'},
              },
              {
                'type': 'message',
                'id': 'a$turn',
                'parentId': 'u$turn',
                'message': {
                  'role': 'assistant',
                  'content': [
                    {'type': 'text', 'text': 'Answer'},
                  ],
                },
              },
            ],
          ].map((entry) => '${jsonEncode(entry)}\n').join(),
        );
      final (:kernel, :transcript, events: _, starts: _) = piKernel(
        [FakePi(sessionFile: file.path)],
        context: KernelContext(
          resume: SessionRecord(
            id: 's0',
            title: 'Ask 0',
            updatedAt: DateTime(2026),
            cwd: '/project',
            path: file.path,
          ),
        ),
      );
      expect(kernel.loadingHistory, isTrue);
      for (var i = 0; i < 100 && transcript.length == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(kernel.loadingHistory, isFalse);
      expect(shown(transcript).first, 'user: Ask 15');
      expect(transcript.length, 20);
      expect(kernel.hasEarlierHistory, isTrue);

      await kernel.loadEarlier();
      expect(shown(transcript).take(2), ['user: Ask 0', 'text: Answer']);
      expect(transcript.length, 50);
      expect(kernel.hasEarlierHistory, isFalse);

      // The first: pi goes on from before it.
      expect(
        await kernel.rewind(itemId: 'pi:history:0', index: 0, turns: 25),
        isTrue,
      );
      final branch = jsonDecode(file.readAsLinesSync().last) as Map;
      expect(branch['data'], {'before': 'u0'});
    });

    test('/compact is pi’s own command, not a prompt', () async {
      final pi = FakePi();
      final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
      kernel.send(const KernelTurn(id: 't1', text: '/compact keep the tests'));
      await pumpEventQueue();
      expect(pi.sent('prompt'), isEmpty);
      expect(pi.sent('compact').single['customInstructions'], 'keep the tests');
      expect(transcript.activeTurn, isNull);
    });

    test('models show their makers\' logos; providers their APIs\'', () async {
      final pi = FakePi();
      final (:kernel, transcript: _, events: _, starts: _) = piKernel([pi]);
      kernel.prepare();
      await pumpEventQueue();
      for (final option in kernel.model.options) {
        expect(option.iconBuilder, isNotNull, reason: option.id);
        expect(option.group?.iconBuilder, isNotNull, reason: option.id);
      }
    });

    test('sent while a turn runs: queued, taken up once it ends', () async {
      final pi = FakePi();
      final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't2', text: 'Second'));
      kernel.send(const KernelTurn(id: 't3', text: 'Third'));
      await pumpEventQueue();
      expect([for (final (id, _) in transcript.queued) id], ['t2', 't3']);
      expect(pi.sent('prompt'), hasLength(1));

      // Taken back, it is not sent.
      expect(await kernel.cancelQueued('t3'), isTrue);
      pi.emit({'type': 'agent_settled', 'aborted': false});
      await pumpEventQueue();
      expect(transcript.queued, isEmpty);
      expect(transcript.activeTurn, 't2');
      expect(
        [for (final m in pi.sent('prompt')) m['message']],
        ['First', 'Second'],
      );
      expect(shown(transcript), ['user: First', 'user: Second']);
    });

    test('cancelled during startup: the prompt is never sent', () async {
      final pi = FakePi();
      final started = Completer<PiTransport>();
      final kernel = PiKernel(
        _descriptor,
        const KernelContext(cwd: '/project'),
        start: (cwd, {session, environment = const {}}) => started.future,
      );
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 't1', text: 'Cancelled'));
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.starting);

      kernel.cancel();
      started.complete(pi);
      await pumpEventQueue();
      expect(pi.sent('prompt'), isEmpty);
      expect(kernel.canFork, isFalse);

      kernel.send(const KernelTurn(id: 't2', text: 'Second'));
      await pumpEventQueue();
      expect(pi.sent('prompt').single['message'], 'Second');
    });

    test('stopped, the run it stopped does not end the next turn', () async {
      final pi = FakePi();
      final (:kernel, :transcript, events: _, starts: _) = piKernel([pi]);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      kernel.cancel();
      kernel.send(const KernelTurn(id: 't2', text: 'Second'));
      await pumpEventQueue();
      // pi told of the second only once it stopped the first.
      final types = [for (final m in pi.written) m['type']];
      expect(types.indexOf('abort'), lessThan(types.lastIndexOf('prompt')));
      expect(transcript.activeTurn, 't2');

      // Sent now: the turn running stops for it.
      kernel.send(const KernelTurn(id: 't3', text: 'Third', now: true));
      await pumpEventQueue();
      expect(transcript.activeTurn, 't3');
      expect(pi.sent('prompt').last['message'], 'Third');
    });

    test('queued to join the turn running: steered in, shown as pi takes '
        'it up', () async {
      final before = QueuedMessages.current;
      QueuedMessages.current = () => QueuedMessages.duringTurn;
      addTearDown(() => QueuedMessages.current = before);
      final pi = FakePi();
      final (:kernel, :transcript, :events, starts: _) = piKernel([pi]);
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 't1', text: 'First'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't2', text: 'Also this'));
      await pumpEventQueue();
      expect(pi.sent('steer').single['message'], 'Also this');
      expect([for (final (id, _) in transcript.queued) id], ['t2']);

      pi
        ..emit({
          'type': 'message_start',
          'message': {'role': 'assistant'},
        })
        ..emit({
          'type': 'message_end',
          'message': {
            'role': 'assistant',
            'durationMs': 200,
            'usage': {'output': 20},
          },
        })
        ..emit({'type': 'turn_start'})
        ..emit({
          'type': 'message_start',
          'message': {'role': 'user', 'content': 'Also this'},
        })
        ..emit({
          'type': 'message_start',
          'message': {'role': 'assistant'},
        })
        ..emit({
          'type': 'message_end',
          'message': {
            'role': 'assistant',
            'durationMs': 400,
            'usage': {'output': 40},
          },
        });
      await pumpEventQueue();
      expect(transcript.queued, isEmpty);
      expect(shown(transcript), ['user: First', 'user: Also this']);
      expect(transcript.activeTurn, 't1');

      // Cancelling a new, partially streamed request cannot fabricate usage.
      pi
        ..emit({'type': 'turn_start'})
        ..emit({
          'type': 'message_start',
          'message': {'role': 'assistant'},
        })
        ..emit({
          'type': 'message_update',
          'assistantMessageEvent': {'type': 'text_start', 'contentIndex': 0},
        })
        ..emit({
          'type': 'message_update',
          'assistantMessageEvent': {
            'type': 'text_delta',
            'contentIndex': 0,
            'delta': 'unfinished',
          },
        });
      await pumpEventQueue();
      kernel.cancel();
      await pumpEventQueue();
      final ended = events.whereType<TurnEnded>().single;
      expect(ended.interrupted, isTrue);
      expect(ended.usage?.outputTokens, 60);
      expect(ended.usage?.tokensPerSecond, 100);
    });

    group('in its session', () {
      late Directory dir;
      late File file;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('pi_session_');
        file = File('${dir.path}/2026_s1.jsonl')
          ..writeAsStringSync(
            [
              {
                'type': 'session',
                'version': 3,
                'id': 's1',
                'timestamp': '2026-01-01T00:00:00.000Z',
                'cwd': '/project',
              },
              for (final (id, parent, role, text) in [
                ('e1', null, 'user', 'First'),
                ('e2', 'e1', 'assistant', 'One'),
                ('e3', 'e2', 'user', 'Second'),
                ('e4', 'e3', 'assistant', 'Two'),
              ])
                {
                  'type': 'message',
                  'id': id,
                  'parentId': parent,
                  'timestamp': '2026-01-01T00:00:00.000Z',
                  'message': {'role': role, 'content': text},
                },
              '',
            ].map((line) => line == '' ? '' : jsonEncode(line)).join('\n'),
          );
      });
      tearDown(() => dir.deleteSync(recursive: true));

      List<Map<String, Object?>> entries(File file) => [
        for (final line in file.readAsLinesSync().skip(1))
          if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast(),
      ];

      Future<
        ({
          PiKernel kernel,
          Transcript transcript,
          List<FakePi> pis,
          List starts,
        })
      >
      twoTurns() async {
        final pis = [
          FakePi(sessionFile: file.path),
          FakePi(sessionFile: file.path),
        ];
        final (:kernel, :transcript, events: _, :starts) = piKernel(pis);
        for (final (id, text) in [('t1', 'First'), ('t2', 'Second')]) {
          kernel.send(KernelTurn(id: id, text: text));
          await pumpEventQueue();
          pis.first.emit({'type': 'agent_settled', 'aborted': false});
          await pumpEventQueue();
        }
        return (
          kernel: kernel,
          transcript: transcript,
          pis: pis,
          starts: starts,
        );
      }

      test('a message edited: pi goes on from before it, in the same '
          'session', () async {
        final (:kernel, :transcript, :pis, :starts) = await twoTurns();
        expect(await kernel.rewind(itemId: 't2', index: 1, turns: 1), isTrue);
        expect(shown(transcript), ['user: First']);
        // The last entry, where pi goes on from: after the first answer.
        expect(entries(file).last, containsPair('parentId', 'e2'));
        expect(kernel.sessionId, 's1');

        kernel.send(const KernelTurn(id: 't3', text: 'Second, again'));
        await pumpEventQueue();
        expect(starts.last, (cwd: '/project', session: file.path));
        expect(pis.last.sent('prompt').single['message'], 'Second, again');
      });

      test('forked: a session of its own, without the turn running', () async {
        final (:kernel, transcript: _, pis: _, starts: _) = await twoTurns();
        expect(kernel.canFork, isTrue);
        final record = await kernel.fork(before: 't2', title: 'Try B');
        expect(record, isNotNull);
        expect(record!.id, isNot('s1'));
        final copy = File(record.path!);
        final header = jsonDecode(copy.readAsLinesSync().first) as Map;
        expect(header['id'], record.id);
        expect(header['parentSession'], file.path);
        // Named, and on from before the second message.
        final copied = entries(copy);
        expect(copied.last, containsPair('name', 'Try B'));
        final branch = copied[copied.length - 2];
        expect(branch['parentId'], 'e2');
        expect(copied.last['parentId'], branch['id']);
        final listed = await PiCatalog(sessionsDir: dir.path)
            .sessionsIn('/project');
        expect(listed.firstWhere((s) => s.id == record.id).title, 'Try B');
        // The session forked from is as it was.
        expect(entries(file), hasLength(4));
      });
    });
  });

  group('pi catalog', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('pi-sessions'));
    tearDown(() => dir.deleteSync(recursive: true));

    File session(String folder, String id, String cwd, List<Object> entries) {
      final file = File('${dir.path}/$folder/2026_$id.jsonl')
        ..createSync(recursive: true);
      file.writeAsStringSync(
        [
          {'type': 'session', 'version': 3, 'id': id, 'cwd': cwd},
          ...entries,
        ].map(jsonEncode).join('\n'),
      );
      return file;
    }

    test('sessions by folder, titled by their name or first message', () async {
      session('--a--', 'one', '/a', [
        {
          'type': 'message',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Fix the\n  build'},
            ],
          },
        },
      ]);
      session('--a--', 'two', '/a', [
        {
          'type': 'message',
          'message': {'role': 'user', 'content': 'Hello'},
        },
        {'type': 'session_info', 'name': 'Refactor auth'},
      ]);
      session('--b--', 'three', '/b', []);
      File('${dir.path}/--b--/notes.jsonl').writeAsStringSync('not json');

      final catalog = PiCatalog(sessionsDir: dir.path);
      final projects = {
        for (final project in await catalog.projects())
          project.path: {
            for (final session in project.sessions) session.id: session.title,
          },
      };
      expect(projects, {
        '/a': {'one': 'Fix the build', 'two': 'Refactor auth'},
        '/b': {'three': ''},
      });

      await catalog.delete('one');
      expect([for (final s in await catalog.sessionsIn('/a')) s.id], ['two']);
    });
  });
}
