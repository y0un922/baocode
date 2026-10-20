import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../jsonl_process_io.dart';
import 'pi_transport.dart';

/// pi as a child process, over its stdin and stdout.
class PiProcess extends JsonLinesProcess implements PiTransport {
  PiProcess(super.process) : super(exitMessage: PiExit.message);
}

Future<PiTransport> startPiProcess(
  String cwd, {
  String? session,
  Map<String, String> environment = const {},
}) async {
  if (!Directory(cwd).existsSync()) {
    throw PiUnavailable('The project folder is gone', detail: cwd);
  }
  // The login shell's: where pi, and the Node it runs on, are installed.
  final variables = {
    ...await ClaudeEnvironment.of(),
    ...await NetworkProxy.instance.environment(),
    ...environment,
  };
  final executable = locateExecutable(variables, 'pi');
  if (executable == null) {
    throw const PiUnavailable(
      'pi is not installed',
      detail:
          'Install it, then try again:\n'
          'npm install -g @earendil-works/pi-coding-agent',
    );
  }
  try {
    final process = await Process.start(
      executable,
      [
        '--mode',
        'rpc',
        if (session != null) ...['--session', session],
      ],
      workingDirectory: cwd,
      environment: variables,
      includeParentEnvironment: Platform.isWindows,
      // An npm shim is a `.cmd`, which only the shell can run.
      runInShell: Platform.isWindows,
    );
    return PiProcess(process);
  } on ProcessException catch (error) {
    throw PiUnavailable(
      'pi could not start',
      detail: '$executable\n${error.message}',
    );
  }
}

/// The entries of the session in [lines] (its header left out).
List<Map<String, Object?>> _entries(Iterable<String> lines) => [
  for (final line in lines)
    if (line.trim().isNotEmpty)
      if (jsonDecode(line) case final Map<String, Object?> entry) entry,
];

/// The user message [fromEnd] from the end of the branch [entries] are on
/// (0: the last), as pi takes up its last entry as where it is.
Map<String, Object?>? _userMessage(
  List<Map<String, Object?>> entries,
  int fromEnd,
) {
  final byId = {for (final entry in entries) entry['id']: entry};
  final users = <Map<String, Object?>>[];
  for (var entry = entries.lastOrNull; entry != null;) {
    if (entry case {'type': 'message', 'message': {'role': 'user'}}) {
      users.add(entry);
    }
    entry = byId[entry['parentId']];
  }
  return fromEnd < users.length ? users[fromEnd] : null;
}

Future<List<Map<String, Object?>>?> readPiHistory(String file) async {
  try {
    return await Isolate.run(() {
      final entries = _entries(File(file).readAsLinesSync().skip(1));
      final byId = {for (final entry in entries) entry['id']: entry};
      final branch = <Map<String, Object?>>[];
      for (var entry = entries.lastOrNull; entry != null;) {
        switch (entry) {
          case {'type': 'message', 'message': final Map<Object?, Object?> m}:
            branch.add(m.cast());
          case {'type': 'compaction'}:
            branch.add(const {'role': 'compactionSummary'});
        }
        entry = byId[entry['parentId']];
      }
      return branch.reversed.toList();
    });
  } on Object {
    return null;
  }
}

/// pi's way with an entry's id: 8 hex digits, none of [entries]'.
String _entryId(List<Map<String, Object?>> entries) {
  final taken = {for (final entry in entries) entry['id']};
  final random = math.Random.secure();
  while (true) {
    final id = [
      for (var i = 0; i < 8; i++) random.nextInt(16).toRadixString(16),
    ].join();
    if (!taken.contains(id)) return id;
  }
}

/// Now, as pi writes a time: to the millisecond, in UTC.
String _timestamp() =>
    '${DateTime.now().toUtc().toIso8601String().substring(0, 23)}Z';

/// An entry of no meaning to the model under [parentId]: where pi goes on
/// from, the last.
Map<String, Object?> _branch(
  List<Map<String, Object?>> entries,
  Map<String, Object?> before,
) => {
  'type': 'custom',
  'id': _entryId(entries),
  'parentId': before['parentId'],
  'timestamp': _timestamp(),
  'customType': 'baocode.rewind',
  'data': {'before': before['id']},
};

Future<bool> branchPiSession(String file, int fromEnd) async {
  final text = await File(file).readAsString();
  final entries = _entries(const LineSplitter().convert(text).skip(1));
  final before = _userMessage(entries, fromEnd);
  if (before == null) return false;
  // On a line of its own, though the last may not have ended its own.
  final start = text.isEmpty || text.endsWith('\n') ? '' : '\n';
  await File(file).writeAsString(
    '$start${jsonEncode(_branch(entries, before))}\n',
    mode: FileMode.append,
  );
  return true;
}

Future<({String id, String path})> copyPiSession(
  String file, {
  int? fromEnd,
  required String title,
}) async {
  final lines = await File(file).readAsLines();
  final header = (jsonDecode(lines.first) as Map).cast<String, Object?>();
  final entries = _entries(lines.skip(1));
  final added = <Map<String, Object?>>[];
  if (fromEnd != null) {
    final before = _userMessage(entries, fromEnd);
    if (before != null) added.add(_branch(entries, before));
  }
  added.add({
    'type': 'session_info',
    'id': _entryId([...entries, ...added]),
    'parentId': (added.lastOrNull ?? entries.lastOrNull)?['id'],
    'timestamp': _timestamp(),
    'name': title,
  });
  final id = _uuid();
  final timestamp = _timestamp();
  final path = p.join(
    p.dirname(file),
    '${timestamp.replaceAll(RegExp('[:.]'), '-')}_$id.jsonl',
  );
  await File(path).writeAsString(
    [
      jsonEncode({
        ...header,
        'id': id,
        'timestamp': timestamp,
        'parentSession': file,
      }),
      for (final line in lines.skip(1))
        if (line.trim().isNotEmpty) line,
      for (final entry in added) jsonEncode(entry),
      '',
    ].join('\n'),
  );
  return (id: id, path: path);
}

/// A random UUID (v4), as pi names its sessions.
String _uuid() {
  final random = math.Random.secure();
  String hex(int length) =>
      [for (var i = 0; i < length; i++) random.nextInt(16).toRadixString(16)]
          .join();
  final variant = (8 + random.nextInt(4)).toRadixString(16);
  return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
}
