import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'pi/pi_catalog.dart';
import 'pi/pi_kernel.dart';
import '../remote/remote_claude.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex',
    icon: Icons.data_object_rounded,
    description: 'OpenAI’s coding agent',
    create: (context) => CodexKernel(codex, context),
    catalog: const CodexCatalog(),
  );

  static final KernelDescriptor pi = KernelDescriptor(
    id: 'pi',
    label: 'pi',
    icon: Icons.pie_chart_outline_rounded,
    description: 'A minimal coding agent, on any model',
    create: (context) => PiKernel(pi, context),
    catalog: const PiCatalog(),
  );

  static List<KernelDescriptor> _all = [claudeCode, codex, pi];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
