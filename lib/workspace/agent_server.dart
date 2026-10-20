import 'agent_host.dart';
import 'agent_server_stub.dart'
    if (dart.library.io) 'agent_server_io.dart'
    as platform;

/// Has [host] answer the agents' command: its server listening on this
/// machine, the command written into [directory], and (unless not to
/// [installSkill]) the skill telling agents of it installed. Nothing on
/// the web, nor on Windows (the command is a shell script).
Future<void> serveAgents(
  AgentHost host, {
  required String directory,
  bool installSkill = true,
}) => platform.serveAgents(
  host,
  directory: directory,
  installSkill: installSkill,
);
