import 'package:baocode/chat/resume_after_reset.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The scheduler's clock, moved on with the test's timers (see [elapse]).
  late DateTime now;

  setUp(() => now = _start);
  tearDown(() => ResumeAfterResetSetting.current = () => false);

  ResumeAfterReset make({PreferenceStore? store}) {
    final resumes = ResumeAfterReset(store: store, clock: () => now);
    addTearDown(resumes.dispose);
    return resumes;
  }

  Future<void> elapse(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
    // What a timer started, done.
    await tester.pump();
  }

  void hit(ResumeAfterReset resumes, String id, {Duration after = _hour}) =>
      resumes.hit(
        sessionId: id,
        title: 'Fix the tests',
        project: 'baocode',
        resetsAt: _start.add(after),
      );

  testWidgets('a limit hit is offered, and goes on only once said to', (
    tester,
  ) async {
    final resumed = <String>[];
    final resumes = make()
      ..resume = (id) async {
        resumed.add(id);
        return true;
      };
    hit(resumes, 'a');
    expect(resumes['a']!.state, ResumeState.offered);
    await elapse(tester, const Duration(hours: 2));
    expect(resumed, isEmpty);

    hit(resumes, 'b', after: const Duration(hours: 3));
    resumes.setScheduled('b', true);
    await elapse(tester, const Duration(minutes: 59, seconds: 59));
    expect(resumed, isEmpty);
    // A minute after the reset.
    await elapse(tester, const Duration(minutes: 1, seconds: 1));
    expect(resumed, ['b']);
    expect(resumes['b'], isNull);
  });

  test('set to go on unasked, a limit hit is scheduled', () {
    ResumeAfterResetSetting.current = () => true;
    final resumes = make();
    hit(resumes, 'a');
    expect(resumes['a']!.state, ResumeState.scheduled);
  });

  test('declined, it stays declined at a new time; and is turned on', () {
    final resumes = make();
    hit(resumes, 'a');
    resumes.setScheduled('a', false);
    hit(resumes, 'a', after: const Duration(hours: 2));
    expect(resumes['a']!.state, ResumeState.declined);
    expect(resumes['a']!.resetsAt, _start.add(const Duration(hours: 2)));
    resumes.setScheduled('a', true);
    expect(resumes['a']!.scheduled, isTrue);
  });

  testWidgets('not continued, it is tried again, then let go', (tester) async {
    var tries = 0;
    final resumes = make()
      ..resume = (id) async {
        tries++;
        return false;
      };
    hit(resumes, 'a');
    resumes.setScheduled('a', true);
    await elapse(tester, const Duration(hours: 1, minutes: 1));
    expect(tries, 1);
    await elapse(tester, const Duration(minutes: 1));
    expect(tries, 2);
    for (var i = 0; i < 10; i++) {
      await elapse(tester, const Duration(minutes: 1));
    }
    expect(tries, resumes.attempts);
    expect(resumes['a'], isNull);
  });

  testWidgets('waits for the workspace to continue them', (tester) async {
    final resumed = <String>[];
    final resumes = make();
    hit(resumes, 'a');
    resumes.setScheduled('a', true);
    await elapse(tester, const Duration(hours: 2));
    resumes.resume = (id) async {
      resumed.add(id);
      return true;
    };
    await elapse(tester, Duration.zero);
    expect(resumed, ['a']);
  });

  testWidgets('kept between runs: one due meanwhile goes on, past ones '
      'turned down go', (tester) async {
    final store = MemoryPreferenceStore();
    final before = make(store: store);
    hit(before, 'declined');
    before.setScheduled('declined', false);
    hit(before, 'later', after: const Duration(hours: 5));
    before.setScheduled('later', false);
    hit(before, 'due');
    before.setScheduled('due', true);
    await tester.pump();

    now = now.add(const Duration(hours: 2));
    final resumed = <String>[];
    final after = make(store: store);
    await after.load();
    expect(
      [for (final entry in after.entries) entry.sessionId],
      ['due', 'later'],
    );
    expect(after['due']!.title, 'Fix the tests');
    after.resume = (id) async {
      resumed.add(id);
      return true;
    };
    await elapse(tester, Duration.zero);
    expect(resumed, ['due']);
    // Their timers (the one still listed lets go as it resets), gone.
    before.dispose();
    after.dispose();
  });

  test('one set to go on takes along those not answered, and those '
      'hitting the limit after; not those turned down', () {
    final resumes = make();
    hit(resumes, 'a');
    hit(resumes, 'b');
    hit(resumes, 'no');
    resumes
      ..setScheduled('no', false)
      ..setScheduled('a', true);
    expect(resumes['b']!.scheduled, isTrue);
    expect(resumes['no']!.state, ResumeState.declined);
    hit(resumes, 'c', after: const Duration(hours: 3));
    expect(resumes['c']!.scheduled, isTrue);
  });

  testWidgets('not to go on, it is no longer listed once its limit resets', (
    tester,
  ) async {
    final resumes = make();
    var told = 0;
    resumes.addListener(() => told++);
    hit(resumes, 'a');
    hit(resumes, 'b', after: const Duration(hours: 2));
    resumes.setScheduled('b', false);
    told = 0;
    await elapse(tester, _hour);
    expect([for (final entry in resumes.entries) entry.sessionId], ['b']);
    expect(told, greaterThan(0));
    await elapse(tester, _hour);
    expect(resumes.entries, isEmpty);
  });

  test('a reset said that is past is nothing to wait for', () {
    final resumes = make();
    hit(resumes, 'a', after: -_hour);
    expect(resumes['a'], isNull);
  });

  testWidgets('removed, it does not go on', (tester) async {
    final resumed = <String>[];
    final resumes = make()
      ..resume = (id) async {
        resumed.add(id);
        return true;
      };
    hit(resumes, 'a');
    resumes
      ..setScheduled('a', true)
      ..remove('a');
    await elapse(tester, const Duration(hours: 2));
    expect(resumed, isEmpty);
  });
}

final _start = DateTime(2026, 10, 13, 14);
const _hour = Duration(hours: 1);
