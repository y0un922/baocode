// Reports what the real Codex did, for a person to read.
// ignore_for_file: avoid_print
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';

import 'kernel/pi_kernel_test.dart' show shown;

void main() {
  test('real Codex, end to end', () async {
    final dir = await Directory.systemTemp.createTemp('baocode-e2e-codex-');
    final cwd = dir.resolveSymbolicLinksSync();
    File('$cwd/a.txt').writeAsStringSync('line one\nline two\n');
    final kernel = CodexKernel(KernelRegistry.codex, KernelContext(cwd: cwd));
    final transcript = Transcript();
    final edits = <FileEdited>[];
    kernel.events.listen((event) {
      transcript.apply(event);
      if (event is FileEdited) edits.add(event);
    });
    Future<void> settle(Transcript transcript) async {
      for (
        var i = 0;
        i < 240 &&
            (transcript.activeTurn != null || transcript.lastTurnEndSeq == 0);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    kernel.send(
      const KernelTurn(
        id: 't1',
        text:
            'Run `ls` in the shell, then use apply_patch to change "line two" '
            'to "line 2" in a.txt, then reply with exactly: done',
      ),
    );
    await settle(transcript);
    print('HEALTH ${kernel.health.status} ${kernel.health.message ?? ''}');
    print('ITEMS\n  ${shown(transcript).join('\n  ')}');
    print('MODEL ${kernel.model.selected} of ${kernel.model.options.length}');
    print(
      'EFFORT ${kernel.effort.selected}  COMMANDS ${kernel.commands.length}',
    );
    print('USAGE ${transcript.usage?.used}/${transcript.usage?.window}');
    print('LIMITS ${kernel.accountLimits.map((l) => l.label)}');
    print('EDITS ${edits.map((e) => '${e.change.path} ${e.original}')}');
    expect(File('$cwd/a.txt').readAsStringSync(), 'line one\nline 2\n');
    expect(edits.single.change.path, '$cwd/a.txt');
    final threadId = kernel.sessionId!;
    // Gone however the test ends: not left in the user's Codex.
    addTearDown(() async {
      await const CodexCatalog().delete(threadId);
      await dir.delete(recursive: true);
    });
    kernel.dispose();
    await kernel.stopped;

    final sessions = await const CodexCatalog().sessionsIn(cwd);
    print('CATALOG ${sessions.map((s) => '${s.id} "${s.title}"')}');
    final session = sessions.singleWhere((s) => s.id == threadId);

    final resumed = CodexKernel(
      KernelRegistry.codex,
      KernelContext(resume: session),
    );
    final replay = Transcript();
    resumed.events.listen(replay.apply);
    resumed.prepare();
    for (var i = 0; i < 60 && replay.length == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    print('REPLAY\n  ${shown(replay).join('\n  ')}');
    expect(shown(replay), shown(transcript));
    resumed.dispose();
  });
}
