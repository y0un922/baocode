import '../chat/chat_models.dart';

/// Actual output tokens over complete request time, including waiting and
/// thinking. Local tool execution is paused out; completed requests are summed.
/// Streamed text estimates the token count only, never the speed.
class OutputMeter {
  OutputMeter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static double estimateTokens(String text) {
    var ascii = 0;
    var other = 0;
    for (final rune in text.runes) {
      rune < 0x80 ? ascii++ : other++;
    }
    return ascii / 3 + other * 1.3;
  }

  int _counted = 0;
  double _guessed = 0;
  int _ratedTokens = 0;
  Duration _ratedTime = Duration.zero;
  Duration _elapsed = Duration.zero;
  DateTime? _started;
  bool _paused = false;

  /// A turn begins, before the first request is sent.
  void begin() {
    _counted = _ratedTokens = 0;
    _guessed = 0;
    _ratedTime = _elapsed = Duration.zero;
    _paused = false;
    _started = _clock();
  }

  /// Pause for tools; overlapping tools must all finish before [resume].
  void pause() {
    if (_paused) return;
    if (_started case final started?) {
      _elapsed += _clock().difference(started);
    }
    _started = null;
    _paused = true;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _started = _clock();
  }

  void streamed(String text) => _guessed += estimateTokens(text);

  /// Commits a request's usage and starts timing the next. Prefer the SDK's
  /// request [duration] when supplied; missing usage cannot contribute a speed.
  void endMessage({int? tokens, Duration? duration}) {
    final now = _clock();
    final elapsed =
        duration ??
        _elapsed +
            switch (_started) {
              final started? => now.difference(started),
              null => Duration.zero,
            };
    _counted += tokens != null && tokens >= 0 ? tokens : _guessed.round();
    if (tokens != null && tokens >= 0 && elapsed > Duration.zero) {
      _ratedTokens += tokens;
      _ratedTime += elapsed;
    }
    _guessed = 0;
    _elapsed = Duration.zero;
    _started = _paused ? null : now;
  }

  TurnOutput get output => TurnOutput(
    tokens: _counted + _guessed.round(),
    tokensPerSecond: averageSpeed,
  );

  double? get averageSpeed => _ratedTokens > 0 && _ratedTime > Duration.zero
      ? _ratedTokens * 1e6 / _ratedTime.inMicroseconds
      : null;
}
