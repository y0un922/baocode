import '../agent_kernel.dart';

/// No local sessions on the web.
class PiCatalog implements SessionCatalog {
  const PiCatalog({this.sessionsDir});

  final String? sessionsDir;

  @override
  Future<List<ProjectRecord>> projects() async => const [];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}
