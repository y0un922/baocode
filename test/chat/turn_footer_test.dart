import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/rolling_text.dart';
import 'package:baocode/chat/widgets/turn_footer.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  test('its runs: each digit alone, what is between them together', () {
    expect(RollingText.runsOf('342.15 tok/s'), [
      '3',
      '4',
      '2',
      '.',
      '1',
      '5',
      ' tok/s',
    ]);
    expect(RollingText.runsOf('↓ 1.2k tokens'), [
      '↓ ',
      '1',
      '.',
      '2',
      'k tokens',
    ]);
  });

  testWidgets('a digit changed rolls: the old one going as the new one '
      'comes, back and forth however fast', (tester) async {
    const style = TextStyle(fontSize: 12);
    await _pump(tester, const RollingText('12', style: style));
    expect(find.text('2'), findsOneWidget);
    await _pump(tester, const RollingText('13', style: style));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // Back before it has gone: another child, no key twice.
    await _pump(tester, const RollingText('12', style: style));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    // The one unchanged never moved.
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('where motion is turned down, one text, at once', (tester) async {
    await _pump(
      tester,
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: RollingText('12 tok/s', style: TextStyle()),
      ),
    );
    expect(find.text('12 tok/s'), findsOneWidget);
  });

  testWidgets('the turn under way\'s line turned off in settings, as it '
      'changes: none at all; a finished turn\'s stays', (tester) async {
    final shown = ValueNotifier(true);
    LiveTurnStatsSetting.current = () => shown.value;
    LiveTurnStatsSetting.changes = shown;
    addTearDown(() {
      LiveTurnStatsSetting.current = () => true;
      LiveTurnStatsSetting.changes = null;
    });

    await _pump(
      tester,
      TurnFooter(
        live: const TurnOutput(tokens: 1234, tokensPerSecond: 42),
        since: DateTime.now().subtract(const Duration(seconds: 3)),
      ),
    );
    expect(find.byType(RollingText), findsNWidgets(3));

    shown.value = false;
    await tester.pump();
    expect(find.byType(RollingText), findsNothing);
    expect(tester.getSize(find.byType(TurnFooter)), Size.zero);

    shown.value = true;
    await tester.pump();
    expect(find.byType(RollingText), findsNWidgets(3));

    shown.value = false;
    await _pump(
      tester,
      const TurnFooter(
        worked: Duration(seconds: 12),
        usage: TurnUsage(outputTokens: 234, tokensPerSecond: 50),
      ),
    );
    expect(find.text('12s'), findsOneWidget);
    expect(find.text('50.00 tok/s'), findsOneWidget);
  });

  testWidgets('TPS waits for usage, then shows even on a short turn', (
    tester,
  ) async {
    await _pump(tester, const TurnFooter(live: TurnOutput(tokens: 30)));
    expect(find.byType(RollingText), findsOneWidget);

    await _pump(
      tester,
      const TurnFooter(live: TurnOutput(tokens: 30, tokensPerSecond: 150)),
    );
    expect(find.byType(RollingText), findsNWidgets(2));

    await _pump(
      tester,
      const TurnFooter(
        worked: Duration(milliseconds: 200),
        usage: TurnUsage(outputTokens: 30, tokensPerSecond: 150),
      ),
    );
    expect(find.text('150.00 tok/s'), findsOneWidget);
  });

  test('when a turn ended: the time today, the day before', () {
    final now = DateTime(2026, 10, 21, 18);
    expect(
      TurnFooter.formatEnded(DateTime(2026, 10, 21, 9, 5, 7), now: now),
      '09:05',
    );
    expect(
      TurnFooter.formatEnded(
        DateTime(2026, 10, 21, 9, 5, 7),
        now: now,
        seconds: true,
      ),
      '09:05:07',
    );
    expect(
      TurnFooter.formatEnded(DateTime(2026, 10, 20, 23, 59), now: now),
      '10-20 23:59',
    );
    expect(
      TurnFooter.formatEnded(DateTime(2025, 12, 31, 8, 0), now: now),
      '2025-12-31 08:00',
    );
  });

  test('a turn that ends is kept with when it ended', () {
    final transcript = Transcript()
      ..apply(const TurnStarted(1, 'u1'))
      ..apply(const ItemUpserted(2, 'u1', UserMessageItem(text: 'hi')));
    final before = DateTime.now();
    transcript.apply(const TurnEnded(3, 'u1', worked: Duration(seconds: 3)));
    final message = transcript.itemAt(0) as UserMessageItem;
    expect(message.worked, const Duration(seconds: 3));
    expect(message.endedAt!.isBefore(before), isFalse);
  });

  testWidgets('a finished turn says when it ended, last', (tester) async {
    final ended = DateTime.now();
    await _pump(
      tester,
      TurnFooter(worked: const Duration(seconds: 12), endedAt: ended),
    );
    final text = 'ended ${TurnFooter.formatEnded(ended)}';
    expect(find.text(text), findsOneWidget);
    expect(
      tester.getRect(find.text('12s')).right,
      lessThan(tester.getRect(find.text(text)).left),
    );
  });

  testWidgets('a finished turn\'s time comes first, its tokens last', (
    tester,
  ) async {
    await _pump(
      tester,
      const TurnFooter(
        answer: 'Done.',
        worked: Duration(seconds: 12),
        usage: TurnUsage(
          inputTokens: 1000,
          outputTokens: 234,
          costUsd: 0.42,
          tokensPerSecond: 50,
        ),
      ),
    );
    final tokens = tester.getRect(find.text('1.23k tokens'));
    final rects = [
      for (final text in ['12s', '50.00 tok/s', r'$0.42'])
        tester.getRect(find.text(text)),
      tokens,
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i - 1].right, lessThan(rects[i].left));
    }
  });
}
