import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:bao_remote/local.dart' show AppPaths, ClaudeEnvironment;
import 'package:path/path.dart' as p;

import '../agent_kernel.dart';

/// pi's own record of its sessions on this machine: one JSONL file each,
/// under `~/.pi/agent/sessions/<folder>/`, its first line the session's
/// header (id, folder, start).
class PiCatalog implements SessionCatalog {
  const PiCatalog({this.sessionsDir});

  /// Where pi keeps its sessions; by default `PI_CODING_AGENT_SESSION_DIR`
  /// as the login shell has it, else `<home>/.pi/agent/sessions`.
  final String? sessionsDir;

  /// The file of each session listed, to delete it by its id.
  static final Map<String, String> _files = {};

  Future<String> _dir() async {
    if (sessionsDir case final dir?) return dir;
    final environment = await ClaudeEnvironment.of();
    if (environment['PI_CODING_AGENT_SESSION_DIR'] case final dir?
        when dir.isNotEmpty) {
      return dir;
    }
    return p.join(AppPaths.home(environment), '.pi', 'agent', 'sessions');
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final dir = await _dir();
    final sessions = await Isolate.run(() => _scan(dir));
    final byFolder = <String, List<SessionRecord>>{};
    for (final session in sessions) {
      _files[session.id] = session.path!;
      (byFolder[session.cwd] ??= []).add(session);
    }
    return [
      for (final MapEntry(key: path, value: sessions) in byFolder.entries)
        ProjectRecord(
          path: path,
          sessions: sessions
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        ),
    ];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final all = await projects();
    return all.where((p) => p.path == cwd).firstOrNull?.sessions ?? const [];
  }

  @override
  Future<void> delete(String id) async {
    if (!_files.containsKey(id)) await projects();
    final path = _files.remove(id);
    if (path == null) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  static List<SessionRecord> _scan(String dir) {
    final root = Directory(dir);
    if (!root.existsSync()) return const [];
    return [
      for (final entity in root.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.jsonl'))
          ?readRecord(entity),
    ];
  }

  /// How much of a file's start and end is read for its record: a session
  /// may be many megabytes.
  static const _head = 256 * 1024;
  static const _tail = 64 * 1024;

  /// The session [file] holds, as the catalog lists it: its title is the
  /// name it was last given, else its first message. Null for a file that
  /// is not a session.
  static SessionRecord? readRecord(File file) {
    try {
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        final head = utf8.decode(
          raf.readSync(math.min(length, _head)),
          allowMalformed: true,
        );
        final lines = head.split('\n');
        final header = _json(lines.first);
        if (header == null || header['type'] != 'session') return null;
        final id = header['id'];
        final cwd = header['cwd'];
        if (id is! String || cwd is! String) return null;
        String? name;
        String? firstMessage;
        void scan(Iterable<String> lines) {
          for (final line in lines) {
            if (line.contains('"session_info"')) {
              if (_json(line) case {'type': 'session_info'} && final entry) {
                name = entry['name'] as String?;
              }
            } else if (firstMessage == null && line.contains('"user"')) {
              if (_json(line) case {
                'type': 'message',
                'message': {'role': 'user', 'content': final content},
              }) {
                firstMessage = _text(content);
              }
            }
          }
        }

        scan(lines.skip(1));
        if (length > _head) {
          raf.setPositionSync(math.max(_head, length - _tail));
          // Its first line likely cut: left out.
          scan(
            utf8
                .decode(raf.readSync(_tail), allowMalformed: true)
                .split('\n')
                .skip(1),
          );
        }
        return SessionRecord(
          id: id,
          title: _oneLine(name ?? firstMessage ?? ''),
          updatedAt: file.lastModifiedSync(),
          cwd: cwd,
          path: file.path,
        );
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return null;
    }
  }

  static Map<String, Object?>? _json(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// A message's text: a string, or its text blocks.
  static String _text(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> blocks => [
      for (final block in blocks)
        if (block case {'type': 'text', 'text': final String text}) text,
    ].join(' '),
    _ => '',
  };

  static String _oneLine(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 100 ? line : '${line.substring(0, 99)}…';
  }
}
