import 'dart:async';

import '../agent_kernel.dart';
import 'codex_rpc.dart';
import 'codex_transport.dart';

/// Codex's own record of its threads, as `codex app-server` lists them: a
/// server is started for each look, and let go after it.
class CodexCatalog implements SessionCatalog {
  const CodexCatalog({this.start = startCodexProcess});

  final CodexTransportFactory start;

  /// How many threads are listed at most, newest first.
  static const _limit = 500;
  static const _page = 100;

  /// Threads the user started, not those agents spawned for themselves.
  static const _sources = ['cli', 'vscode', 'exec', 'appServer'];

  @override
  Future<List<ProjectRecord>> projects() async {
    final byFolder = <String, List<SessionRecord>>{};
    for (final session in await _list()) {
      (byFolder[session.cwd] ??= []).add(session);
    }
    return [
      for (final MapEntry(key: path, value: sessions) in byFolder.entries)
        ProjectRecord(path: path, sessions: sessions),
    ];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) => _list(cwd: cwd);

  @override
  Future<void> delete(String id) async {
    try {
      await _with((rpc) => rpc.call('thread/delete', {'threadId': id}));
    } on Object {
      // Gone already, or Codex is not there to ask.
    }
  }

  /// The models Codex offers, for a picker shown before any session has
  /// started: none if Codex is not there to ask.
  Future<List<Map<String, Object?>>> models() async {
    try {
      return await _with(listModels);
    } on Object {
      return const [];
    }
  }

  /// The models the server of [rpc] offers, every page of them.
  static Future<List<Map<String, Object?>>> listModels(CodexRpc rpc) async {
    final models = <Map<String, Object?>>[];
    String? cursor;
    do {
      final page = await rpc.call('model/list', {'cursor': ?cursor});
      for (final model in page['data'] as List? ?? const []) {
        if (model is Map) models.add(model.cast());
      }
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    return models;
  }

  Future<List<SessionRecord>> _list({String? cwd}) async {
    try {
      return await _with((rpc) async {
        final sessions = <SessionRecord>[];
        String? cursor;
        do {
          final page = await rpc.call('thread/list', {
            'limit': _page,
            'cursor': ?cursor,
            'sortKey': 'updated_at',
            'sourceKinds': _sources,
            'cwd': ?cwd,
          });
          for (final thread in page['data'] as List? ?? const []) {
            if (thread is Map) {
              if (record(thread.cast()) case final session?) {
                sessions.add(session);
              }
            }
          }
          cursor = page['nextCursor'] as String?;
        } while (cursor != null && sessions.length < _limit);
        return sessions;
      });
    } on Object {
      return const [];
    }
  }

  /// Runs [body] on a server of its own, started and initialized for it.
  Future<T> _with<T>(Future<T> Function(CodexRpc rpc) body) async {
    final transport = await start('.');
    final rpc = CodexRpc(transport);
    final subscription = transport.messages.listen((message) {
      if (message['method'] == CodexExit.method) {
        rpc.fail('Codex stopped');
      } else if (!rpc.receive(message) && message.containsKey('id')) {
        // A request of the server's: none is expected of a listing.
        rpc.refuse(message['id'], 'not supported');
      }
    });
    try {
      await rpc.call('initialize', initializeParams);
      rpc.notify('initialized');
      return await body(rpc).timeout(const Duration(seconds: 30));
    } finally {
      unawaited(subscription.cancel());
      transport.close();
    }
  }

  /// Who is asking, as `initialize` tells Codex.
  static const initializeParams = {
    'clientInfo': {'name': 'baocode', 'title': 'BaoCode', 'version': '1.0.0'},
    'capabilities': {'experimentalApi': false, 'requestAttestation': false},
  };

  /// [thread] as the catalog lists it: titled by its name, else its first
  /// message. Null for one not kept (ephemeral) or of no folder.
  static SessionRecord? record(Map<String, Object?> thread) {
    final id = thread['id'];
    final cwd = thread['cwd'];
    if (id is! String || cwd is! String || thread['ephemeral'] == true) {
      return null;
    }
    final name = thread['name'] as String?;
    return SessionRecord(
      id: id,
      title: _oneLine(
        name != null && name.isNotEmpty
            ? name
            : thread['preview'] as String? ?? '',
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        ((thread['updatedAt'] as num?) ?? 0).toInt() * 1000,
      ),
      cwd: cwd,
      path: thread['path'] as String?,
    );
  }

  static String _oneLine(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 100 ? line : '${line.substring(0, 99)}…';
  }
}
