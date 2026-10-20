// Reports what the real pi did, for a person to read.
// ignore_for_file: avoid_print
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/pi/pi_catalog.dart';
import 'package:baocode/kernel/pi/pi_kernel.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';

import 'kernel/pi_kernel_test.dart' show shown;

void main() {
  test('real pi, end to end', () async {
    final dir = await Directory.systemTemp.createTemp('baocode-e2e-pi-');
    final cwd = dir.resolveSymbolicLinksSync();
    File('$cwd/a.txt').writeAsStringSync('line one\nline two\n');
    final kernel = PiKernel(KernelRegistry.pi, KernelContext(cwd: cwd));
    final transcript = Transcript();
    final edits = <FileEdited>[];
    kernel.events.listen((event) {
      transcript.apply(event);
      if (event is FileEdited) edits.add(event);
    });
    kernel.send(
      const KernelTurn(
        id: 't1',
        text:
            'Run `ls` with bash, then use the edit tool to change "line two" '
            'to "line 2" in a.txt, then reply with exactly: done',
      ),
    );
    for (
      var i = 0;
      i < 240 &&
          (transcript.activeTurn != null || transcript.lastTurnEndSeq == 0);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    print('HEALTH ${kernel.health.status} ${kernel.health.message ?? ''}');
    print('ITEMS\n  ${shown(transcript).join('\n  ')}');
    print('MODEL ${kernel.model.selected} of ${kernel.model.options.length}');
    print(
      'EFFORT ${kernel.effort.selected}  COMMANDS ${kernel.commands.length}',
    );
    print('USAGE ${transcript.usage?.used}/${transcript.usage?.window}');
    print('EDITS ${edits.map((e) => '${e.change.path} ${e.original}')}');
    expect(File('$cwd/a.txt').readAsStringSync(), 'line one\nline 2\n');
    expect(edits.single.change.path, '$cwd/a.txt');
    kernel.dispose();
    await kernel.stopped;

    final project = (await const PiCatalog().projects()).firstWhere(
      (p) => p.path == cwd,
    );
    final session = project.sessions.single;
    addTearDown(() async {
      await dir.delete(recursive: true);
      await File(session.path!).parent.delete(recursive: true);
    });
    print('CATALOG ${session.id} "${session.title}"');

    final resumed = PiKernel(KernelRegistry.pi, KernelContext(resume: session));
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
