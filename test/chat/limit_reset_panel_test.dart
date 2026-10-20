import 'package:baocode/chat/panels/limit_reset_panel.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    required DateTime resetsAt,
    bool scheduled = false,
    Locale locale = const Locale('en'),
  }) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 640,
              child: LimitResetPanel(
                resetsAt: resetsAt,
                scheduled: scheduled,
                onSchedule: () => calls.add('schedule'),
                onUnschedule: () => calls.add('unschedule'),
                onDecline: () => calls.add('decline'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return calls;
  }

  /// A time later today, [minutes] from now (clamped before midnight).
  DateTime laterToday() {
    final now = DateTime.now();
    final at = now.add(const Duration(minutes: 30));
    return at.day == now.day
        ? at
        : DateTime(now.year, now.month, now.day, 23, 59, 59);
  }

  String clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  testWidgets('says when the limit resets, and asks to go on then', (
    tester,
  ) async {
    final at = laterToday();
    final calls = await pump(tester, resetsAt: at);
    expect(
      find.text('Usage limit reached · resets ${clock(at)}'),
      findsOneWidget,
    );
    expect(
      find.text('Continue this task automatically once it resets?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue After Reset'));
    await tester.tap(find.text('Cancel'));
    expect(calls, ['schedule', 'decline']);
    // Gone as the limit resets: no timer left behind.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scheduled, says so, and is undone', (tester) async {
    final at = laterToday();
    final calls = await pump(tester, resetsAt: at, scheduled: true);
    expect(
      find.text('Continues automatically after the reset at ${clock(at)}'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Undo'));
    expect(calls, ['unschedule']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in Chinese', (tester) async {
    final at = laterToday();
    await pump(tester, resetsAt: at, locale: const Locale('zh'));
    expect(find.text('已达到用量上限，${clock(at)} 重置'), findsOneWidget);
    expect(find.text('重置后继续'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('goes as the limit resets', (tester) async {
    await pump(
      tester,
      resetsAt: DateTime.now().add(const Duration(milliseconds: 300)),
    );
    expect(find.text('Continue After Reset'), findsOneWidget);
    // The clock read is the real one: past it, then the timer.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Continue After Reset'), findsNothing);
  });

  test('the reset time: today, tomorrow, or with its date', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final now = DateTime(2026, 10, 13, 14, 2);
    expect(resetTime(DateTime(2026, 10, 13, 16, 30), l10n, now: now), '16:30');
    expect(
      resetTime(DateTime(2026, 10, 14, 3, 50), l10n, now: now),
      'tomorrow 03:50',
    );
    expect(resetTime(DateTime(2026, 10, 16, 9), l10n, now: now), '10/16 09:00');
  });
}
