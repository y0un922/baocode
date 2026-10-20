import 'pi_transport.dart';

Future<PiTransport> startPiProcess(
  String cwd, {
  String? session,
  Map<String, String> environment = const {},
}) async =>
    throw const PiUnavailable(
      'pi runs in the desktop app',
      detail: 'The browser cannot start local processes.',
    );

Future<bool> branchPiSession(String file, int fromEnd) async =>
    throw UnsupportedError('pi runs in the desktop app');

Future<({String id, String path})> copyPiSession(
  String file, {
  int? fromEnd,
  required String title,
}) async => throw UnsupportedError('pi runs in the desktop app');

Future<List<Map<String, Object?>>?> readPiHistory(String file) async => null;
