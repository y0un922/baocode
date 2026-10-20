import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../../icons/brand_logos.dart';
import '../../models/model_brand.dart';
import '../../models/model_provider.dart' show effortLabel;
import '../agent_kernel.dart';
import '../claude_code/claude_elicitation.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import '../output_meter.dart';
import '../queued_messages.dart';
import 'codex_catalog.dart';
import 'codex_rpc.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]: a thread of Codex's for the
/// session, a turn of it for each message. Codex keeps no background
/// commands and cannot put files back, so it does not declare
/// [RunsBackgroundTasks] or [RevertsChanges]: those parts of the UI are not
/// shown for it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsEffort,
        SelectsMode,
        SelectsPermission,
        ProvidesCommands,
        ReportsContext,
        ReportsUsage,
        QueuesMessages,
        RewindsConversation,
        ForksConversation,
        RenamesSession,
        AcceptsImages,
        ManagesMcpServers,
        LoadsHistory {
  CodexKernel(this.descriptor, this._context, {this._start = startCodexProcess})
    : _threadId = _context.resume?.id,
      _historyShown = _context.resume == null,
      _loadingHistory = _context.resume != null {
    // A new session starts on what new Codex agents start on; one resumed,
    // on what its thread was on.
    if (_context.resume == null) {
      String? setting(KernelChoiceKind kind) =>
          _context.settings[kernelSettingKey(descriptor.id, kind)];
      _model = setting(KernelChoiceKind.model);
      _effort = setting(KernelChoiceKind.effort);
      _mode = setting(KernelChoiceKind.mode) ?? _mode;
      _permission = setting(KernelChoiceKind.permission) ?? _permission;
    }
    _live.add(this);
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final CodexTransportFactory _start;

  CodexTransport? _transport;
  CodexRpc? _rpc;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _starting;
  Future<void> _stopped = Future.value();
  KernelHealth _health = KernelHealth.idle;
  bool _disposed = false;
  bool _releaseWanted = false;

  /// The thread the session is, once there is one; and whether this
  /// server is following it.
  String? _threadId;
  bool _subscribed = false;
  String? _threadPath;

  /// The conversation of the thread resumed is shown once.
  bool _historyShown;

  /// A name given before there was a thread to give it.
  String? _pendingName;

  String get _cwd => _context.cwd ?? _context.resume?.cwd ?? '.';

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _threadId;

  @override
  Future<void> get stopped => _stopped;

  bool get _running =>
      _transport != null && _health.status == KernelHealthStatus.ready;

  void _setHealth(KernelHealth health) {
    _health = health;
    emitInfoChanged();
  }

  // --- Choices --------------------------------------------------------------

  /// The models Codex offers, as last listed by any session.
  static List<Map<String, Object?>> _knownModels = const [];

  String? _model;
  String? _effort;
  String _mode = 'agent';
  String _permission = 'default';

  static Map<String, Object?>? _info(String? id) =>
      _knownModels.where((m) => m['id'] == id).firstOrNull;

  /// The model a turn runs on: the one picked, else Codex's default (null
  /// while its models are not known: Codex takes its own then).
  String? get _modelInUse => switch (_model) {
    null || _default =>
      (_knownModels.where((m) => m['isDefault'] == true).firstOrNull ??
              _knownModels.firstOrNull)?['id']
          as String?,
    final model => model,
  };

  /// Offered while its models are not known (no session has started yet):
  /// Codex's default, whichever it is.
  static const _default = 'default';

  static final _group = KernelOptionGroup(
    'codex',
    'Codex',
    iconBuilder: (size, color) => BrandLogo('openai', size: size, color: color),
  );

  @override
  late final KernelChoiceSource model = _Choice(
    options: () {
      // Not started yet (e.g. a new agent): its models asked of Codex.
      if (_knownModels.isEmpty && _starting == null && !_running) {
        _listModels();
      }
      return [
        if (_knownModels.isEmpty)
          KernelOption(
            _default,
            'Default',
            Icons.hub_outlined,
            '',
            group: _group,
            iconBuilder: (size, color) =>
                BrandLogo('codex', size: size, color: color),
          ),
        for (final info in _knownModels)
          if (info['hidden'] != true)
            KernelOption(
              '${info['id']}',
              '${info['displayName'] ?? info['id']}',
              Icons.hub_outlined,
              '${info['description'] ?? ''}',
              group: _group,
              iconBuilder: (size, color) => BrandLogo(
                ModelBrand.ofModel('${info['id']}') ?? 'codex',
                size: size,
                color: color,
              ),
            ),
      ];
    },
    selected: () => _modelInUse ?? _default,
    select: (id) {
      if (id == _model) return;
      _model = id;
      emitInfoChanged();
    },
  );

  List<String> _effortsOf(String? model) => [
    for (final option
        in _info(model)?['supportedReasoningEfforts'] as List? ?? const [])
      if (option case {'reasoningEffort': final String effort}) effort,
  ];

  String? _effortFor(String? model) {
    final efforts = _effortsOf(model);
    if (_effort case final effort? when efforts.contains(effort)) return effort;
    return _info(model)?['defaultReasoningEffort'] as String?;
  }

  @override
  late final ModelSetting effort = _Setting(
    optionsFor: (model) => [
      for (final effort in _effortsOf(model ?? _modelInUse))
        KernelOption(effort, effortLabel(effort), Icons.speed_rounded, ''),
    ],
    selectedFor: (model) => _effortFor(model ?? _modelInUse),
    select: (model, effort) {
      _model = model;
      _effort = effort;
      emitInfoChanged();
    },
  );

  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace and run commands',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  @override
  late final KernelChoiceSource mode = _Choice(
    options: () => _modes,
    selected: () => _mode,
    select: (id) {
      _mode = id;
      emitInfoChanged();
    },
  );

  /// Codex's approval presets: when it asks, and how far its sandbox goes.
  static const _permissions = [
    KernelOption(
      'default',
      'Auto',
      Icons.shield_outlined,
      'Work in the workspace, ask to go beyond it',
    ),
    KernelOption(
      'untrusted',
      'Ask before commands',
      Icons.front_hand_outlined,
      'Ask before any command not known to be safe',
    ),
    KernelOption(
      'full',
      'Full access',
      Icons.warning_amber_rounded,
      'No sandbox, and never ask',
      caution: true,
    ),
  ];

  @override
  late final KernelChoiceSource permission = _Choice(
    options: () => _permissions,
    selected: () => _permission,
    select: (id) {
      _permission = id;
      emitInfoChanged();
    },
  );

  String get _approvalPolicy => _mode == 'ask'
      ? 'never'
      : switch (_permission) {
          'untrusted' => 'untrusted',
          'full' => 'never',
          _ => 'on-request',
        };

  String get _sandbox => _mode == 'ask'
      ? 'read-only'
      : _permission == 'full'
      ? 'danger-full-access'
      : 'workspace-write';

  /// The sandbox the thread was started (or last turn run) with: a turn on
  /// another says which.
  String? _threadSandbox;

  static Map<String, Object?> _sandboxPolicy(String sandbox) =>
      switch (sandbox) {
        'read-only' => {'type': 'readOnly', 'networkAccess': false},
        'danger-full-access' => {'type': 'dangerFullAccess'},
        _ => {
          'type': 'workspaceWrite',
          'writableRoots': const <String>[],
          'networkAccess': false,
          'excludeTmpdirEnvVar': false,
          'excludeSlashTmp': false,
        },
      };

  /// What a thread resumed was on, as the picks show it.
  void _applyThreadSettings(Map<String, Object?> response) {
    if (response['model'] case final String model) _model = model;
    if (response['reasoningEffort'] case final String effort) _effort = effort;
    switch (response['sandbox']) {
      case {'type': 'readOnly'}:
        _mode = 'ask';
        _threadSandbox = 'read-only';
      case {'type': 'dangerFullAccess'}:
        _permission = 'full';
        _threadSandbox = 'danger-full-access';
      case {'type': 'workspaceWrite'}:
        _threadSandbox = 'workspace-write';
        if (response['approvalPolicy'] == 'untrusted') {
          _permission = 'untrusted';
        }
    }
    emitInfoChanged();
  }

  int _contextWindow = 272000;

  @override
  int get contextWindow => _contextWindow;

  static const _builtinCommands = [
    KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
    ),
    KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
      argumentHint: '[instructions]',
    ),
  ];

  /// The skills Codex has for the project, by name: their files.
  Map<String, String> _skills = const {};

  @override
  List<KernelCommand> commands = _builtinCommands;

  @override
  void rename(String title) {
    final threadId = _threadId;
    if (threadId == null) {
      _pendingName = title;
      return;
    }
    unawaited(
      _request('thread/name/set', {
        'threadId': threadId,
        'name': title,
      }).catchError((Object _) => const <String, Object?>{}),
    );
  }

  // --- Account limits ---------------------------------------------------------

  /// The kernels open: the account's limits are told to each.
  static final Set<CodexKernel> _live = {};

  static List<RateLimitWindow> _limits = const [];

  @override
  List<RateLimitWindow> get accountLimits => _limits;

  @override
  Future<void> refreshUsage() async {
    try {
      final usage = await _request('account/rateLimits/read', const {});
      _takeLimits(usage['rateLimits']);
    } on Object {
      // Kept as they were.
    }
  }

  /// From a rate limit snapshot: its windows, by how long each is.
  static void _takeLimits(Object? snapshot) {
    if (snapshot is! Map) return;
    RateLimitWindow? window(Object? value) {
      if (value is! Map || value['usedPercent'] is! num) return null;
      final minutes = (value['windowDurationMins'] as num?)?.toInt();
      return RateLimitWindow(
        switch (minutes) {
          null => 'Limit',
          10080 => 'Weekly limit',
          final m when m % 1440 == 0 => '${m ~/ 1440}-day limit',
          final m when m % 60 == 0 => '${m ~/ 60}-hour limit',
          final m => '$m-minute limit',
        },
        (value['usedPercent'] as num) / 100,
        resetsAt: switch (value['resetsAt']) {
          final num at => DateTime.fromMillisecondsSinceEpoch(
            at.toInt() * 1000,
          ),
          _ => null,
        },
      );
    }

    _limits = [?window(snapshot['primary']), ?window(snapshot['secondary'])];
    for (final kernel in _live) {
      kernel.emit(StatsReported(kernel.nextSeq, UsageStats(limits: _limits)));
    }
  }

  // --- The process ------------------------------------------------------------

  /// [method] once started, and done with what is [_ahead].
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) => _ensureStarted().then((_) => _ahead).then((_) => _call(method, params));

  /// [method] of the server running.
  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> params,
  ) {
    final rpc = _rpc;
    if (rpc == null) return Future.error(const CodexError('', 'Codex stopped'));
    return rpc.call(method, params);
  }

  Future<void> _ensureStarted() {
    if (_disposed) return Future.error(StateError('disposed'));
    if (_running) return Future.value();
    return _starting ??= _launch().whenComplete(() {
      _starting = null;
      if (_releaseWanted) release();
    });
  }

  Future<void> _launch() async {
    // One server at a time on a thread: the last one, if restarted.
    await _stopped;
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    final CodexTransport transport;
    try {
      transport = await _start(_cwd, environment: _context.environment);
    } on CodexUnavailable catch (error) {
      _fail(error.message, error.detail);
      rethrow;
    } on Object catch (error) {
      _fail('Codex did not start', '$error');
      rethrow;
    }
    if (_disposed) {
      transport.close();
      throw StateError('disposed');
    }
    final rpc = CodexRpc(transport);
    _transport = transport;
    _rpc = rpc;
    _subscription = transport.messages.listen(_receive);
    try {
      await rpc
          .call('initialize', CodexCatalog.initializeParams)
          .timeout(const Duration(seconds: 30));
      rpc.notify('initialized');
      unawaited(_refreshModels());
      unawaited(_refreshSkills());
      unawaited(refreshUsage());
      if (_threadId case final threadId?) await _resume(threadId);
      _setHealth(KernelHealth.ready);
    } on Object catch (error) {
      if (_health.status != KernelHealthStatus.failed) {
        _fail('Codex did not start', '$error');
      }
      rethrow;
    }
  }

  /// Follows thread [threadId] on this server: the first time, its
  /// conversation is shown as Codex kept it.
  Future<void> _resume(String threadId) async {
    final resumed = await _call('thread/resume', {
      'threadId': threadId,
      'cwd': _cwd,
      'excludeTurns': true,
    });
    _subscribed = true;
    final thread = (resumed['thread'] as Map?)?.cast<String, Object?>();
    _threadPath = thread?['path'] as String? ?? _threadPath;
    if (_historyShown) return;
    _historyShown = true;
    _applyThreadSettings(resumed);
    try {
      _showHistory(await _turnsBefore(null, _firstTurns));
    } finally {
      _loadingHistory = false;
      emitInfoChanged();
    }
  }

  /// The thread messages go to: started with the first.
  Future<String> _ensureThread() async {
    if (_threadId case final threadId?) {
      if (!_subscribed) await _resume(threadId);
      return threadId;
    }
    final started = await _call('thread/start', {
      'model': ?_modelInUse,
      'cwd': _cwd,
      'approvalPolicy': _approvalPolicy,
      'sandbox': _sandbox,
    });
    final thread = (started['thread'] as Map).cast<String, Object?>();
    final threadId = _threadId = thread['id'] as String;
    _threadPath = thread['path'] as String?;
    _subscribed = true;
    _threadSandbox = _sandbox;
    emitInfoChanged();
    if (_pendingName case final name?) {
      _pendingName = null;
      unawaited(
        _call('thread/name/set', {
          'threadId': threadId,
          'name': name,
        }).catchError((Object _) => const <String, Object?>{}),
      );
    }
    return threadId;
  }

  Future<void> _refreshModels() async {
    final rpc = _rpc;
    if (rpc == null) return;
    try {
      _knownModels = await CodexCatalog.listModels(rpc);
      emitInfoChanged();
    } on Object {
      // Kept as they were.
    }
  }

  /// Asked once, of a server of its own, when a picker is shown before any
  /// session has started.
  static Future<void>? _listing;

  /// As before any server has listed them.
  @visibleForTesting
  static void forgetModels() {
    _knownModels = const [];
    _listing = null;
  }

  void _listModels() {
    _listing ??= CodexCatalog(start: _start).models().then((models) {
      if (models.isEmpty || _knownModels.isNotEmpty) return;
      _knownModels = models;
      for (final kernel in _live) {
        kernel.emitInfoChanged();
      }
    });
  }

  Future<void> _refreshSkills() async {
    try {
      final data = await _call('skills/list', {
        'cwds': [_cwd],
      });
      final skills = <String, String>{};
      final described = <KernelCommand>[];
      for (final entry in data['data'] as List? ?? const []) {
        for (final skill in (entry as Map)['skills'] as List? ?? const []) {
          if (skill case {'name': final String name, 'path': final String path}
              when skill['enabled'] != false && !skills.containsKey(name)) {
            skills[name] = path;
            described.add(
              KernelCommand(
                name,
                skill['shortDescription'] as String? ??
                    skill['description'] as String? ??
                    '',
                Icons.auto_awesome_outlined,
              ),
            );
          }
        }
      }
      _skills = skills;
      commands = [
        ..._builtinCommands,
        ...described.where(
          (command) => !_builtinCommands.any((c) => c.name == command.name),
        ),
      ];
      emitInfoChanged();
    } on Object {
      // Kept as they were.
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
    _rpc?.fail('Codex stopped');
    _rpc = null;
    if (_transport case final transport?) {
      final done = Completer<void>();
      // Gone once its stream ends (its exit message last), or soon anyway.
      transport.messages.listen(
        (_) {},
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object _) {},
      );
      _stopped = done.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      transport.close();
    }
    _transport = null;
    _subscribed = false;
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
    _live.remove(this);
    _teardown();
    closeEvents();
  }

  // --- The conversation -------------------------------------------------------

  final Set<String> _sentTurns = {};

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;
  DateTime? _turnStarted;
  int _unprompted = 0;

  /// The server's turn each of ours became, once it said: null for one it
  /// did not take.
  final Map<String, Future<String?>> _serverTurnOf = {};

  /// The server's turns given up: what they still say is dropped.
  final Set<String> _abandoned = {};

  /// Completes as each server turn waited on ends.
  final Map<String, Completer<void>> _turnEnds = {};

  /// The server's turns of the thread, in order; and the turn each user
  /// message shown began.
  final List<String> _serverTurns = [];
  final Map<String, String> _userTurns = {};

  /// What the turn's requests to the model spent.
  int _turnInput = 0;
  int _turnOutput = 0;
  int? _lastTokenUsageTotal;

  /// Actual output over request time, excluding local tools.
  final OutputMeter _meter = OutputMeter();
  final Set<String> _meterTools = {};
  DateTime? _outputReported;
  static const _outputEvery = Duration(milliseconds: 250);

  /// Messages sent while a turn runs, waiting here for it to end: the next
  /// first.
  final List<KernelTurn> _queue = [];

  /// The message to take up next, ahead of [_queue]: the turn running was
  /// stopped for it.
  KernelTurn? _now;

  /// Messages given the turn running (`turn/steer`), not taken up yet.
  final List<KernelTurn> _steered = [];

  /// What the server must be done with before it is given anything more:
  /// a turn stopping.
  Future<void> _ahead = Future.value();

  /// Turns stopping: until they have, a turn the server starts is not
  /// taken for ours.
  int _stopping = 0;

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
        _serverTurn != null &&
        _stopping == 0 &&
        _command(turn) == null) {
      _steer(turn);
    } else {
      _queue.add(turn);
    }
  }

  /// [turn]'s slash command and what follows it, when it is one of
  /// Codex's own (not a skill's).
  static (String, String)? _command(KernelTurn turn) {
    final text = turn.text.trim();
    for (final name in const ['compact', 'review']) {
      if (text == '/$name' || text.startsWith('/$name ')) {
        return (name, text.substring(name.length + 1).trim());
      }
    }
    return null;
  }

  /// What the user sends, as Codex takes it: a skill named first, the
  /// text and its notes, the pictures.
  List<Map<String, Object?>> _input(KernelTurn turn) {
    var text = turn.text;
    Map<String, Object?>? skill;
    if (RegExp(r'^/(\S+)').firstMatch(text.trimLeft()) case final match?) {
      if (_skills[match.group(1)] case final path?) {
        skill = {'type': 'skill', 'name': match.group(1), 'path': path};
        text = text.trimLeft().substring(match.end).trimLeft();
      }
    }
    return [
      ?skill,
      for (final part in [text, ...turn.notes])
        if (part.isNotEmpty)
          {'type': 'text', 'text': part, 'text_elements': const <Object?>[]},
      for (final image in turn.images)
        {
          'type': 'image',
          'url': 'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
        },
    ];
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
    final started = Completer<String?>();
    _serverTurnOf[turn.id] = started.future;
    // A later stop waits for this request, so this request must not wait for it.
    final ahead = _ahead;
    unawaited(
      _ensureStarted()
          .then((_) => ahead)
          .then<String?>(
            (_) => _disposed || _turn != turn.id ? null : _ensureThread(),
          )
          .then((threadId) {
            if (threadId == null || _disposed || _turn != turn.id) {
              return const <String, Object?>{};
            }
            _meter.begin();
            final command = _command(turn);
            return switch (command) {
              ('compact', _) => _call('thread/compact/start', {
                'threadId': threadId,
              }),
              ('review', final instructions) => _call('review/start', {
                'threadId': threadId,
                'target': instructions.isEmpty
                    ? const {'type': 'uncommittedChanges'}
                    : {'type': 'custom', 'instructions': instructions},
              }),
              _ => _call('turn/start', {
                'threadId': threadId,
                'clientUserMessageId': turn.id,
                'input': _input(turn),
                'model': ?_modelInUse,
                'effort': ?_effortFor(_modelInUse),
                'approvalPolicy': _approvalPolicy,
                if (_sandbox != _threadSandbox)
                  'sandboxPolicy': _sandboxPolicy(_sandbox),
              }),
            }.then((result) {
              if (command == null) _threadSandbox = _sandbox;
              return result;
            });
          })
          .then((result) {
            final serverTurn = switch (result) {
              {'turn': {'id': final String id}} => id,
              _ => null,
            };
            started.complete(serverTurn);
            if (serverTurn == null) return;
            if (_turn == turn.id) {
              _adopt(serverTurn);
              _userTurns[turn.id] = serverTurn;
            }
          })
          .catchError((Object error) {
            if (!started.isCompleted) started.complete(null);
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

  /// Takes the server's turn [serverTurn] for the one under way here.
  void _adopt(String serverTurn) {
    if (_serverTurn != null || _abandoned.contains(serverTurn)) return;
    _serverTurn = serverTurn;
    if (!_serverTurns.contains(serverTurn)) _serverTurns.add(serverTurn);
  }

  /// Gives the turn running [turn], to take up as it goes on.
  void _steer(KernelTurn turn) {
    final (threadId, serverTurn) = (_threadId, _serverTurn);
    if (threadId == null || serverTurn == null) {
      _queue.add(turn);
      return;
    }
    _steered.add(turn);
    unawaited(
      _call('turn/steer', {
        'threadId': threadId,
        'expectedTurnId': serverTurn,
        'clientUserMessageId': turn.id,
        'input': _input(turn),
      }).catchError((Object _) {
        // Not taken: it waits for the turn to end instead.
        if (!_steered.remove(turn)) return const <String, Object?>{};
        if (_turn == null) {
          _startTurn(turn);
        } else {
          _queue.insert(0, turn);
        }
        return const <String, Object?>{};
      }),
    );
  }

  void _beginTurn(String id, {bool unprompted = false}) {
    _turn = id;
    _serverTurn = null;
    _turnStarted = DateTime.now();
    _turnInput = _turnOutput = 0;
    _lastTokenUsageTotal = null;
    _meter.begin();
    _meterTools.clear();
    _outputReported = null;
    emit(TurnStarted(nextSeq, id, unprompted: unprompted));
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    if (_transport != null) _stop(turn);
    _endTurn(interrupted: true);
  }

  /// Interrupts the server's turn for [turn], once it is known: until it
  /// has ended, it is given nothing more.
  void _stop(String turn) {
    final known = _serverTurn;
    final pending = _serverTurnOf[turn];
    _stopping++;
    _ahead = _ahead
        .then((_) async {
          final serverTurn = known ?? await pending;
          final threadId = _threadId;
          if (serverTurn == null || threadId == null || !_running) return;
          _abandoned.add(serverTurn);
          final ended = _turnEnds.putIfAbsent(serverTurn, Completer.new);
          await _call('turn/interrupt', {
            'threadId': threadId,
            'turnId': serverTurn,
          });
          await ended.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
        })
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _stopping--);
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final queued = _queue.indexWhere((turn) => turn.id == turnId);
    if (queued < 0) return false;
    // Steered in, it is the server's: Codex takes none back.
    _queue.removeAt(queued);
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final turn = _queue.where((turn) => turn.id == turnId).firstOrNull;
    if (turn == null) return;
    _queue.remove(turn);
    _now = turn;
    cancel();
  }

  void _endTurn({bool interrupted = false}) {
    final turn = _turn;
    if (turn == null) return;
    _turn = null;
    _serverTurn = null;
    for (final id in [..._reasoning.keys]) {
      _completeThought(id, null);
    }
    for (final id in [..._texts.keys]) {
      _texts.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final MapEntry(key: id, value: request) in _requests.entries) {
      emit(InteractionResolved(nextSeq, id));
      _rpc?.respond(request.rpcId, request.cancel);
    }
    _requests.clear();
    _permissionsAsked.clear();
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
              )
            : null,
      ),
    );
    // Steered in, not taken up: they wait their turn.
    _queue.insertAll(0, _steered);
    _steered.clear();
    if (_now case final now?) {
      _now = null;
      _queue.insert(0, now);
    }
    if (_queue.isNotEmpty && _health.status != KernelHealthStatus.failed) {
      _startTurn(_queue.removeAt(0));
    }
    if (_releaseWanted) release();
  }

  /// Dropped from the thread only once Codex has: turned down, the
  /// conversation is left as it was. The files stay as they are.
  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    final serverTurn = _userTurns[itemId];
    final threadId = _threadId;
    try {
      if (serverTurn == null || threadId == null) {
        throw StateError('Codex does not keep that message');
      }
      cancel();
      await _ahead;
      await _request('thread/revert', {
        'threadId': threadId,
        'beforeTurnId': serverTurn,
      });
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
    final at = _serverTurns.indexOf(serverTurn);
    if (at >= 0) _serverTurns.removeRange(at, _serverTurns.length);
    _userTurns.removeWhere((_, turn) => !_serverTurns.contains(turn));
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  bool get canFork => _threadId != null && _serverTurns.isNotEmpty;

  /// A thread of its own, forked from this one as Codex kept it: a turn
  /// running goes on here alone.
  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    final threadId = _threadId;
    if (threadId == null) return null;
    String? lastTurn;
    try {
      if (_userTurns[before] case final serverTurn?) {
        final at = _serverTurns.indexOf(serverTurn);
        if (at > 0) {
          lastTurn = _serverTurns[at - 1];
        } else if (at == 0 && _earlier != null) {
          // The first shown: the one before it is not read yet.
          lastTurn = await _turnBeforeShown();
        }
      }
      // Omitting lastTurnId copies the whole thread, not an empty prefix.
      if (before != null && lastTurn == null) {
        throw StateError('Codex cannot fork before that message');
      }
      final forked = await _request('thread/fork', {
        'threadId': threadId,
        'lastTurnId': ?lastTurn,
        'excludeTurns': true,
      });
      final thread = (forked['thread'] as Map).cast<String, Object?>();
      final id = thread['id'] as String;
      await _call('thread/name/set', {'threadId': id, 'name': title});
      // Followed here as it was forked: it is another session's.
      unawaited(
        _call('thread/unsubscribe', {
          'threadId': id,
        }).catchError((Object _) => const <String, Object?>{}),
      );
      return SessionRecord(
        id: id,
        title: title,
        updatedAt: DateTime.now(),
        cwd: _cwd,
        path: thread['path'] as String?,
      );
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'fork:${before ?? threadId}',
          NoticeItem(NoticeKind.error, 'Could not fork: $error'),
        ),
      );
      return null;
    }
  }

  // --- Translation ------------------------------------------------------------

  final Map<String, int> _texts = {};
  final Map<String, ({StringBuffer text, DateTime started})> _reasoning = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};

  /// Commands started and not completed yet, as they started; and when.
  final Map<String, Map<String, Object?>> _commands = {};
  final Map<String, DateTime> _startedAt = {};

  /// The changes of each patch proposed, as it started: shown when it asks
  /// leave to apply them.
  final Map<String, List<Map<String, Object?>>> _patches = {};

  /// Requests of the server's awaiting the user: our id → its JSON-RPC id,
  /// what it is answered with if the turn ends first, and for a form, its
  /// fields.
  final Map<
    String,
    ({
      Object? rpcId,
      String method,
      Map<String, Object?> cancel,
      List<String> questions,
      List<ElicitationField>? fields,
    })
  >
  _requests = {};

  void _receive(Map<String, Object?> message) {
    final rpc = _rpc;
    if (rpc == null || rpc.receive(message)) return;
    final method = message['method'] as String?;
    final params =
        (message['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method == CodexExit.method) {
      _exited(params['stderr'] as String? ?? '');
      return;
    }
    // Another thread's (one forked, say): not this session's.
    if (params['threadId'] case final String thread when thread != _threadId) {
      if (message.containsKey('id')) rpc.refuse(message['id'], 'not followed');
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method ?? '', params);
      return;
    }
    switch (method) {
      case 'turn/started':
        final id = (params['turn'] as Map?)?['id'] as String?;
        if (id == null || _abandoned.contains(id) || _stopping > 0) return;
        if (_turn == null) {
          // Taken up by Codex on its own.
          _beginTurn('codex-turn:${++_unprompted}', unprompted: true);
        }
        _adopt(id);
      case 'turn/completed':
        final turn = (params['turn'] as Map?)?.cast<String, Object?>() ?? {};
        final id = turn['id'] as String?;
        _turnEnds.remove(id)?.complete();
        if (id == null || id != _serverTurn) return;
        if (turn case {
          'status': 'failed',
          'error': {'message': final message},
        }) {
          emit(
            ItemUpserted(
              nextSeq,
              'error:$id',
              NoticeItem(NoticeKind.error, '$message'),
            ),
          );
        }
        _endTurn(interrupted: turn['status'] == 'interrupted');
      case 'thread/tokenUsage/updated':
        _tokenUsage(params);
      case 'account/rateLimits/updated':
        _takeLimits(params['rateLimits']);
      case 'turn/plan/updated' when _ofTurn(params):
        emit(
          TodosReported(nextSeq, [
            for (final step in params['plan'] as List? ?? const [])
              if (step case {'step': final String text})
                TodoEntry(text, switch (step['status']) {
                  'completed' => TodoStatus.completed,
                  'inProgress' => TodoStatus.inProgress,
                  _ => TodoStatus.pending,
                }),
          ]),
        );
      case 'error' when _ofTurn(params):
        final error = (params['error'] as Map?) ?? const {};
        final retry = params['willRetry'] == true;
        emit(
          ItemUpserted(
            nextSeq,
            retry
                ? 'retry:${DateTime.now().microsecondsSinceEpoch}'
                : 'error:${params['turnId']}',
            NoticeItem(
              retry ? NoticeKind.retry : NoticeKind.error,
              [
                '${error['message'] ?? 'Codex failed'}',
                ?error['additionalDetails'] as String?,
              ].join('\n'),
            ),
          ),
        );
      case 'warning' || 'configWarning':
        if (params['message'] ?? params['summary'] case final String text) {
          emit(
            ItemUpserted(
              nextSeq,
              'warning:${DateTime.now().microsecondsSinceEpoch}',
              NoticeItem(NoticeKind.warning, text),
            ),
          );
        }
      case 'mcpServer/startupStatus/updated':
        _serverStarting(params);
      case 'mcpServer/oauthLogin/completed':
        refreshMcpServers();
      case 'serverRequest/resolved':
        final id = 'codex-request:${params['requestId']}';
        if (_requests.remove(id) != null) {
          _resumeMeter();
          emit(InteractionResolved(nextSeq, id));
        }
      case 'item/started' when _ofTurn(params):
        _itemStarted((params['item'] as Map).cast<String, Object?>());
      case 'item/completed' when _ofTurn(params):
        _itemCompleted((params['item'] as Map).cast<String, Object?>());
      case 'item/agentMessage/delta' when _ofTurn(params):
        final id = params['itemId'] as String;
        final offset = _texts[id];
        if (offset == null) return;
        final delta = params['delta'] as String? ?? '';
        _texts[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
        _metered(delta);
      case 'item/reasoning/summaryTextDelta' || 'item/reasoning/textDelta'
          when _ofTurn(params):
        final id = params['itemId'] as String;
        final thought = _reasoning[id];
        if (thought == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null &&
            thought.text.isNotEmpty &&
            part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
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
        _metered(delta);
      case 'item/commandExecution/outputDelta' when _ofTurn(params):
        final id = params['itemId'] as String;
        final command = _commands[id];
        if (command == null) return;
        final output =
            '${command['aggregatedOutput'] ?? ''}${params['delta'] ?? ''}';
        _commands[id] = {...command, 'aggregatedOutput': output};
        emit(ItemUpserted(nextSeq, id, _commandItem(_commands[id]!)));
    }
  }

  /// Whether the notification [params] is of the turn under way here (its
  /// server turn, taken for it if not known yet).
  bool _ofTurn(Map<String, Object?> params) {
    if (_turn == null) return false;
    final turnId = params['turnId'];
    if (turnId is! String) return true;
    if (_abandoned.contains(turnId)) return false;
    if (_stopping == 0) _adopt(turnId);
    return turnId == _serverTurn;
  }

  void _exited(String stderr) {
    _teardown();
    final detail = stderr.trim();
    // Failed before the turn ends: nothing queued is taken up then.
    _setHealth(
      KernelHealth(
        KernelHealthStatus.failed,
        message: 'Codex stopped',
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
            detail.isEmpty ? 'Codex stopped' : 'Codex stopped:\n$detail',
          ),
        ),
      );
      _endTurn(interrupted: true);
    }
  }

  void _tokenUsage(Map<String, Object?> params) {
    final usage = (params['tokenUsage'] as Map?) ?? const {};
    if (usage['modelContextWindow'] case final int window) {
      _contextWindow = window;
    }
    final last = (usage['last'] as Map?) ?? const {};
    int count(String key) => (last[key] as num?)?.toInt() ?? 0;
    emit(
      UsageReported(
        nextSeq,
        // The last request's, which is what the context holds; the total
        // adds up every request, and never drops on compacting.
        ContextUsage(window: _contextWindow, used: count('totalTokens')),
      ),
    );
    if (!_ofTurn(params)) return;
    final output = switch (last['outputTokens']) {
      final num tokens when tokens.isFinite && tokens >= 0 => tokens.toInt(),
      _ => null,
    };
    // A partial snapshot must not finish the request or lose its waiting time.
    if (output == null) return;
    final total = switch ((usage['total'] as Map?)?['totalTokens']) {
      final num tokens when tokens.isFinite && tokens >= 0 => tokens.toInt(),
      _ => null,
    };
    if (total != null && total == _lastTokenUsageTotal) return;
    _lastTokenUsageTotal = total;
    // Each request's as it ends: what the turn spent is theirs summed.
    _turnInput += count('inputTokens');
    _turnOutput += output;
    _meter.endMessage(tokens: output);
    _outputReported = DateTime.now();
    emit(OutputReported(nextSeq, _meter.output));
  }

  /// Estimates the live count; speed waits for the actual usage.
  void _metered(String text) {
    _meter.streamed(text);
    final now = DateTime.now();
    if (_outputReported case final at? when now.difference(at) < _outputEvery) {
      return;
    }
    _outputReported = now;
    emit(OutputReported(nextSeq, _meter.output));
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      // Hosted web search remains part of the upstream request.
      case 'commandExecution' ||
          'fileChange' ||
          'mcpToolCall' ||
          'dynamicToolCall' ||
          'imageView':
        _meterTools.add(id);
        _meter.pause();
    }
    switch (item['type']) {
      case 'userMessage':
        // A message steered in, taken up: after what came before it.
        final index = _steered.indexWhere(
          (turn) => turn.id == item['clientId'],
        );
        if (index < 0) return;
        final turn = _steered.removeAt(index);
        emit(
          ItemUpserted(
            nextSeq,
            turn.id,
            UserMessageItem(text: turn.text, images: turn.images),
          ),
        );
      case 'reasoning':
        final started = DateTime.now();
        _reasoning[id] = (text: StringBuffer(), started: started);
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: started),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _texts[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
      case 'fileChange':
        _patches[id] = [
          for (final change in item['changes'] as List? ?? const [])
            if (change is Map) change.cast(),
        ];
      case 'mcpToolCall' || 'webSearch' || 'dynamicToolCall':
        emit(ItemUpserted(nextSeq, id, _toolItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item, {bool history = false}) {
    final id = item['id'] as String;
    if (!history && _meterTools.remove(id)) _resumeMeter();
    switch (item['type']) {
      case 'reasoning':
        final text = [...?(item['summary'] as List?)?.whereType<String>()]
            .join('\n\n');
        _completeThought(id, text.isEmpty ? null : text, history: history);
      case 'agentMessage':
        _texts.remove(id);
        final text = item['text'] as String? ?? '';
        if (history) {
          if (text.trim().isNotEmpty) {
            emit(ItemUpserted(nextSeq, id, AssistantTextItem(text)));
          }
        } else {
          emit(ItemCompleted(nextSeq, id, item: AssistantTextItem(text)));
        }
      case 'commandExecution':
        _commands.remove(id);
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
      case 'fileChange':
        _patches.remove(id);
        final changes = item['changes'] as List? ?? const [];
        final applied = item['status'] == 'completed';
        for (final (index, change) in changes.indexed) {
          if (change is! Map) continue;
          _fileChange(
            '$id:$index',
            change['path'] as String? ?? '',
            change['diff'] as String? ?? '',
            kind: (change['kind'] as Map?)?['type'] as String?,
            edited: applied && !history,
          );
        }
      case 'mcpToolCall' || 'webSearch' || 'dynamicToolCall' || 'imageView':
        emit(ItemUpserted(nextSeq, id, _toolItem(item)));
      case 'contextCompaction':
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
          ),
        );
      case 'exitedReviewMode':
        if (item['review'] case final String review
            when review.trim().isNotEmpty) {
          emit(ItemUpserted(nextSeq, id, AssistantTextItem(review)));
        }
    }
  }

  void _resumeMeter() {
    if (_meterTools.isEmpty && _requests.isEmpty) _meter.resume();
  }

  void _completeThought(String id, String? summary, {bool history = false}) {
    final thought = _reasoning.remove(id);
    _reasoningPart.remove(id);
    final text = summary ?? thought?.text.toString() ?? '';
    if (history && text.trim().isEmpty) return;
    final thinking = ThinkingItem(
      text: text,
      tokens: text.length ~/ 4,
      seconds: switch (thought) {
        (:final started, text: _) => math.max(
          1,
          (DateTime.now().difference(started).inMilliseconds / 1000).round(),
        ),
        null => 1,
      },
    );
    emit(
      thought == null
          ? ItemUpserted(nextSeq, id, thinking)
          : ItemCompleted(nextSeq, id, item: thinking),
    );
  }

  /// The command itself, out of the shell Codex runs it in
  /// (`/bin/zsh -lc ls`): as its parts say, else as it was run.
  static String _commandText(Map<String, Object?> item) {
    final parts = [
      for (final action in item['commandActions'] as List? ?? const [])
        if (action case {'command': final String command}) command,
    ];
    if (parts.isNotEmpty) return parts.join(' && ');
    final command = item['command'] as String? ?? '';
    final shell = RegExp(r'''^\S*/(?:ba|z)?sh -l?c (['"]?)(.*)\1$''');
    return shell.firstMatch(command)?.group(2) ?? command;
  }

  /// A command as the history shows it: reads, listings and searches as
  /// tool rows, anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List? ?? const [])
        if (action is Map) action.cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final status = switch (item['status']) {
      'completed' when (item['exitCode'] ?? 0) == 0 => ToolStatus.succeeded,
      'completed' || 'failed' || 'declined' => ToolStatus.failed,
      _ => ToolStatus.running,
    };
    final done = status != ToolStatus.running;
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = _absolute(actions.first['path'] as String? ?? '');
      return ToolCallItem(
        kind: ToolKind.read,
        target: p.basename(path),
        path: path,
        status: status,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String? ?? _commandText(item),
        detail: done ? '${matches.length} results' : null,
        results: matches,
        status: status,
      );
    }
    if (actions.length == 1 && actions.single['type'] == 'listFiles') {
      return ToolCallItem(
        kind: ToolKind.listDir,
        target: actions.single['path'] as String? ?? '.',
        output: output,
        status: status,
      );
    }
    return TerminalItem(
      command: _commandText(item),
      output: output ?? '',
      status: switch (status) {
        ToolStatus.running => CommandStatus.running,
        ToolStatus.succeeded => CommandStatus.succeeded,
        _ => CommandStatus.failed,
      },
      startedAt: _startedAt[item['id']],
    );
  }

  /// A tool of Codex's other than a command or a patch, as its row.
  ChatItem _toolItem(Map<String, Object?> item) {
    final status = switch (item['status']) {
      'completed' when item['success'] != false => ToolStatus.succeeded,
      'failed' || 'completed' => ToolStatus.failed,
      null => ToolStatus.succeeded,
      _ => ToolStatus.running,
    };
    final arguments = item['arguments'];
    return switch (item['type']) {
      'webSearch' => ToolCallItem(
        kind: ToolKind.web,
        target: item['query'] as String? ?? '',
        status: status,
      ),
      'imageView' => ToolCallItem(
        kind: ToolKind.read,
        target: p.basename(item['path'] as String? ?? ''),
        path: _absolute(item['path'] as String? ?? ''),
        status: ToolStatus.succeeded,
      ),
      _ => ToolCallItem(
        kind: item['type'] == 'mcpToolCall' ? ToolKind.mcp : ToolKind.other,
        target: arguments is Map
            ? arguments.values.whereType<String>().firstOrNull ?? ''
            : '',
        label: [?item['server'] as String?, '${item['tool']}'].join(' · '),
        tool: '${item['tool']}',
        input: arguments is Map ? arguments.cast() : const {},
        output: switch (item) {
          {'result': {'content': final List<Object?> content}} => [
            for (final block in content)
              if (block case {'type': 'text', 'text': final String text}) text,
          ].join('\n'),
          {'error': {'message': final String message}} => message,
          _ => null,
        },
        status: status,
      ),
    };
  }

  /// The lines of [diff], numbered as in the file: a file added or deleted
  /// ([kind]) has its whole text for a diff.
  static List<DiffLine> _diffLines(String diff, String? kind) {
    if (kind == 'add' || kind == 'delete') {
      final text = diff.endsWith('\n')
          ? diff.substring(0, diff.length - 1)
          : diff;
      return [
        for (final (index, line) in text.split('\n').indexed)
          DiffLine(
            kind == 'add' ? DiffLineType.added : DiffLineType.removed,
            index + 1,
            line,
          ),
      ];
    }
    final lines = <DiffLine>[];
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty ||
          line.startsWith(r'\') ||
          line.startsWith('--- ') ||
          line.startsWith('+++ ')) {
        continue;
      }
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

  /// A patch's change to one file as its diff card; [edited], a change to
  /// review too.
  void _fileChange(
    String id,
    String path,
    String diff, {
    String? kind,
    required bool edited,
  }) {
    final absolute = _absolute(path);
    final lines = _diffLines(diff, kind);
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: p.basename(absolute),
          directory: p.dirname(absolute),
          lines: lines,
        ),
      ),
    );
    if (!edited) return;
    emit(
      FileEdited(
        nextSeq,
        FileChange(
          path: absolute,
          added: lines.where((l) => l.type == DiffLineType.added).length,
          removed: lines.where((l) => l.type == DiffLineType.removed).length,
        ),
        turnId: _turn,
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  String _absolute(String path) =>
      path.isEmpty || p.isAbsolute(path) ? path : p.join(_cwd, path);

  // --- MCP servers ------------------------------------------------------------

  List<McpServer>? _servers;

  /// The servers the user configured, by name: the file each is in, and
  /// its layer (`user`, `project`…).
  Map<String, ({String file, String scope})> _configured = const {};

  @override
  List<McpServer>? get mcpServers => _servers;

  @override
  void refreshMcpServers() => unawaited(_listServers().catchError((_) {}));

  Future<void> _listServers() async {
    final config = await _request('config/read', {
      'cwd': _cwd,
      'includeLayers': true,
    });
    _configured = _configuredServers(config['origins']);
    final settings = switch (config['config']) {
      {'mcp_servers': final Map<Object?, Object?> servers} => servers,
      _ => const <Object?, Object?>{},
    };
    final servers = <McpServer>[];
    String? cursor;
    do {
      final page = await _request('mcpServerStatus/list', {
        'detail': 'toolsAndAuthOnly',
        'threadId': ?_threadId,
        'cursor': ?cursor,
      });
      for (final raw in page['data'] as List? ?? const []) {
        if (raw is Map) {
          final name = '${raw['name']}';
          servers.add(_server(raw.cast(), settings[name]));
        }
      }
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    if (_disposed) return;
    _servers = servers;
    emitInfoChanged();
  }

  /// Where each server configured is, as `config/read` traces its keys
  /// (`mcp_servers.<name>.command`) to their files.
  static Map<String, ({String file, String scope})> _configuredServers(
    Object? origins,
  ) => {
    if (origins is Map)
      for (final MapEntry(:key, :value) in origins.entries)
        if ((key, value)
            case (
              final String key,
              {'name': {'file': final String file, 'type': final String scope}},
            )
            when key.startsWith('mcp_servers.'))
          key.split('.')[1]: (file: file, scope: scope),
  };

  McpServer _server(Map<String, Object?> raw, Object? settings) {
    final name = '${raw['name']}';
    final error = raw['toolsError'] as String?;
    final configured = _configured[name];
    return McpServer(
      name: name,
      status: switch (raw['runtimeStatus']) {
        'connected' => McpServerStatus.connected,
        'authenticationRequired' => McpServerStatus.needsAuth,
        'failed' || 'cancelled' => McpServerStatus.failed,
        'disabled' => McpServerStatus.disabled,
        'starting' || 'notStarted' => McpServerStatus.pending,
        // No thread yet: as listing it found it.
        _ when settings is Map && settings['enabled'] == false =>
          McpServerStatus.disabled,
        _ when error != null => McpServerStatus.failed,
        _ when raw['authStatus'] == 'notLoggedIn' => McpServerStatus.needsAuth,
        _ => McpServerStatus.connected,
      },
      error: error,
      scope: configured?.scope ?? (raw['pluginId'] == null ? null : 'plugin'),
      version: (raw['serverInfo'] as Map?)?['version'] as String?,
      tools: [...(raw['tools'] as Map? ?? const {}).keys.map((t) => '$t')],
      // A plugin's, or Codex's own: not the user's to turn off here.
      toggles: configured != null && !name.contains('.'),
    );
  }

  /// A server of the thread's starting, up, or failing.
  void _serverStarting(Map<String, Object?> params) {
    final name = params['name'];
    if (name is! String) return;
    final failed = switch (params) {
      {'failureReason': 'reauthenticationRequired'} =>
        McpServerStatus.needsAuth,
      _ => McpServerStatus.failed,
    };
    _setServerStatus(name, switch (params['status']) {
      'ready' => McpServerStatus.connected,
      'failed' || 'cancelled' => failed,
      _ => McpServerStatus.pending,
    }, error: params['error'] as String?);
  }

  @override
  void setMcpServerEnabled(String name, bool enabled) {
    final configured = _configured[name];
    if (configured == null) return;
    _setServerStatus(
      name,
      enabled ? McpServerStatus.pending : McpServerStatus.disabled,
    );
    _reloadServers(
      () => _request('config/value/write', {
        'keyPath': 'mcp_servers.$name.enabled',
        'value': enabled,
        'mergeStrategy': 'upsert',
        'filePath': configured.file,
      }),
    );
  }

  /// Codex starts its servers again, the failed ones too.
  @override
  void reconnectMcpServer(String name) {
    _setServerStatus(name, McpServerStatus.pending);
    _reloadServers();
  }

  @override
  Future<Uri?> authenticateMcpServer(String name) async {
    final response = await _request('mcpServer/oauth/login', {
      'name': name,
      'threadId': ?_threadId,
    });
    final url = Uri.tryParse('${response['authorizationUrl'] ?? ''}');
    if (url == null || !url.hasScheme) {
      refreshMcpServers();
      return null;
    }
    // Codex takes the callback, and says so once signed in.
    return url;
  }

  /// After [change] (if any), has Codex take up its servers' configuration
  /// again; then reports where they stand.
  void _reloadServers([Future<Object?> Function()? change]) {
    unawaited(
      (change?.call() ?? Future.value())
          .then((_) => _request('config/mcpServer/reload', const {}))
          .then((_) {}, onError: (Object _) {})
          .whenComplete(refreshMcpServers),
    );
  }

  /// Shows [name] as [status] until Codex says otherwise.
  void _setServerStatus(String name, McpServerStatus status, {String? error}) {
    final servers = _servers;
    if (servers == null) return;
    _servers = [
      for (final server in servers)
        server.name == name
            ? McpServer(
                name: server.name,
                status: status,
                error: status == McpServerStatus.failed
                    ? error ?? server.error
                    : null,
                scope: server.scope,
                version: server.version,
                tools: server.tools,
                toggles: server.toggles,
              )
            : server,
    ];
    emitInfoChanged();
  }

  // --- History ----------------------------------------------------------------

  /// Turns shown of the thread resumed at first, then on each asking for
  /// more: as Claude Code's.
  static const _firstTurns = 10;
  static const _earlierTurns = 20;

  bool _loadingHistory;

  /// Where Codex goes on listing the turns before those shown, if there
  /// are some.
  String? _earlier;
  Future<void>? _earlierLoad;

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
  bool get hasEarlierHistory => _earlier != null && !_loadingHistory;

  @override
  bool get loadingEarlier => _earlierLoad != null;

  @override
  Future<void> loadEarlier() {
    if (_earlier == null || _disposed) return Future.value();
    return _earlierLoad ??= _readEarlier().whenComplete(() {
      _earlierLoad = null;
      if (!_disposed) emitInfoChanged();
    });
  }

  Future<void> _readEarlier() async {
    emitInfoChanged();
    final List<Map<String, Object?>> turns;
    try {
      await _ensureStarted();
      turns = await _turnsBefore(_earlier, _earlierTurns);
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'history-error',
          NoticeItem(NoticeKind.error, 'Could not read earlier: $error'),
        ),
      );
      return;
    }
    if (_disposed) return;
    final items = _gathering = {};
    try {
      _showHistory(turns, earlier: true);
    } finally {
      _gathering = null;
    }
    emit(
      HistoryPrepended(nextSeq, [
        ...items.entries.map((e) => (e.key, e.value)),
      ]),
    );
  }

  /// The [limit] turns before [cursor] (the last ones, when null), oldest
  /// first, of the server running; where to list those before them next is
  /// kept in [_earlier].
  Future<List<Map<String, Object?>>> _turnsBefore(
    String? cursor,
    int limit,
  ) async {
    final page = await _call('thread/turns/list', {
      'threadId': _threadId,
      'cursor': ?cursor,
      'limit': limit,
      'sortDirection': 'desc',
      'itemsView': 'full',
    });
    _earlier = page['nextCursor'] as String?;
    return [
      for (final turn in (page['data'] as List? ?? const []).reversed)
        if (turn is Map) turn.cast<String, Object?>(),
    ];
  }

  /// The id of the turn before those shown, not shown yet itself.
  Future<String?> _turnBeforeShown() async {
    final page = await _request('thread/turns/list', {
      'threadId': _threadId,
      'cursor': _earlier,
      'limit': 1,
      'sortDirection': 'desc',
      'itemsView': 'notLoaded',
    });
    return ((page['data'] as List?)?.firstOrNull as Map?)?['id'] as String?;
  }

  /// The conversation of the thread resumed, as Codex kept it: turns
  /// [earlier] than those shown go before them.
  void _showHistory(List<Map<String, Object?>> turns, {bool earlier = false}) {
    final shown = <String>[];
    for (final turn in turns) {
      final turnId = turn['id'] as String?;
      if (turnId == null) continue;
      shown.add(turnId);
      var first = true;
      for (final item in turn['items'] as List? ?? const []) {
        if (item is! Map) continue;
        final entry = item.cast<String, Object?>();
        if (entry['type'] == 'userMessage') {
          final id = entry['id'] as String;
          final text = [
            for (final part in entry['content'] as List? ?? const [])
              if (part case {'type': 'text', 'text': final String text}) text,
          ].join('\n');
          // The turn begins with the first; those after were steered in.
          if (first) _userTurns[id] = turnId;
          first = false;
          if (text.isNotEmpty) {
            emit(ItemUpserted(nextSeq, id, UserMessageItem(text: text)));
          }
        } else {
          _itemCompleted(entry, history: true);
        }
      }
    }
    _serverTurns.insertAll(earlier ? 0 : _serverTurns.length, shown);
  }

  // --- Requests of the server's -----------------------------------------------

  static const _alwaysLabel = 'Approve for this session';

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    final rpc = _rpc!;
    final id = 'codex-request:$rpcId';
    // Of a turn given up: it is over.
    if (params['turnId'] case final String turn
        when _abandoned.contains(turn)) {
      rpc.respond(rpcId, const {'decision': 'cancel'});
      return;
    }
    final InteractionRequest request;
    var cancel = const <String, Object?>{'decision': 'cancel'};
    var questions = const <String>[];
    List<ElicitationField>? fields;
    switch (method) {
      case 'item/commandExecution/requestApproval':
        final command = switch (params['commandActions']) {
          final List<Object?> actions when actions.isNotEmpty => _commandText({
            'commandActions': actions,
          }),
          _ => _commandText({'command': params['command']}),
        };
        request = ApprovalRequest(
          id: id,
          title: 'Run command',
          toolName: 'commandExecution',
          reason: params['reason'] as String?,
          preview: CommandPreview(
            command,
            description: params['cwd'] as String?,
          ),
          alwaysAllowLabel: _alwaysLabel,
        );
      case 'item/fileChange/requestApproval':
        final changes = _patches[params['itemId']] ?? const [];
        final first = changes.firstOrNull;
        request = ApprovalRequest(
          id: id,
          title: 'Apply changes',
          toolName: 'fileChange',
          reason: params['reason'] as String?,
          preview: first == null
              ? null
              : DiffPreview(
                  _absolute(first['path'] as String? ?? ''),
                  _diffLines(
                    first['diff'] as String? ?? '',
                    (first['kind'] as Map?)?['type'] as String?,
                  ),
                ),
          alwaysAllowLabel: _alwaysLabel,
        );
      case 'item/permissions/requestApproval':
        cancel = const {'permissions': {}, 'scope': 'turn'};
        _permissionsAsked[id] = params['permissions'];
        request = ApprovalRequest(
          id: id,
          title: 'Grant permissions',
          toolName: 'permissions',
          reason: params['reason'] as String?,
          preview: TextPreview(
            const JsonEncoder.withIndent('  ').convert(params['permissions']),
          ),
          alwaysAllowLabel: _alwaysLabel,
        );
      case 'item/tool/requestUserInput':
        cancel = const {'answers': {}};
        final asked = [
          for (final question in params['questions'] as List? ?? const [])
            if (question is Map) question.cast<String, Object?>(),
        ];
        questions = [for (final q in asked) '${q['id']}'];
        request = QuestionRequest(
          id: id,
          title: 'Codex asks',
          questions: [
            for (final question in asked)
              Question(
                prompt: '${question['question'] ?? ''}',
                header: '${question['header'] ?? ''}',
                options: [
                  for (final option in question['options'] as List? ?? const [])
                    if (option case {'label': final String label})
                      QuestionOption(
                        label,
                        description: option['description'] as String? ?? '',
                      ),
                ],
                allowOther:
                    question['isOther'] == true ||
                    (question['options'] as List?)?.isEmpty != false,
              ),
          ],
        );
      case 'mcpServer/elicitation/request' when params['mode'] != 'url':
        cancel = const {'action': 'cancel', 'content': null, '_meta': null};
        fields = elicitationFields(params['requestedSchema']);
        request = QuestionRequest(
          id: id,
          title: '${params['serverName'] ?? 'MCP'} asks for input',
          questions: elicitationQuestions(
            params['message'] as String? ?? '',
            fields,
          ),
        );
      default:
        rpc.refuse(rpcId, 'BaoCode does not handle $method');
        return;
    }
    _requests[id] = (
      rpcId: rpcId,
      method: method,
      cancel: cancel,
      questions: questions,
      fields: fields,
    );
    _meter.pause();
    emit(InteractionRequested(nextSeq, request));
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final request = _requests.remove(requestId);
    final rpc = _rpc;
    if (request == null) return;
    emit(InteractionResolved(nextSeq, requestId));
    if (rpc == null) return;
    final allow = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    rpc.respond(request.rpcId, switch (request.method) {
      'item/permissions/requestApproval' => {
        'permissions': switch (_permissionsAsked.remove(requestId)) {
          final Map<Object?, Object?> asked when allow != 'decline' => {
            for (final MapEntry(:key, :value) in asked.entries) '$key': ?value,
          },
          _ => const <String, Object?>{},
        },
        'scope': allow == 'acceptForSession' ? 'session' : 'turn',
      },
      'item/tool/requestUserInput' => {
        'answers': {
          if (answer case QuestionAnswer(skipped: false, :final picks))
            for (final (index, question) in request.questions.indexed)
              question: {
                'answers': index < picks.length ? picks[index] : const [],
              },
        },
      },
      'mcpServer/elicitation/request' => switch (answer) {
        QuestionAnswer() => {
          ...elicitationResult(request.fields ?? const [], answer),
          '_meta': null,
        },
        _ => request.cancel,
      },
      _ => {'decision': allow},
    });
    _resumeMeter();
  }

  /// What each request for permissions asked for: granted as asked.
  final Map<String, Object?> _permissionsAsked = {};
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

/// The reasoning effort, by model: each offers its own.
class _Setting implements ModelSetting {
  _Setting({
    required this._optionsFor,
    required this._selectedFor,
    required this._select,
  });

  final List<KernelOption> Function(String? model) _optionsFor;
  final String? Function(String? model) _selectedFor;
  final void Function(String model, String id) _select;

  @override
  bool get toggle => false;

  @override
  List<KernelOption> optionsFor(String model) => _optionsFor(model);

  @override
  String? get selected => _selectedFor(null);

  @override
  String? selectedFor(String model) => _selectedFor(model);

  @override
  void select(String model, String id) => _select(model, id);
}
