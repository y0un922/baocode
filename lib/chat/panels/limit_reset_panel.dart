import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;

/// The agent stopped at the account's usage limit, first above the
/// composer: when the limit resets, and whether the agent goes on by itself
/// then ([scheduled]), with a way to say so or not.
///
/// Gone once the reset is past.
class LimitResetPanel extends StatefulWidget {
  const LimitResetPanel({
    super.key,
    required this.resetsAt,
    required this.scheduled,
    required this.onSchedule,
    required this.onUnschedule,
    required this.onDecline,
  });

  final DateTime resetsAt;

  /// Whether the agent goes on once it resets.
  final bool scheduled;

  /// Continue After Reset.
  final VoidCallback onSchedule;

  /// Undo, once scheduled.
  final VoidCallback onUnschedule;

  /// Cancel: not to go on.
  final VoidCallback onDecline;

  @override
  State<LimitResetPanel> createState() => _LimitResetPanelState();
}

class _LimitResetPanelState extends State<LimitResetPanel> {
  Timer? _over;

  bool get _past => !widget.resetsAt.isAfter(DateTime.now());

  @override
  void initState() {
    super.initState();
    _time();
  }

  @override
  void didUpdateWidget(LimitResetPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetsAt != oldWidget.resetsAt) _time();
  }

  /// Hides it as the limit resets.
  void _time() {
    _over?.cancel();
    final left = widget.resetsAt.difference(DateTime.now());
    if (left.isNegative) return;
    _over = Timer(left, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _over?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_past) return const SizedBox.shrink();
    final l10n = context.l10n;
    final time = resetTime(widget.resetsAt, l10n);
    final warning = themeColors['editorWarning.foreground'];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderStrong),
      ),
      child: Row(
        children: [
          Icon(
            widget.scheduled
                ? Icons.schedule_send_rounded
                : Icons.hourglass_bottom_rounded,
            size: 14,
            color: widget.scheduled ? AppColors.textMuted : warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.scheduled
                      ? l10n.usageLimitScheduled(time)
                      : l10n.usageLimitHit(time),
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!widget.scheduled) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.usageLimitAsk,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (widget.scheduled)
            IdeButton(
              label: l10n.usageLimitUndo,
              secondary: true,
              onPressed: widget.onUnschedule,
            )
          else ...[
            IdeButton(
              label: l10n.commonCancel,
              secondary: true,
              onPressed: widget.onDecline,
            ),
            const SizedBox(width: 6),
            IdeButton(
              label: l10n.usageLimitContinueAfterReset,
              onPressed: widget.onSchedule,
            ),
          ],
        ],
      ),
    );
  }
}

/// When the limit resets, on the clock: `15:00` today, `tomorrow 15:00`,
/// else with its date (`10/23 15:00`).
String resetTime(DateTime at, AppLocalizations l10n, {DateTime? now}) {
  now ??= DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(at.hour)}:${two(at.minute)}';
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = day.difference(today).inHours / 24;
  if (days.round() == 0) return clock;
  if (days.round() == 1) return l10n.usageLimitTomorrow(clock);
  return '${at.month}/${at.day} $clock';
}
