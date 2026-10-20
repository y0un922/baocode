import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../../icons/brand_logos.dart';
import '../../icons/project_icon.dart';
import '../../models/model_brand.dart';
import '../../models/model_icons.dart' show ProviderIconView;
import '../../models/model_provider.dart' show effortLabel, formatTokens;
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import '../output_meter.dart';
import '../queued_messages.dart';
import 'pi_transport.dart';

/// Adapts pi's RPC mode (`pi --mode rpc`) to [AgentKernel]. pi asks no
/// leave to use its tools, so nothing is approved here; what its
/// extensions ask the user (`select`, `confirm`, `input`) comes as
/// questions.
class PiKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext,
        AcceptsImages,
        RenamesSession,
        QueuesMessages,
        RewindsConversation,
        ForksConversation,
        LoadsHistory {
  PiKernel(this.descriptor, this._context, {this._start = startPiProcess})
    : _resumeFile = _context.resume?.path,
      _historyShown = _context.resume == null,
      _loadingHistory = _context.resume != null {
    // A new session starts on what new pi agents start on; one resumed, on
    // what it was on.
    if (_context.resume == null) {
      String? setting(KernelChoiceKind kind) =>
          _context.settings[kernelSettingKey(descriptor.id, kind)];
      _pendingModel = _model = setting(KernelChoiceKind.model);
      _pendingThinking = _thinking = setting(KernelChoiceKind.effort);
    }
    if (_resumeFile case final file?) _reading = _readHistory(file);
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final PiTransportFactory _start;

  PiTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _starting;
  Future<void> _stopped = Future.value();
  KernelHealth _health = KernelHealth.idle;
  bool _disposed = false;
  bool _releaseWanted = false;

  String? _sessionId;

  /// The session file to go on with when started (again).
  String? _resumeFile;
  bool _historyShown;

  /// The conversation of the session resumed, read from its file: shown
  /// at once, not once pi has started (true then).
  Future<bool>? _reading;

  Future<bool> _readHistory(String file) async {
    final messages = await readPiHistory(file);
    if (messages == null || _disposed) return false;
    _historyShown = true;
    _showHistory(messages);
    return true;
  }

  String get _cwd => _context.cwd ?? _context.resume?.cwd ?? '.';

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _sessionId;

  @override
  Future<void> get stopped => _stopped;

  bool get _running =>
      _transport != null && _health.status == KernelHealthStatus.ready;

  void _setHealth(KernelHealth health) {
    _health = health;
    emitInfoChanged();
  }

  // --- Choices --------------------------------------------------------------

  /// The models pi offers, as last listed by any session.
  static List<Map<String, Object?>> _knownModels = const [];

  /// The model in use (`provider/id`), and the thinking level.
  String? _model;
  String? _thinking;

  /// Picked while pi was not running: applied once it is.
  String? _pendingModel;
  String? _pendingThinking;

  static String _ref(Map<Object?, Object?> model) =>
      '${model['provider']}/${model['id']}';

  static (String, String) _split(String ref) {
    final slash = ref.indexOf('/');
    return (ref.substring(0, slash), ref.substring(slash + 1));
  }

  static Map<String, Object?>? _info(String? ref) =>
      _knownModels.where((m) => _ref(m) == ref).firstOrNull;

  @override
  late final KernelChoiceSource model = _Choice(
    options: () => [
      for (final info in _knownModels)
        KernelOption(
          _ref(info),
          '${info['name'] ?? info['id']}',
          Icons.hub_outlined,
          [
            '${info['id']}',
            if (info['contextWindow'] case final int tokens)
              formatTokens(tokens),
          ].join(' · '),
          group: KernelOptionGroup(
            '${info['provider']}',
            '${info['provider']}',
            iconBuilder: _providerIcon(info['baseUrl'] as String?),
          ),
          iconBuilder: _modelIcon('${info['id']}', info['baseUrl'] as String?),
        ),
    ],
    selected: () => _model,
    select: _pickModel,
  );

  /// A provider's icon, as its models' heading shows it: the logo of the
  /// maker its API at [baseUrl] is of, else that site's icon.
  static Widget Function(double, Color) _providerIcon(String? baseUrl) =>
      (size, color) => ProviderIconView(
        icon: switch (ModelBrand.ofUrl(baseUrl ?? '')) {
          final brand? => BrandIcon(brand),
          null => null,
        },
        site: baseUrl == null ? null : Uri.tryParse(baseUrl),
        size: size,
        color: color,
      );

  /// Model [id]'s icon: its maker's logo, as its name says; else its
  /// provider's.
  static Widget Function(double, Color) _modelIcon(
    String id,
    String? baseUrl,
  ) =>
      (size, color) => switch (ModelBrand.ofModel(id)) {
        final brand? => BrandLogo(brand, size: size, color: color),
        null => _providerIcon(baseUrl)(size, color),
      };

  void _pickModel(String ref) {
    if (ref == _model) return;
    _model = _pendingModel = ref;
    emitInfoChanged();
    if (_running) unawaited(_applyPending());
  }

  static const _allLevels = [
    'off',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  ];

  /// The thinking levels [ref] takes, worked out as pi does: none for a
  /// model that does not think; of the rest, those its `thinkingLevelMap`
  /// does not rule out, xhigh and max only if it maps them.
  List<String> _levelsOf(String ref) {
    final info = _info(ref);
    if (info?['reasoning'] != true) return const [];
    final map = info?['thinkingLevelMap'] as Map? ?? const {};
    return [
      for (final level in _allLevels)
        if (map.containsKey(level)
            ? map[level] != null
            : level != 'xhigh' && level != 'max')
          level,
    ];
  }

  /// The level [ref] thinks at when [_thinking] is picked: as pi clamps it,
  /// the nearest it takes, higher first.
  String? _levelFor(String ref) {
    final level = _thinking;
    final levels = _levelsOf(ref);
    if (level == null || levels.isEmpty || levels.contains(level)) {
      return level;
    }
    final at = _allLevels.indexOf(level);
    if (at < 0) return levels.first;
    return [
      ..._allLevels.skip(at),
      ..._allLevels.take(at).toList().reversed,
    ].firstWhere(levels.contains);
  }

  @override
  late final ModelSetting effort = _Setting(
    optionsFor: (ref) => [
      for (final level in _levelsOf(ref))
        KernelOption(level, effortLabel(level), Icons.speed_rounded, ''),
    ],
    selected: () => _thinking,
    selectedFor: _levelFor,
    select: (ref, level) {
      _pickModel(ref);
      if (level == _thinking) return;
      _thinking = _pendingThinking = level;
      emitInfoChanged();
      if (_running) unawaited(_applyPending());
    },
  );

  /// Tells pi what was picked while it was not running.
  Future<void> _applyPending() async {
    try {
      if (_pendingModel case final ref?) {
        _pendingModel = null;
        final (provider, id) = _split(ref);
        final model = await _call({
          'type': 'set_model',
          'provider': provider,
          'modelId': id,
        });
        if (model != null) _applyModel(model);
      }
      if (_pendingThinking case final level?) {
        _pendingThinking = null;
        await _call({'type': 'set_thinking_level', 'level': level});
      }
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'pick:${DateTime.now().microsecondsSinceEpoch}',
          NoticeItem(NoticeKind.error, '$error'),
        ),
      );
      // What is in effect, then.
      final state = await _call({'type': 'get_state'}).catchError((_) => null);
      if (state != null) _applyState(state);
    }
  }

  int _contextWindow = 200000;

  @override
  int get contextWindow => _contextWindow;

  @override
  List<KernelCommand> commands = _builtinCommands;

  static const _builtinCommands = [
    KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
      argumentHint: '[instructions]',
    ),
  ];

  @override
  void rename(String title) =>
      unawaited(_request({'type': 'set_session_name', 'name': title}));

  // --- The process ------------------------------------------------------------

  int _requests = 0;
  final Map<String, Completer<Map<String, Object?>?>> _responses = {};

  /// Writes [command] and completes with its response's data; fails with
  /// its error. pi must be running.
  Future<Map<String, Object?>?> _call(Map<String, Object?> command) {
    final transport = _transport;
    if (transport == null) return Future.error(StateError('pi stopped'));
    final id = 'baocode-${++_requests}';
    final response = Completer<Map<String, Object?>?>();
    _responses[id] = response;
    transport.write({...command, 'id': id});
    return response.future;
  }

  /// [_call], once started, and done with what is [_ahead].
  Future<Map<String, Object?>?> _request(Map<String, Object?> command) =>
      _ensureStarted().then((_) => _ahead).then((_) => _call(command));

  Future<void> _ensureStarted() {
    if (_disposed) return Future.error(StateError('disposed'));
    if (_running) return Future.value();
    return _starting ??= _launch().whenComplete(() {
      _starting = null;
      if (_releaseWanted) release();
    });
  }

  Future<void> _launch() async {
    // One process at a time on a session: the last one, if restarted.
    await _stopped;
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    final PiTransport transport;
    try {
      transport = await _start(
        _cwd,
        session: _resumeFile,
        environment: _context.environment,
      );
    } on PiUnavailable catch (error) {
      _fail(error.message, error.detail);
      rethrow;
    } on Object catch (error) {
      _fail('pi did not start', '$error');
      rethrow;
    }
    if (_disposed) {
      transport.close();
      throw StateError('disposed');
    }
    _transport = transport;
    _subscription = transport.messages.listen(_receive);
    try {
      final state = await _call({'type': 'get_state'})
          .timeout(const Duration(seconds: 30));
      if (state != null) _applyState(state);
      _setHealth(KernelHealth.ready);
      await _applyPending();
      unawaited(_refreshModels());
      unawaited(_refreshCommands());
      if (!_historyShown) {
        _historyShown = true;
        // Its file not read: asked of pi. Not shown, it is still pi's to go
        // on with.
        if (await _reading != true) {
          final data = await _call({'type': 'get_messages'})
              .catchError((_) => null);
          _showHistory([
            for (final message in data?['messages'] as List? ?? const [])
              if (message is Map) message.cast<String, Object?>(),
          ]);
        }
      }
    } on Object catch (error) {
      if (_health.status != KernelHealthStatus.failed) {
        _fail('pi did not start', '$error');
      }
      rethrow;
    }
  }

  void _applyState(Map<String, Object?> state) {
    _sessionId = state['sessionId'] as String? ?? _sessionId;
    if (state['model'] case final Map<Object?, Object?> model) {
      _applyModel(model.cast());
    }
    if (_pendingThinking == null) {
      _thinking = state['thinkingLevel'] as String? ?? _thinking;
    }
    if (state['sessionFile'] case final String file) _sessionFile = file;
    emitInfoChanged();
  }

  String? _sessionFile;

  void _applyModel(Map<String, Object?> model) {
    final ref = _ref(model);
    if (_pendingModel == null) _model = ref;
    if (model['contextWindow'] case final int window) _contextWindow = window;
    if (_info(ref) == null) _knownModels = [..._knownModels, model];
    emitInfoChanged();
  }

  Future<void> _refreshModels() async {
    try {
      final data = await _call({'type': 'get_available_models'});
      _knownModels = [
        for (final model in data?['models'] as List? ?? const [])
          if (model is Map) model.cast<String, Object?>(),
      ];
      emitInfoChanged();
    } on Object {
      // Kept as they were.
    }
  }

  Future<void> _refreshCommands() async {
    try {
      final data = await _call({'type': 'get_commands'});
      commands = [
        ..._builtinCommands,
        for (final command in data?['commands'] as List? ?? const [])
          if (command case {'name': final String name}
              when !_builtinCommands.any((c) => c.name == name))
            KernelCommand(
              name,
              command['description'] as String? ?? '',
              switch (command['source']) {
                'skill' => Icons.auto_awesome_outlined,
                'prompt' => Icons.description_outlined,
                _ => Icons.extension_outlined,
              },
            ),
      ];
      emitInfoChanged();
    } on Object {
      // Kept as they were.
    }
  }

  /// The session's cost and context, after a turn.
  Future<void> _refreshStats() async {
    try {
      final data = await _call({'type': 'get_session_stats'});
      if (data == null) return;
      if (data['cost'] case final num cost) {
        emit(StatsReported(nextSeq, UsageStats(costUsd: cost.toDouble())));
      }
      if (data['contextUsage'] case {
        'tokens': final int tokens,
        'contextWindow': final int window,
      }) {
        emit(
          UsageReported(nextSeq, ContextUsage(window: window, used: tokens)),
        );
      }
    } on Object {
      // Not said, then.
    }
  }

  void _fail(String message, String? detail) {
    _loadingHistory = false;
    _teardown();
    _setHealth(
      KernelHealth(KernelHealthStatus.failed, message: message, detail: detail),
    );
  }

  void _teardown() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    for (final response in _responses.values) {
      response.completeError(StateError('pi stopped'));
    }
    _responses.clear();
    if (_transport case final transport?) {
      _stopped = transport.exited.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      transport.close();
    }
    _transport = null;
    _releaseWanted = false;
  }

  @override
  void prepare() {
    _releaseWanted = false;
    if (_health.status == KernelHealthStatus.failed) return;
    unawaited(_ensureStarted().catchError((_) {}));
  }

  @override
  void restart() {
    _teardown();
    _setHealth(KernelHealth.idle);
    prepare();
  }

  @override
  void release() {
    if (_turn != null || _starting != null) {
      _releaseWanted = true;
      return;
    }
    if (_transport == null) return;
    _teardown();
    _setHealth(KernelHealth.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _dialogTimers.values) {
      timer.cancel();
    }
    _teardown();
    closeEvents();
  }

  // --- The conversation -------------------------------------------------------

  final Set<String> _sentTurns = {};
  String? _turn;
  DateTime? _turnStarted;
  int _unprompted = 0;

  /// What the turn's requests to the model spent.
  int _turnInput = 0;
  int _turnOutput = 0;
  double _turnCost = 0;

  /// Meters what the turn's model writes as it streams; reported now and
  /// then.
  final OutputMeter _meter = OutputMeter();
  DateTime? _outputReported;
  static const _outputEvery = Duration(milliseconds: 250);

  /// Messages sent while a turn runs, waiting here for it to end: the next
  /// first.
  final List<KernelTurn> _queue = [];

  /// The message to take up next, ahead of [_queue]: the turn running was
  /// stopped for it.
  KernelTurn? _now;

  /// Messages sent while a turn runs that pi was given (`steer`), to take
  /// up between its tool calls: the next first.
  final List<KernelTurn> _steered = [];

  /// What pi must be done with before it is given anything more: a run
  /// stopping, what was steered into it taken back.
  Future<void> _ahead = Future.value();

  /// Runs stopping: until they have, what they still say is dropped.
  int _stopping = 0;

  /// The model has answered in the run under way: a user message after
  /// that is one steered into it.
  bool _answered = false;

  /// The items showing the user messages on the branch of pi's session it
  /// is on, in order: one's place from the end is its message's there.
  final List<String> _userItems = [];

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    if (_turn == null) {
      _startTurn(turn);
      return;
    }
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images, queued: true),
      ),
    );
    if (turn.now) {
      _now = turn;
      cancel();
    } else if (QueuedMessages.current() == QueuedMessages.duringTurn &&
        _running &&
        _stopping == 0 &&
        _commandFor(turn)['type'] == 'prompt') {
      _steer(turn);
    } else {
      _queue.add(turn);
    }
  }

  /// Starts a turn with [turn].
  void _startTurn(KernelTurn turn) {
    _beginTurn(turn.id);
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );
    final command = _commandFor(turn);
    final prompt = command['type'] == 'prompt';
    unawaited(
      _ensureStarted()
          .then((_) => _ahead)
          .then((_) {
            if (_disposed || _turn != turn.id) return null;
            if (prompt) {
              _userItems.add(turn.id);
              // Older pi may omit turn_start; exclude process/setup time.
              _meter.resume();
            }
            return _call(command);
          })
          .then((data) {
            // Run as soon as it was sent (`/compact`), or taken by an
            // extension: no run follows.
            if (!prompt || data?['disposition'] == 'handled') {
              _userItems.remove(turn.id);
              if (_turn == turn.id) _endTurn();
            }
          })
          .catchError((Object error) {
            _userItems.remove(turn.id);
            if (_turn != turn.id) return;
            emit(
              ItemUpserted(
                nextSeq,
                'error:${turn.id}',
                NoticeItem(NoticeKind.error, _health.message ?? '$error'),
              ),
            );
            _endTurn(interrupted: true);
          }),
    );
  }

  /// Gives pi [turn] to take up in the run under way, between its tool
  /// calls.
  void _steer(KernelTurn turn) {
    _steered.add(turn);
    unawaited(
      _call({..._commandFor(turn), 'type': 'steer'})
          .then((data) {
            // Taken by an extension as it came: sent, and done with.
            if (data?['disposition'] == 'handled' && _steered.remove(turn)) {
              emit(
                ItemUpserted(
                  nextSeq,
                  turn.id,
                  UserMessageItem(text: turn.text, images: turn.images),
                ),
              );
            }
          })
          .catchError((Object _) {
            // Not taken: it waits for the turn to end instead.
            if (_steered.remove(turn)) _queue.insert(0, turn);
          }),
    );
  }

  /// What [turn] is sent as: `/compact` is pi's own command, anything else
  /// a prompt (its notes after it).
  static Map<String, Object?> _commandFor(KernelTurn turn) {
    final text = turn.text.trim();
    if (text == '/compact' || text.startsWith('/compact ')) {
      final instructions = text.substring('/compact'.length).trim();
      return {
        'type': 'compact',
        if (instructions.isNotEmpty) 'customInstructions': instructions,
      };
    }
    return {
      'type': 'prompt',
      'message': [turn.text, ...turn.notes].join('\n\n'),
      if (turn.images.isNotEmpty)
        'images': [
          for (final image in turn.images)
            {
              'type': 'image',
              'data': base64Encode(image.bytes),
              'mimeType': image.mediaType,
            },
        ],
    };
  }

  void _beginTurn(String id, {bool unprompted = false}) {
    _turn = id;
    _turnStarted = DateTime.now();
    _turnInput = _turnOutput = 0;
    _turnCost = 0;
    _answered = false;
    _meter.begin();
    _meter.pause();
    _outputReported = null;
    emit(TurnStarted(nextSeq, id, unprompted: unprompted));
  }

  @override
  void cancel() {
    if (_turn == null) return;
    if (_running) _stop();
    _endTurn(interrupted: true);
  }

  /// Stops pi's run: until it has, what it says is dropped, and it is given
  /// nothing more.
  void _stop() {
    _stopping++;
    _ahead = _ahead
        .then((_) => _call({'type': 'abort'}))
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _stopping--);
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final queued = _queue.indexWhere((turn) => turn.id == turnId);
    if (queued >= 0) {
      _queue.removeAt(queued);
      emit(ItemRemoved(nextSeq, turnId));
      return true;
    }
    if (!_steered.any((turn) => turn.id == turnId) || !_running) return false;
    // pi gives back all it was steered, or nothing: the others are steered
    // again.
    try {
      await _call({'type': 'clear_queue'});
    } on Object {
      return false;
    }
    final taken = !_steered.any((turn) => turn.id == turnId);
    final others = [
      for (final turn in _steered)
        if (turn.id != turnId) turn,
    ];
    _steered.clear();
    others.forEach(_steer);
    if (taken) return false;
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final turn = [
      ..._queue,
      ..._steered,
    ].where((turn) => turn.id == turnId).firstOrNull;
    if (turn == null) return;
    _queue.remove(turn);
    _steered.remove(turn);
    _now = turn;
    cancel();
  }

  void _endTurn({bool interrupted = false}) {
    final turn = _turn;
    if (turn == null) return;
    _turn = null;
    _meter.pause();
    for (final id in [..._texts.keys]) {
      _texts.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    for (final id in [..._thoughts.keys]) {
      _completeThought(id, null);
    }
    // Stopped with the turn: they will not report their end.
    for (final MapEntry(key: id, value: tool) in [..._tools.entries]) {
      _tools.remove(id);
      emit(
        ItemUpserted(
          nextSeq,
          id,
          _toolItem(tool.name, tool.args, status: ToolStatus.failed),
        ),
      );
    }
    _resolveDialogs();
    final spent = _turnInput > 0 || _turnOutput > 0;
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
        usage: spent
            ? TurnUsage(
                inputTokens: _turnInput,
                outputTokens: _turnOutput,
                tokensPerSecond: _meter.averageSpeed,
                costUsd: _turnCost,
              )
            : null,
      ),
    );
    if (_running) unawaited(_refreshStats());
    if (_resumeFile == null && _sessionFile != null) _resumeFile = _sessionFile;
    // Steered in, not taken up: taken back from pi, they wait their turn.
    if (_steered.isNotEmpty) {
      _queue.insertAll(0, _steered);
      _steered.clear();
      if (_running) {
        _ahead = _ahead
            .then((_) => _call({'type': 'clear_queue'}))
            .then<void>((_) {}, onError: (Object _) {});
      }
    }
    if (_now case final now?) {
      _now = null;
      _queue.insert(0, now);
    }
    if (_queue.isNotEmpty && _health.status != KernelHealthStatus.failed) {
      _startTurn(_queue.removeAt(0));
    }
    if (_releaseWanted) release();
  }

  /// Dropped from pi's session only once it is: pi goes on from where the
  /// session's file ends, so it is stopped while it is changed, and starts
  /// on it again with the next message.
  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    final at = _userItems.indexOf(itemId);
    final file = _sessionFile ?? _resumeFile;
    try {
      if (at < 0 || file == null) {
        throw StateError('pi does not keep that message');
      }
      cancel();
      await _ahead;
      if (_transport != null) {
        _teardown();
        _setHealth(KernelHealth.idle);
      }
      await _stopped;
      if (!await branchPiSession(file, _userItems.length - 1 - at)) {
        throw StateError('pi does not keep that message');
      }
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'rewind:$itemId',
          NoticeItem(NoticeKind.error, 'Could not rewind: $error'),
        ),
      );
      return false;
    }
    _userItems.removeRange(at, _userItems.length);
    _resumeFile = file;
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  bool get canFork =>
      (_sessionFile ?? _resumeFile) != null && _userItems.isNotEmpty;

  /// Copied beside the session, as pi wrote it so far: a turn running goes
  /// on here alone.
  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    final file = _sessionFile ?? _resumeFile;
    if (file == null) return null;
    final at = before == null ? -1 : _userItems.indexOf(before);
    try {
      final copy = await copyPiSession(
        file,
        fromEnd: at < 0 ? null : _userItems.length - 1 - at,
        title: title,
      );
      return SessionRecord(
        id: copy.id,
        title: title,
        updatedAt: DateTime.now(),
        cwd: _cwd,
        path: copy.path,
      );
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'fork:${before ?? file}',
          NoticeItem(NoticeKind.error, 'Could not fork: $error'),
        ),
      );
      return null;
    }
  }

  // --- Translation --------------------------------------------------------------

  /// The assistant message streaming, counted: its blocks' ids.
  int _message = 0;

  /// Text blocks streaming: how much of each is there.
  final Map<String, int> _texts = {};

  /// The text blocks of the assistant message streaming, to take its final
  /// text once it ends.
  final Set<String> _messageTexts = {};

  /// Thoughts streaming, and when each began.
  final Map<String, ({StringBuffer text, DateTime started})> _thoughts = {};

  /// Tools at work, as they were called.
  final Map<
    String,
    ({String name, Map<String, Object?> args, DateTime started})
  >
  _tools = {};

  /// What pi says that is not of a run.
  static const _outsideRuns = {'response', PiExit.type, 'extension_ui_request'};

  void _receive(Map<String, Object?> message) {
    // A run stopped, winding down: what it says is not of the turn now.
    if (_stopping > 0 && !_outsideRuns.contains(message['type'])) return;
    switch (message['type']) {
      case 'response':
        final response = _responses.remove(message['id']);
        if (response == null) return;
        if (message['success'] == true) {
          response.complete((message['data'] as Map?)?.cast<String, Object?>());
        } else {
          response.completeError(
            StateError('${message['error'] ?? 'pi refused the command'}'),
          );
        }
      case PiExit.type:
        _exited(message['stderr'] as String? ?? '');
      case 'extension_ui_request':
        _extensionRequest(message);
      case 'agent_start':
        _answered = false;
        if (_turn == null) {
          // Taken up by pi on its own, e.g. an extension's message.
          _beginTurn('pi-turn:${++_unprompted}', unprompted: true);
          _meter.resume();
        }
      case 'turn_start':
        // Before the provider request, so TTFT and reasoning both count.
        _meter.resume();
      case 'agent_settled':
        _endTurn(interrupted: message['aborted'] == true);
      case 'message_start':
        switch (message['message']) {
          case {'role': 'assistant'}:
            _answered = true;
            _message++;
            _messageTexts.clear();
          case {'role': 'user'} when _answered && _steered.isNotEmpty:
            // A message steered in, taken up: after what came before it.
            final turn = _steered.removeAt(0);
            _userItems.add(turn.id);
            emit(
              ItemUpserted(
                nextSeq,
                turn.id,
                UserMessageItem(text: turn.text, images: turn.images),
              ),
            );
        }
      case 'message_update':
        if (message['assistantMessageEvent']
            case final Map<Object?, Object?> event) {
          _assistantEvent(event.cast());
        }
      case 'message_end':
        if (message['message'] case {'role': 'assistant'} && final Map m) {
          _assistantEnded(m.cast());
        }
      case 'tool_execution_start':
        _toolStarted(message);
      case 'tool_execution_update':
        _toolUpdated(message);
      case 'tool_execution_end':
        _toolEnded(message);
      case 'compaction_start':
        _meter.pause();
        emit(
          ActivityReported(
            nextSeq,
            KernelActivity(KernelActivityKind.compacting, DateTime.now()),
          ),
        );
      case 'compaction_end':
        emit(ActivityReported(nextSeq, null));
        final id = 'compaction:${DateTime.now().microsecondsSinceEpoch}';
        if (message['result'] != null) {
          emit(
            ItemUpserted(
              nextSeq,
              id,
              const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
            ),
          );
        } else if (message['errorMessage'] case final String error) {
          emit(ItemUpserted(nextSeq, id, NoticeItem(NoticeKind.error, error)));
        }
      case 'auto_retry_start':
        emit(
          ItemUpserted(
            nextSeq,
            'retry:${DateTime.now().microsecondsSinceEpoch}',
            NoticeItem(
              NoticeKind.retry,
              'Retrying (${message['attempt']}/${message['maxAttempts']}): '
              '${message['errorMessage'] ?? ''}',
            ),
          ),
        );
      case 'auto_retry_end' when message['success'] == false:
        emit(
          ItemUpserted(
            nextSeq,
            'retry:${DateTime.now().microsecondsSinceEpoch}',
            NoticeItem(NoticeKind.error, '${message['finalError'] ?? ''}'),
          ),
        );
      case 'thinking_level_changed':
        if (message['level'] case final String level) {
          _thinking = level;
          emitInfoChanged();
        }
    }
  }

  void _exited(String stderr) {
    _teardown();
    final detail = _stripAnsi(stderr).trim();
    // Failed before the turn ends: nothing queued is taken up then.
    _setHealth(
      KernelHealth(
        KernelHealthStatus.failed,
        message: 'pi stopped',
        detail: detail.isEmpty ? null : detail,
      ),
    );
    if (_turn case final turn?) {
      emit(
        ItemUpserted(
          nextSeq,
          'error:$turn',
          NoticeItem(
            NoticeKind.error,
            detail.isEmpty ? 'pi stopped' : 'pi stopped:\n$detail',
          ),
        ),
      );
      _endTurn(interrupted: true);
    }
  }

  void _assistantEvent(Map<String, Object?> event) {
    final id = 'pi:$_message:${event['contentIndex']}';
    switch (event['type']) {
      case 'text_start':
        _texts[id] = 0;
        _messageTexts.add(id);
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'text_delta':
        final offset = _texts[id];
        if (offset == null) return;
        final delta = event['delta'] as String? ?? '';
        _texts[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
        _metered(delta);
      case 'text_end':
        if (_texts.remove(id) == null) return;
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(event['content'] as String? ?? ''),
          ),
        );
      case 'thinking_start':
        final started = DateTime.now();
        _thoughts[id] = (text: StringBuffer(), started: started);
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: started),
            streaming: true,
          ),
        );
      case 'toolcall_delta':
        _metered(event['delta'] as String? ?? '');
      case 'thinking_delta':
        final thought = _thoughts[id];
        if (thought == null) return;
        final delta = event['delta'] as String? ?? '';
        _metered(delta);
        final offset = thought.text.length;
        thought.text.write(delta);
        emit(
          TextDelta(
            nextSeq,
            id,
            offset,
            delta,
            tokens: thought.text.length ~/ 4,
          ),
        );
      case 'thinking_end':
        _completeThought(id, event['content'] as String?);
    }
  }

  /// Meters [text] written (see [OutputMeter.streamed]), and reports what
  /// is written now and then.
  void _metered(String text) {
    _meter.streamed(text);
    final now = DateTime.now();
    if (_outputReported case final at? when now.difference(at) < _outputEvery) {
      return;
    }
    _outputReported = now;
    emit(OutputReported(nextSeq, _meter.output));
  }

  void _completeThought(String id, String? content) {
    final thought = _thoughts.remove(id);
    if (thought == null) return;
    final text = _stripAnsi(content ?? thought.text.toString());
    emit(
      ItemCompleted(
        nextSeq,
        id,
        item: ThinkingItem(
          text: text,
          tokens: text.length ~/ 4,
          seconds: math.max(
            1,
            (DateTime.now().difference(thought.started).inMilliseconds / 1000)
                .round(),
          ),
        ),
      ),
    );
  }

  void _assistantEnded(Map<String, Object?> message) {
    // Its text as it ends is what it says, not what streamed: extensions
    // may change it on the way (its thoughts, they only color).
    for (final (index, block)
        in (message['content'] as List? ?? const []).indexed) {
      final id = 'pi:$_message:$index';
      if (block case {'type': 'text', 'text': final String text}
          when _messageTexts.contains(id)) {
        _texts.remove(id);
        emit(ItemCompleted(nextSeq, id, item: AssistantTextItem(text)));
      }
    }
    _messageTexts.clear();
    final usage = message['usage'];
    final output = switch (usage) {
      {'output': final num tokens} when tokens.isFinite && tokens >= 0 =>
        tokens.toInt(),
      _ => null,
    };
    final duration = switch (message['durationMs']) {
      null => null,
      final num ms when ms.isFinite && ms > 0 => Duration(
        microseconds: (ms * 1000).round(),
      ),
      _ => Duration.zero,
    };
    _meter.endMessage(tokens: output, duration: duration);
    // Tool execution and steering wait until the next provider request.
    _meter.pause();
    _outputReported = DateTime.now();
    emit(OutputReported(nextSeq, _meter.output));
    if (usage case final Map<Object?, Object?> usage) {
      int count(String key) => (usage[key] as num?)?.toInt() ?? 0;
      _turnInput += count('input') + count('cacheRead') + count('cacheWrite');
      _turnOutput += count('output');
      if (usage['cost'] case {'total': final num cost}) {
        _turnCost += cost.toDouble();
      }
      if (count('totalTokens') > 0) {
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(window: _contextWindow, used: count('totalTokens')),
          ),
        );
      }
    }
    if (message['stopReason'] == 'error') {
      emit(
        ItemUpserted(
          nextSeq,
          'pi:$_message:error',
          NoticeItem(
            NoticeKind.error,
            '${message['errorMessage'] ?? 'The model request failed'}',
          ),
        ),
      );
    }
  }

  void _toolStarted(Map<String, Object?> message) {
    final id = message['toolCallId'] as String;
    final name = message['toolName'] as String? ?? '';
    final args = (message['args'] as Map?)?.cast<String, Object?>() ?? {};
    _tools[id] = (name: name, args: args, started: DateTime.now());
    emit(
      ItemUpserted(
        nextSeq,
        id,
        _toolItem(name, args, status: ToolStatus.running),
      ),
    );
  }

  void _toolUpdated(Map<String, Object?> message) {
    final id = message['toolCallId'] as String;
    final tool = _tools[id];
    if (tool == null) return;
    emit(
      ItemUpserted(
        nextSeq,
        id,
        _toolItem(
          tool.name,
          tool.args,
          status: ToolStatus.running,
          output: _resultText(message['partialResult']),
          started: tool.started,
        ),
      ),
    );
  }

  void _toolEnded(Map<String, Object?> message) {
    final id = message['toolCallId'] as String;
    final tool = _tools.remove(id);
    final name = tool?.name ?? message['toolName'] as String? ?? '';
    final args = tool?.args ?? const {};
    final result = (message['result'] as Map?)?.cast<String, Object?>() ?? {};
    final failed = message['isError'] == true;
    final item = _finishedTool(name, args, result, failed: failed);
    emit(ItemUpserted(nextSeq, id, item));
    if (failed || item is! CodeDiffItem) return;
    final patch = (result['details'] as Map?)?['patch'] as String?;
    emit(
      FileEdited(
        nextSeq,
        FileChange(
          path: _absolute(args['path'] as String? ?? ''),
          added: item.added,
          removed: item.removed,
        ),
        turnId: _turn,
        original: patch == null ? null : OriginalByPatch(patch),
      ),
    );
  }

  /// A tool done, as the history shows it: an edit or a file written as
  /// its diff, anything else as its row.
  ChatItem _finishedTool(
    String name,
    Map<String, Object?> args,
    Map<String, Object?> result, {
    required bool failed,
  }) {
    final path = args['path'] as String?;
    if (!failed && path != null) {
      if (name == 'edit') {
        if ((result['details'] as Map?)?['patch'] case final String patch) {
          return _diff(path, _patchLines(patch));
        }
      } else if (name == 'write') {
        final content = args['content'] as String? ?? '';
        final lines = content.endsWith('\n')
            ? content.substring(0, content.length - 1).split('\n')
            : content.split('\n');
        return _diff(path, [
          for (final (index, line) in lines.indexed)
            DiffLine(DiffLineType.added, index + 1, line),
        ]);
      }
    }
    final exitCode = switch (result['structuredContent']) {
      {'exit_code': final int code} => code,
      _ => null,
    };
    return _toolItem(
      name,
      args,
      status: failed || (exitCode ?? 0) != 0
          ? ToolStatus.failed
          : ToolStatus.succeeded,
      output: _resultText(result),
    );
  }

  /// A tool as a row: a command as a terminal, reads and searches as
  /// theirs, anything else by its name.
  ChatItem _toolItem(
    String name,
    Map<String, Object?> args, {
    required ToolStatus status,
    String? output,
    DateTime? started,
  }) {
    String arg(String key) => args[key] as String? ?? '';
    final path = arg('path');
    final done = status != ToolStatus.running;
    switch (name) {
      case 'bash':
        return TerminalItem(
          command: arg('command'),
          output: output ?? '',
          status: switch (status) {
            ToolStatus.running => CommandStatus.running,
            ToolStatus.succeeded => CommandStatus.succeeded,
            _ => CommandStatus.failed,
          },
          startedAt: started,
        );
      case 'read':
        return ToolCallItem(
          kind: ToolKind.read,
          target: p.basename(path),
          path: _absolute(path),
          status: status,
        );
      case 'grep':
        final matches = [
          for (final line in (output ?? '').split('\n'))
            if (line.contains(':')) line.split(':').take(2).join(':'),
        ];
        return ToolCallItem(
          kind: ToolKind.grep,
          target: arg('pattern'),
          detail: done ? '${matches.length} results' : null,
          results: matches,
          status: status,
        );
      case 'find':
        return ToolCallItem(
          kind: ToolKind.search,
          target: arg('pattern').isEmpty ? path : arg('pattern'),
          output: output,
          status: status,
        );
      case 'ls':
        return ToolCallItem(
          kind: ToolKind.listDir,
          target: path.isEmpty ? '.' : path,
          output: output,
          status: status,
        );
      case 'edit' || 'write':
        return ToolCallItem(
          kind: ToolKind.edit,
          target: p.basename(path),
          path: _absolute(path),
          output: output,
          status: status,
        );
      default:
        return ToolCallItem(
          kind: ToolKind.other,
          target: args.values.whereType<String>().firstOrNull ?? '',
          label: name,
          tool: name,
          input: args,
          output: output,
          status: status,
        );
    }
  }

  CodeDiffItem _diff(String path, List<DiffLine> lines) {
    final absolute = _absolute(path);
    return CodeDiffItem(
      fileName: p.basename(absolute),
      directory: p.dirname(absolute),
      lines: lines,
    );
  }

  /// The lines of a unified diff, numbered as in the file.
  static List<DiffLine> _patchLines(String patch) {
    final lines = <DiffLine>[];
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    var inHunk = false;
    for (final line in patch.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        inHunk = true;
        continue;
      }
      if (!inHunk || line.isEmpty || line.startsWith(r'\')) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    return lines;
  }

  String _absolute(String path) =>
      path.isEmpty || p.isAbsolute(path) ? path : p.join(_cwd, path);

  /// A tool result's text blocks.
  static String? _resultText(Object? result) => switch (result) {
    {'content': final List<Object?> blocks} => [
      for (final block in blocks)
        if (block case {'type': 'text', 'text': final String text}) text,
    ].join('\n'),
    _ => null,
  };

  static final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

  static String _stripAnsi(String text) => text.replaceAll(_ansi, '');

  // --- History ----------------------------------------------------------------

  /// Turns shown of the session resumed at first, then on each asking for
  /// more: as Claude Code's.
  static const _firstTurns = 10;
  static const _earlierTurns = 20;

  /// The conversation of the session resumed, all of it; shown from
  /// message [_shownFrom] on.
  List<Map<String, Object?>> _history = const [];
  int _shownFrom = 0;
  bool _loadingHistory;

  /// Where the history's items go while gathered for [HistoryPrepended],
  /// rather than out one by one.
  Map<String, ChatItem>? _gathering;

  @override
  void emit(KernelEvent event) {
    if (_gathering case final items?) {
      if (event is ItemUpserted) items[event.id] = event.item;
      return;
    }
    super.emit(event);
  }

  @override
  bool get loadingHistory => _loadingHistory;

  @override
  bool get hasEarlierHistory => _shownFrom > 0 && !_loadingHistory;

  /// Read with the rest: there at once.
  @override
  bool get loadingEarlier => false;

  @override
  Future<void> loadEarlier() async {
    if (_shownFrom == 0 || _disposed) return;
    final to = _shownFrom;
    _shownFrom = _turnsFrom(to, _earlierTurns);
    final items = _gathering = {};
    try {
      _translateHistory(_shownFrom, to);
    } finally {
      _gathering = null;
    }
    emit(
      HistoryPrepended(nextSeq, [
        ...items.entries.map((e) => (e.key, e.value)),
      ]),
    );
    emitInfoChanged();
  }

  /// Where the [turns] turns of the history before message [end] begin: at
  /// the user's message; at its start once there are fewer before.
  int _turnsFrom(int end, int turns) {
    var count = 0;
    for (var i = end - 1; i >= 0; i--) {
      if (_history[i]['role'] == 'user' && ++count == turns) {
        final more = _history.take(i).any((m) => m['role'] == 'user');
        return more ? i : 0;
      }
    }
    return 0;
  }

  /// The conversation of the session resumed, as pi kept it: its last
  /// turns shown, the rest on asking ([loadEarlier]).
  void _showHistory(List<Map<String, Object?>> messages) {
    _history = messages;
    // All of them, to rewind to any: shown or not yet.
    for (final (index, message) in messages.indexed) {
      if (message['role'] == 'user') _userItems.add('pi:history:$index');
    }
    _shownFrom = _turnsFrom(messages.length, _firstTurns);
    _translateHistory(_shownFrom, messages.length);
    _loadingHistory = false;
    emitInfoChanged();
  }

  /// The history's messages [from] to [to], as items.
  void _translateHistory(int from, int to) {
    final calls = <String, ({String name, Map<String, Object?> args})>{};
    for (var index = from; index < to; index++) {
      final message = _history[index];
      final id = 'pi:history:$index';
      switch (message['role']) {
        case 'user':
          final text = _userText(message['content']);
          if (text.isNotEmpty) {
            emit(ItemUpserted(nextSeq, id, UserMessageItem(text: text)));
          }
        case 'assistant':
          for (final (block, content)
              in (message['content'] as List? ?? const []).indexed) {
            switch (content) {
              case {'type': 'text', 'text': final String text}
                  when text.trim().isNotEmpty:
                emit(
                  ItemUpserted(nextSeq, '$id:$block', AssistantTextItem(text)),
                );
              case {'type': 'thinking', 'thinking': final String thinking}
                  when thinking.trim().isNotEmpty:
                final text = _stripAnsi(thinking);
                emit(
                  ItemUpserted(
                    nextSeq,
                    '$id:$block',
                    ThinkingItem(
                      text: text,
                      tokens: text.length ~/ 4,
                      seconds: 1,
                    ),
                  ),
                );
              case {
                'type': 'toolCall',
                'id': final String call,
                'name': final String name,
              }:
                calls[call] = (
                  name: name,
                  args: (content['arguments'] as Map?)?.cast() ?? {},
                );
            }
          }
        case 'toolResult':
          final call = calls.remove(message['toolCallId']);
          if (call == null) continue;
          emit(
            ItemUpserted(
              nextSeq,
              message['toolCallId'] as String,
              _finishedTool(
                call.name,
                call.args,
                message,
                failed: message['isError'] == true,
              ),
            ),
          );
        case 'bashExecution':
          emit(
            ItemUpserted(
              nextSeq,
              id,
              TerminalItem(
                command: message['command'] as String? ?? '',
                output: message['output'] as String? ?? '',
                status: message['exitCode'] == 0
                    ? CommandStatus.succeeded
                    : CommandStatus.failed,
              ),
            ),
          );
        case 'compactionSummary':
          emit(
            ItemUpserted(
              nextSeq,
              id,
              const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
            ),
          );
      }
    }
  }

  static String _userText(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> blocks => [
      for (final block in blocks)
        if (block case {'type': 'text', 'text': final String text}) text,
    ].join('\n'),
    _ => '',
  };

  // --- Extension dialogs ------------------------------------------------------

  /// Dialogs awaiting the user: our request id → pi's, and what it asks.
  final Map<String, ({String id, String method})> _dialogs = {};
  final Map<String, Timer> _dialogTimers = {};

  static const _yes = 'Yes';
  static const _no = 'No';
  static const _typeHere = 'Type here';

  void _extensionRequest(Map<String, Object?> request) {
    final piId = request['id'] as String? ?? '';
    final title = _stripAnsi(request['title'] as String? ?? '');
    switch (request['method']) {
      case 'select':
        _ask(piId, 'select', title, [
          Question(
            prompt: title,
            options: [
              for (final option in request['options'] as List? ?? const [])
                QuestionOption(_stripAnsi('$option')),
            ],
            allowOther: false,
          ),
        ], request['timeout']);
      case 'confirm':
        _ask(piId, 'confirm', title, [
          Question(
            prompt: _stripAnsi(request['message'] as String? ?? title),
            header: title,
            options: const [QuestionOption(_yes), QuestionOption(_no)],
            allowOther: false,
          ),
        ], request['timeout']);
      case 'input' || 'editor':
        _ask(piId, 'input', title, [
          Question(
            prompt: title,
            options: const [],
            otherLabel: _stripAnsi(
              request['placeholder'] as String? ?? _typeHere,
            ),
          ),
        ], request['timeout']);
      case 'notify':
        final kind = switch (request['notifyType']) {
          'error' => NoticeKind.error,
          'warning' => NoticeKind.warning,
          _ => null,
        };
        if (kind == null) return;
        emit(
          ItemUpserted(
            nextSeq,
            'notify:$piId',
            NoticeItem(kind, _stripAnsi(request['message'] as String? ?? '')),
          ),
        );
    }
  }

  void _ask(
    String piId,
    String method,
    String title,
    List<Question> questions,
    Object? timeout,
  ) {
    final id = 'pi-ui:$piId';
    _dialogs[id] = (id: piId, method: method);
    if (timeout case final int ms) {
      // pi answers it itself then.
      _dialogTimers[id] = Timer(Duration(milliseconds: ms), () {
        _dialogTimers.remove(id);
        if (_dialogs.remove(id) != null) {
          emit(InteractionResolved(nextSeq, id));
        }
      });
    }
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(id: id, title: title, questions: questions),
      ),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final dialog = _dialogs.remove(requestId);
    if (dialog == null) return;
    _dialogTimers.remove(requestId)?.cancel();
    emit(InteractionResolved(nextSeq, requestId));
    final pick = switch (answer) {
      QuestionAnswer(skipped: false, :final picks)
          when picks.isNotEmpty && picks.first.isNotEmpty =>
        picks.first.first,
      _ => null,
    };
    _transport?.write({
      'type': 'extension_ui_response',
      'id': dialog.id,
      if (pick == null)
        'cancelled': true
      else if (dialog.method == 'confirm')
        'confirmed': pick == _yes
      else
        'value': pick,
    });
  }

  void _resolveDialogs() {
    for (final id in _dialogs.keys) {
      _dialogTimers.remove(id)?.cancel();
      emit(InteractionResolved(nextSeq, id));
    }
    _dialogs.clear();
  }
}

/// A choice over what the kernel keeps.
class _Choice implements KernelChoiceSource {
  _Choice({
    required this._options,
    required this._selected,
    required this._select,
  });

  final List<KernelOption> Function() _options;
  final String? Function() _selected;
  final void Function(String id) _select;

  @override
  List<KernelOption> get options => _options();

  @override
  String? get selected => _selected();

  @override
  void select(String id) => _select(id);
}

/// pi's thinking level: one for the session, each model at the nearest it
/// takes.
class _Setting implements ModelSetting {
  _Setting({
    required this._optionsFor,
    required this._selected,
    required this._selectedFor,
    required this._select,
  });

  final List<KernelOption> Function(String model) _optionsFor;
  final String? Function() _selected;
  final String? Function(String model) _selectedFor;
  final void Function(String model, String id) _select;

  @override
  bool get toggle => false;

  @override
  List<KernelOption> optionsFor(String model) => _optionsFor(model);

  @override
  String? get selected => _selected();

  @override
  String? selectedFor(String model) => _selectedFor(model);

  @override
  void select(String model, String id) => _select(model, id);
}
