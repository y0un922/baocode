import 'dart:async';

import 'package:flutter/foundation.dart';

import '../workspace/preference_store.dart';

/// Whether an agent that hits the account's usage limit goes on by itself
/// once the limit resets, unasked: the `chat.resumeAfterLimitReset`
/// setting. Off, the user is asked above the composer each time.
abstract final class ResumeAfterResetSetting {
  static const settingKey = 'chat.resumeAfterLimitReset';

  /// Written when on; off, the setting is left out.
  static const on = true;

  /// Off unless set to true.
  static bool enabled(Object? setting) => setting == true;

  /// The setting as it is now; main() points it at settings.json.
  static bool Function() current = () => false;
}

/// What is to happen to an agent stopped at the usage limit.
enum ResumeState {
  /// Not answered yet: asked above its composer.
  offered,

  /// Goes on by itself once the limit resets.
  scheduled,

  /// Not to go on: the user said no (and may yet say yes, in Settings).
  declined,
}

/// An agent stopped at the usage limit, until it resets.
@immutable
class ResumeEntry {
  const ResumeEntry({
    required this.sessionId,
    required this.title,
    required this.project,
    required this.resetsAt,
    required this.state,
  });

  final String sessionId;
  final String title;

  /// Its project's name, as the sidebar shows it.
  final String project;
  final DateTime resetsAt;
  final ResumeState state;

  bool get scheduled => state == ResumeState.scheduled;

  ResumeEntry copyWith({
    String? title,
    String? project,
    DateTime? resetsAt,
    ResumeState? state,
  }) => ResumeEntry(
    sessionId: sessionId,
    title: title ?? this.title,
    project: project ?? this.project,
    resetsAt: resetsAt ?? this.resetsAt,
    state: state ?? this.state,
  );

  Map<String, Object?> toJson() => {
    'session': sessionId,
    'title': title,
    'project': project,
    'resetsAt': resetsAt.toUtc().toIso8601String(),
    'state': state.name,
  };

  static ResumeEntry? fromJson(Object? json) => switch (json) {
    {
      'session': final String sessionId,
      'resetsAt': final String resetsAt,
      'state': final String state,
    } =>
      switch ((
        DateTime.tryParse(resetsAt),
        ResumeState.values.asNameMap()[state],
      )) {
        (final at?, final state?) => ResumeEntry(
          sessionId: sessionId,
          title: switch (json['title']) {
            final String title => title,
            _ => '',
          },
          project: switch (json['project']) {
            final String project => project,
            _ => '',
          },
          resetsAt: at.toLocal(),
          state: state,
        ),
        _ => null,
      },
    _ => null,
  };
}

/// Continues [sessionId]'s agent: whether it was (or need not be any
/// more: it went on already, or is gone); false to be tried again.
typedef ResumeAgent = Future<bool> Function(String sessionId);

/// The agents stopped at the account's usage limit, and those of them to
/// go on once it resets: each sent a message to continue then, by
/// [resume] (the workspace's). Kept between runs: one due while the app
/// was closed goes on once it is open again.
class ResumeAfterReset extends ChangeNotifier {
  ResumeAfterReset({
    this._store,
    this.margin = const Duration(seconds: 60),
    this.retryAfter = const Duration(minutes: 1),
    this.attempts = 5,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The app's; main() gives it a file to keep them in.
  static ResumeAfterReset current = ResumeAfterReset();

  /// Where the app keeps them, in its state folder.
  static const fileName = 'resume_after_reset.json';

  final PreferenceStore? _store;
  final DateTime Function() _clock;

  /// How long after the reset an agent goes on: the account's usage is
  /// not started over that very second.
  final Duration margin;

  /// How long before an agent that could not go on is tried again, and
  /// how many times in all.
  final Duration retryAfter;
  final int attempts;

  /// Continues an agent; none till the workspace has listed them.
  ResumeAgent? get resume => _resume;
  ResumeAgent? _resume;
  set resume(ResumeAgent? resume) {
    _resume = resume;
    _arm();
  }

  final Map<String, ResumeEntry> _entries = {};
  final Map<String, int> _failed = {};
  final Map<String, DateTime> _retryAt = {};

  /// The agents continued here since a turn of theirs last went through,
  /// and how many times: one stopped at the limit again goes on again.
  final Map<String, int> _resumed = {};
  Timer? _timer;
  bool _firing = false;
  bool _disposed = false;

  /// All of them, those resetting first first.
  List<ResumeEntry> get entries =>
      _entries.values.toList()
        ..sort((a, b) => a.resetsAt.compareTo(b.resetsAt));

  ResumeEntry? operator [](String sessionId) => _entries[sessionId];

  /// Reads those kept; those whose limit has reset with nothing to do
  /// are let go.
  Future<void> load() async {
    final kept = await _store?.read() ?? const {};
    if (_disposed) return;
    final now = _clock();
    for (final json in switch (kept['entries']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    }) {
      final entry = ResumeEntry.fromJson(json);
      if (entry == null || _entries.containsKey(entry.sessionId)) continue;
      if (!entry.scheduled && !entry.resetsAt.isAfter(now)) continue;
      _entries[entry.sessionId] = entry;
    }
    _arm();
    notifyListeners();
  }

  /// [sessionId]'s agent hit the limit, which resets [resetsAt]: offered
  /// to go on then, or set to (see [ResumeAfterResetSetting]); one set to
  /// already, or declined, stays so, at the new time.
  ///
  /// Set to as well while another is (the account's limit, for all its
  /// agents), and when it was continued here and stopped at it again.
  /// That with a reset said that is past (the CLI's, not taken yet): it
  /// goes on again [retryAfter] on, up to [attempts] times; one not
  /// continued here has nothing to wait for.
  void hit({
    required String sessionId,
    required String title,
    required String project,
    required DateTime resetsAt,
  }) {
    final resumed = _resumed[sessionId] ?? 0;
    final stale = !resetsAt.isAfter(_clock());
    if (stale && (resumed == 0 || resumed >= attempts)) return;
    final known = _entries[sessionId];
    if (known != null &&
        known.title == title &&
        known.project == project &&
        known.resetsAt == resetsAt) {
      return;
    }
    _entries[sessionId] =
        known?.copyWith(title: title, project: project, resetsAt: resetsAt) ??
        ResumeEntry(
          sessionId: sessionId,
          title: title,
          project: project,
          resetsAt: resetsAt,
          state:
              ResumeAfterResetSetting.current() ||
                  resumed > 0 ||
                  _entries.values.any((entry) => entry.scheduled)
              ? ResumeState.scheduled
              : ResumeState.offered,
        );
    _forgetTries(sessionId);
    if (stale) _retryAt[sessionId] = _clock().add(retryAfter);
    _changed();
  }

  /// Sets [sessionId]'s agent to go on once the limit resets, or not. Set
  /// to, those not answered yet are too: all go on as it resets.
  void setScheduled(String sessionId, bool scheduled) {
    final entry = _entries[sessionId];
    final state = scheduled ? ResumeState.scheduled : ResumeState.declined;
    if (entry == null || entry.state == state) return;
    _entries[sessionId] = entry.copyWith(state: state);
    _forgetTries(sessionId);
    if (scheduled) {
      for (final other in [..._entries.values]) {
        if (other.state != ResumeState.offered) continue;
        _entries[other.sessionId] = other.copyWith(
          state: ResumeState.scheduled,
        );
        _forgetTries(other.sessionId);
      }
    }
    _changed();
  }

  /// Forgets [sessionId]'s agent: deleted, say, or a turn of it went
  /// through.
  void remove(String sessionId) {
    _resumed.remove(sessionId);
    if (_entries.remove(sessionId) == null) return;
    _forgetTries(sessionId);
    _changed();
  }

  void _forgetTries(String sessionId) {
    _failed.remove(sessionId);
    _retryAt.remove(sessionId);
  }

  void _changed() {
    _arm();
    _save();
    notifyListeners();
  }

  void _save() {
    final store = _store;
    if (store == null) return;
    unawaited(
      store.write({
        'entries': [for (final entry in entries) entry.toJson()],
      }),
    );
  }

  /// When [entry] is due to go on: [margin] after its reset, or once
  /// more after it could not.
  DateTime _dueOf(ResumeEntry entry) =>
      _retryAt[entry.sessionId] ?? entry.resetsAt.add(margin);

  /// Times the next to do: one due to go on, if the workspace can continue
  /// it, or one not to whose limit resets, to be let go then.
  void _arm() {
    _timer?.cancel();
    _timer = null;
    // Armed again once those under way are done.
    if (_disposed || _firing) return;
    DateTime? next;
    for (final entry in _entries.values) {
      final DateTime at;
      if (!entry.scheduled) {
        at = entry.resetsAt;
      } else if (_resume != null) {
        at = _dueOf(entry);
      } else {
        continue;
      }
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    final wait = next.difference(_clock());
    // Looked at again a minute on at most: a timer does not count the time
    // the computer slept, the clock does.
    _timer = Timer(
      wait.isNegative
          ? Duration.zero
          : wait < _recheck
          ? wait
          : _recheck,
      _fire,
    );
  }

  static const _recheck = Duration(minutes: 1);

  Future<void> _fire() async {
    _timer = null;
    if (_disposed) return;
    _firing = true;
    var changed = false;
    try {
      final now = _clock();
      // Their limit reset with nothing to do: no longer listed.
      for (final entry in [..._entries.values]) {
        if (entry.scheduled || entry.resetsAt.isAfter(now)) continue;
        _entries.remove(entry.sessionId);
        _forgetTries(entry.sessionId);
        changed = true;
      }
      final resume = _resume;
      final due = [
        if (resume != null)
          for (final entry in _entries.values)
            if (entry.scheduled && !_dueOf(entry).isAfter(now)) entry,
      ];
      for (final entry in due) {
        var done = false;
        try {
          done = await resume!(entry.sessionId);
        } on Object catch (error) {
          debugPrint('Not continued after the limit reset: $error');
        }
        if (_disposed) return;
        // Changed meanwhile: as it is now.
        if (!identical(_entries[entry.sessionId], entry)) continue;
        final failed = (_failed[entry.sessionId] ?? 0) + 1;
        if (done || failed >= attempts) {
          _entries.remove(entry.sessionId);
          _forgetTries(entry.sessionId);
          if (done) {
            _resumed[entry.sessionId] = (_resumed[entry.sessionId] ?? 0) + 1;
          }
          changed = true;
        } else {
          _failed[entry.sessionId] = failed;
          _retryAt[entry.sessionId] = _clock().add(retryAfter);
        }
      }
    } finally {
      _firing = false;
    }
    if (changed) {
      _save();
      notifyListeners();
    }
    _arm();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
