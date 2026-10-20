import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/output_meter.dart';

void main() {
  late DateTime now;
  late OutputMeter meter;

  setUp(() {
    now = DateTime(2026);
    meter = OutputMeter(clock: () => now)..begin();
  });

  void after(int ms) => now = now.add(Duration(milliseconds: ms));

  test('estimates the displayed count, not the speed', () {
    expect(OutputMeter.estimateTokens('a' * 30), 10);
    expect(OutputMeter.estimateTokens('秋天' * 5), closeTo(13, 1e-9));
    after(2000);
    meter.streamed('a' * 3000);
    expect(meter.output.tokens, 1000);
    expect(meter.output.tokensPerSecond, isNull);
    expect(meter.averageSpeed, isNull);
  });

  test('actual output over full request time, including first-token wait', () {
    after(12000);
    meter.streamed('a' * 300);
    after(8000);
    meter.endMessage(tokens: 1000);
    expect(meter.output.tokens, 1000);
    expect(meter.output.tokensPerSecond, 50);
    expect(meter.averageSpeed, 50);
  });

  test('all actual output counts, including reasoning and tool inputs', () {
    after(4000);
    meter.streamed('a short thought');
    after(1000);
    meter.streamed('tiny visible answer');
    meter.endMessage(tokens: 1000);
    expect(meter.output.tokens, 1000);
    expect(meter.averageSpeed, 200);
  });

  test('prefers the SDK request duration over delayed event delivery', () {
    after(60000);
    meter.endMessage(tokens: 1000, duration: const Duration(seconds: 20));
    expect(meter.averageSpeed, 50);
    after(60000);
    meter.endMessage(tokens: 500, duration: const Duration(seconds: 10));
    expect(meter.output.tokens, 1500);
    expect(meter.averageSpeed, 50);
  });

  test('an invalid SDK duration does not fall back to a made-up speed', () {
    after(2000);
    meter.endMessage(tokens: 100, duration: Duration.zero);
    expect(meter.averageSpeed, isNull);
    after(2000);
    meter.endMessage(tokens: 100, duration: const Duration(seconds: -1));
    expect(meter.averageSpeed, isNull);
  });

  test('a buffered response needs no deltas to measure its actual usage', () {
    after(2000);
    meter.endMessage(tokens: 300);
    expect(meter.output.tokens, 300);
    expect(meter.averageSpeed, 150);
  });

  test('counts a burst instead of dropping its first 50 milliseconds', () {
    meter.streamed('a' * 3000);
    after(10);
    meter.streamed('a' * 3000);
    after(1990);
    meter.endMessage(tokens: 2000);
    expect(meter.averageSpeed, 1000);
  });

  test('does not hide a valid response shorter than one second', () {
    after(200);
    meter.endMessage(tokens: 30);
    expect(meter.averageSpeed, 150);
  });

  test('includes time between the last delta and the completed usage', () {
    after(1000);
    meter.streamed('abc');
    after(3000);
    meter.endMessage(tokens: 200);
    expect(meter.averageSpeed, 50);
  });

  test('excludes tool execution even if usage arrives after the tool', () {
    after(2000);
    meter.pause();
    after(120000);
    meter.resume();
    after(1000);
    meter.endMessage(tokens: 300);
    expect(meter.averageSpeed, 100);
  });

  test('sums matched tokens and request durations across a turn', () {
    after(500);
    meter.endMessage(tokens: 50);
    meter.pause();
    after(30000);
    meter.resume();
    after(1500);
    meter.endMessage(tokens: 75);
    expect(meter.output.tokens, 125);
    expect(meter.averageSpeed, 62.5);
  });

  test('usage received while tools run does not restart the clock', () {
    after(1000);
    meter.pause();
    after(10000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, 100);
    after(10000);
    meter.resume();
    after(1000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, 100);
  });

  test('pause and resume are idempotent', () {
    after(1000);
    meter.pause();
    after(10000);
    meter.pause();
    after(10000);
    meter.resume();
    after(1000);
    meter.resume();
    after(1000);
    meter.endMessage(tokens: 300);
    expect(meter.averageSpeed, 100);
  });

  test('keeps the completed speed while the next request is pending', () {
    after(1000);
    meter.endMessage(tokens: 100);
    after(5000);
    meter.streamed('a' * 30);
    expect(meter.output.tokens, 110);
    expect(meter.output.tokensPerSecond, 100);
    meter.pause();
    after(60000);
    expect(meter.averageSpeed, 100);
  });

  test('missing usage can keep a count but never invents a speed', () {
    after(5000);
    meter.streamed('a' * 300);
    meter.endMessage();
    expect(meter.output.tokens, 100);
    expect(meter.averageSpeed, isNull);
    after(1000);
    meter.endMessage(tokens: 50);
    expect(meter.output.tokens, 150);
    expect(meter.averageSpeed, 50);
  });

  test('zero output keeps its request time; negative usage is ignored', () {
    after(1000);
    meter.endMessage(tokens: 0);
    expect(meter.averageSpeed, isNull);
    after(1000);
    meter.endMessage(tokens: -10);
    expect(meter.output.tokens, 0);
    expect(meter.averageSpeed, isNull);
    after(1000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, 50);
  });

  test('an empty request still contributes to the turn total duration', () {
    after(10000);
    meter.endMessage(tokens: 0);
    expect(meter.averageSpeed, isNull);
    after(1000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, closeTo(100 / 11, 1e-9));
  });

  test('zero or negative elapsed time cannot contribute a speed', () {
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, isNull);
    after(-1000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, isNull);
    after(1000);
    meter.endMessage(tokens: 50);
    expect(meter.output.tokens, 250);
    expect(meter.averageSpeed, 50);
  });

  test('a new turn clears counts, speed, pauses and elapsed time', () {
    after(1000);
    meter.endMessage(tokens: 100);
    meter.pause();
    after(30000);
    meter.begin();
    expect(meter.output.tokens, 0);
    expect(meter.averageSpeed, isNull);
    after(2000);
    meter.endMessage(tokens: 100);
    expect(meter.averageSpeed, 50);
  });
}
