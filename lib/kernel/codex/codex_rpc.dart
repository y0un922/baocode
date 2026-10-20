import 'dart:async';

import 'codex_transport.dart';

/// A request to `codex app-server` turned down, or not answered.
class CodexError implements Exception {
  const CodexError(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => message;
}

/// Requests to `codex app-server` over [transport], and their responses.
class CodexRpc {
  CodexRpc(this.transport);

  final CodexTransport transport;

  int _requests = 0;
  final Map<Object, ({String method, Completer<Map<String, Object?>> done})>
  _pending = {};

  /// Writes the request [method] and completes with its result; fails with
  /// a [CodexError].
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = ++_requests;
    final done = Completer<Map<String, Object?>>();
    _pending[id] = (method: method, done: done);
    transport.write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return done.future;
  }

  /// Writes the notification [method].
  void notify(String method, [Map<String, Object?>? params]) =>
      transport.write({'jsonrpc': '2.0', 'method': method, 'params': ?params});

  /// Answers the server's request [id] with [result].
  void respond(Object? id, Map<String, Object?> result) =>
      transport.write({'jsonrpc': '2.0', 'id': id, 'result': result});

  /// Turns down the server's request [id].
  void refuse(Object? id, String message) => transport.write({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32601, 'message': message},
  });

  /// Takes [message] if it is a response to a request of ours: true then.
  bool receive(Map<String, Object?> message) {
    if (message.containsKey('method')) return false;
    final pending = _pending.remove(message['id']);
    if (pending == null) return message.containsKey('id');
    if (message['error'] case final Map<Object?, Object?> error) {
      pending.done.completeError(
        CodexError(pending.method, '${error['message'] ?? error}'),
      );
    } else {
      pending.done.complete(
        (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
      );
    }
    return true;
  }

  /// Fails the requests not answered: the server is gone.
  void fail(String message) {
    for (final pending in _pending.values) {
      pending.done.completeError(CodexError(pending.method, message));
    }
    _pending.clear();
  }
}
