import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/panels/limit_reset_panel.dart';
import 'package:baocode/chat/resume_after_reset.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/settings/pages/models_page.dart';
import 'package:baocode/settings/settings_dialog.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

const _gateway = ModelProvider(
  id: 'gw',
  name: 'Gateway',
  protocol: ProviderProtocol.openaiChat,
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModel(id: 'gpt-5', contextWindow: 400000)],
);

/// The error Claude Code answers with at the limit.
Map<String, Object?> _limitError(String text) => {
  'type': 'assistant',
  'error': 'rate_limit',
  'parent_tool_use_id': null,
  'message': {
    'id': 'msg-limit',
    'role': 'assistant',
    'model': '<synthetic>',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  late ResumeAfterReset resumes;
  late IdeNotifications notifications;
  late List<SettingsSection> opened;

  setUp(() {
    final before = ResumeAfterReset.current;
    resumes = ResumeAfterReset.current = ResumeAfterReset();
    notifications = IdeNotifications();
    opened = [];
    addTearDown(() {
      ResumeAfterReset.current = before;
      ResumeAfterResetSetting.current = () => false;
      resumes.dispose();
      notifications.dispose();
    });
  });

  /// A Claude Code session on a CLI the test speaks for, its session
  /// named, a message sent; on [settings]' model.
  Future<({ChatSession session, FakeCli cli})> pumpSession(
    WidgetTester tester, {
    Map<String, String> settings = const {},
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cli = FakeCli();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async => cli,
        providers: ModelProviders.memory(providers: [_gateway]),
        providerEnvironment: (provider, model) async => {
          'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
        },
      ),
    );
    final session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      kernelContext: KernelContext(cwd: '/tmp/project', settings: settings),
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: SettingsOpener(
          open: opened.add,
          child: IdeNotificationsScope(
            notifications: notifications,
            child: ChatScreen(title: 'Fix the tests', session: session),
          ),
        ),
      ),
    );
    await tester.pump();
    session.send(const ComposerMessage(text: 'fix the tests'));
    await tester.pump(const Duration(milliseconds: 100));
    cli.push({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'session-1',
      'cwd': '/tmp/project',
    });
    await tester.pump(const Duration(milliseconds: 100));
    return (session: session, cli: cli);
  }

  /// The turn ends at the limit, which resets in an hour.
  Future<DateTime> hitLimit(WidgetTester tester, FakeCli cli) async {
    final at = DateTime.now().add(const Duration(hours: 1));
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    cli
      ..push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'rejected',
          'resetsAt': seconds,
          'rateLimitType': 'five_hour',
        },
      })
      ..push(_limitError("You've hit your session limit · resets 11pm"))
      ..push({
        'type': 'result',
        'subtype': 'success',
        'is_error': true,
        'result': "You've hit your session limit · resets 11pm",
      });
    await tester.pump(const Duration(milliseconds: 100));
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  testWidgets('usage limit: asked above the composer, it is scheduled', (
    tester,
  ) async {
    final (:session, :cli) = await pumpSession(tester);
    expect(find.byType(LimitResetPanel), findsNothing);
    final at = await hitLimit(tester, cli);
    expect(session.usageLimitResetsAt, at);
    expect(find.byType(LimitResetPanel), findsOneWidget);
    expect(find.text('Continue After Reset'), findsOneWidget);

    await tester.tap(find.text('Continue After Reset'));
    await tester.pump();
    expect(resumes['session-1']!.scheduled, isTrue);
    expect(resumes['session-1']!.title, 'Fix the tests');
    expect(find.textContaining('Continues automatically'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(resumes['session-1']!.state, ResumeState.declined);
    await tester.pumpWidget(const SizedBox());
    // Its timer: listed till the limit resets.
    resumes.dispose();
  });

  testWidgets('usage limit: declined, it says where to turn it on', (
    tester,
  ) async {
    final (session: _, :cli) = await pumpSession(tester);
    await hitLimit(tester, cli);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byType(LimitResetPanel), findsNothing);
    expect(resumes['session-1']!.state, ResumeState.declined);
    final note = notifications.notifications.single;
    expect(note.message, contains('Settings → Models → Claude Code'));
    expect(note.primary.single.label, 'Open Settings');
    note.primary.single.run();
    expect(opened, [SettingsSection.models]);
    expect(ModelsSettingsPage.reveal.value, builtinProviderId);
    ModelsSettingsPage.reveal.value = null;
    await tester.pumpWidget(const SizedBox());
    resumes.dispose();
  });

  testWidgets('usage limit: set to go on unasked, it is scheduled at once', (
    tester,
  ) async {
    ResumeAfterResetSetting.current = () => true;
    final (session: _, :cli) = await pumpSession(tester);
    await hitLimit(tester, cli);
    // The workspace hits it; here, the screen does as it is answered.
    resumes.hit(
      sessionId: 'session-1',
      title: 'Fix the tests',
      project: 'project',
      resetsAt: DateTime.now().add(const Duration(hours: 1)),
    );
    await tester.pump();
    expect(find.textContaining('Continues automatically'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('usage limit: only warned, nothing is asked', (tester) async {
    final (session: _, :cli) = await pumpSession(tester);
    cli
      ..push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'allowed_warning',
          'resetsAt': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          'rateLimitType': 'five_hour',
          'utilization': 0.9,
        },
      })
      ..push({'type': 'result', 'subtype': 'success', 'is_error': false});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('usage limit: on a provider, not asked', (tester) async {
    final (:session, :cli) = await pumpSession(
      tester,
      settings: {'model': '@gw/gpt-5'},
    );
    await hitLimit(tester, cli);
    expect(session.usageLimitResetsAt, isNull);
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
