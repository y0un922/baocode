import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/widgets/chat_message_rail.dart';
import 'package:baocode/theme/app_theme.dart';

class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items);

  final List<ChatItem> items;

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];

  @override
  bool get isStreaming => false;

  @override
  bool get isUnprompted => false;

  @override
  bool get canEditMessages => false;

  @override
  ({int index, ComposerDraft draft})? get editing => null;

  @override
  set editing(({int index, ComposerDraft draft})? value) {}

  @override
  void editMessage(int index, ComposerMessage message) {}

  @override
  VoidCallback? moveToBackgroundAt(int index) => null;

  @override
  VoidCallback? stopAt(int index) => null;
}

/// [turns] questions, each answered at length.
List<ChatItem> _conversation(int turns) => [
  for (var n = 0; n < turns; n++) ...[
    UserMessageItem(text: 'Question $n\nmore of it'),
    AssistantTextItem('Answer $n.\n\n${'A long answer. ' * 120}'),
  ],
];

Future<void> _pump(
  WidgetTester tester,
  ChatFeed feed, {
  bool minimap = true,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ChatHistoryView(
          feed: feed,
          maxContentWidth: 720,
          minimap: minimap,
          messageRail: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  for (final minimap in [true, false]) {
    testWidgets('a dash a message at the right edge; over them, the list; a '
        'click on a line scrolls to its message (minimap: $minimap)', (
      tester,
    ) async {
      await _pump(tester, _Feed(_conversation(12)), minimap: minimap);
      final rail = find.byType(ChatMessageRail);
      expect(rail, findsOneWidget);
      final rect = tester.getRect(rail);
      // Right of the column (720 in the middle of 1200), off the edge.
      expect(rect.left, greaterThanOrEqualTo(960));
      expect(rect.right, lessThan(1200));
      final shown = tester.widget<ChatMessageRail>(rail);
      expect(shown.rows, [for (var n = 0; n < 12; n++) 2 * n]);
      expect(shown.labelAt(4), 'Question 2');
      expect(find.text('3. Question 2'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(rail));
      await tester.pumpAndSettle();
      expect(find.text('3. Question 2'), findsOneWidget);
      expect(find.text('12. Question 11'), findsOneWidget);

      expect(_position(tester).pixels, _position(tester).maxScrollExtent);
      await tester.tap(find.text('3. Question 2'));
      await tester.pumpAndSettle();
      expect(
        _position(tester).pixels,
        lessThan(_position(tester).maxScrollExtent / 2),
      );
      expect(find.textContaining('Answer 2.'), findsOneWidget);

      // The pointer gone, the list closes.
      await mouse.moveTo(const Offset(600, 400));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('3. Question 2'), findsNothing);
    });
  }

  testWidgets('thousands of messages: a sample of dashes, each standing for '
      'the messages at its place', (tester) async {
    await _pump(tester, _Feed(_conversation(3000)));
    final rail = find.byType(ChatMessageRail);
    expect(tester.widget<ChatMessageRail>(rail).rows, hasLength(3000));
    // A click a quarter of the way down goes to a message a quarter of the
    // way through.
    final rect = tester.getRect(
      find.descendant(of: rail, matching: find.byType(CustomPaint)),
    );
    await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height / 4));
    await tester.pumpAndSettle();
    expect(find.textContaining('Answer 750.'), findsOneWidget);
  });

  testWidgets('none with fewer than two messages', (tester) async {
    await _pump(tester, _Feed(_conversation(1)));
    expect(find.byType(ChatMessageRail), findsNothing);
  });

  test("a message's label is its first line, without a heading's marks", () {
    expect(
      ChatMessageRail.labelOf('\n\n## Fix the build\nplease'),
      'Fix the build',
    );
    expect(ChatMessageRail.labelOf('  '), '');
  });
}
