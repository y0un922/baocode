import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/panels/limit_reset_panel.dart' show resetTime;
import '../../chat/resume_after_reset.dart';
import '../../ide/ide_back_button.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';

/// Settings → Models → Claude Code (this machine's setup): what is Claude's
/// own plan's alone. Its usage limit: whether an agent stopped at it goes on
/// by itself once it resets, unasked (`chat.resumeAfterLimitReset`), and
/// the agents stopped now, each to go on then or not (one turned down above
/// its composer turned on here), each opened with a click.
class BuiltinProviderSettingsPage extends StatelessWidget {
  const BuiltinProviderSettingsPage({
    super.key,
    required this.onBack,
    this.settings,
    this.resumes,
    this.onOpenSession,
  });

  final VoidCallback onBack;

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  /// The agents stopped at the usage limit; the app's by default.
  final ResumeAfterReset? resumes;

  /// Shows the agent of a session listed; none where it cannot.
  final ValueChanged<String>? onOpenSession;

  void _write(Object? value) {
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings.update(ResumeAfterResetSetting.settingKey, value).catchError((
        Object error,
      ) {
        // A settings file that does not parse is left as it is; its error
        // is shown.
        debugPrint('${ResumeAfterResetSetting.settingKey} not kept: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final resumes = this.resumes ?? ResumeAfterReset.current;
    return ListenableBuilder(
      listenable: Listenable.merge([?settings, resumes]),
      builder: (context, _) {
        final entries = resumes.entries;
        return SettingsColumn(
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              // Its arrow level with the title under it.
              child: Transform.translate(
                offset: const Offset(-10, 0),
                child: IdeBackButton(label: l10n.modelsTitle, onTap: onBack),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.modelsBuiltinName, style: SettingsText.title),
            const SizedBox(height: 4),
            Text(
              l10n.modelsBuiltinDescription,
              style: SettingsText.description,
            ),
            const SizedBox(height: 16),
            SettingsGroup(
              title: l10n.resumeSettingsTitle,
              description: l10n.resumeSettingsDescription,
              children: [
                SettingsCard(
                  children: [
                    SettingsSwitchRow(
                      label: l10n.resumeSettingsAuto,
                      description: l10n.resumeSettingsAutoDescription,
                      value: ResumeAfterResetSetting.enabled(
                        settings?[ResumeAfterResetSetting.settingKey],
                      ),
                      onChanged: (on) =>
                          _write(on ? ResumeAfterResetSetting.on : null),
                    ),
                    if (entries.isEmpty)
                      SettingsRow(label: l10n.resumeSettingsEmpty)
                    else
                      for (final entry in entries)
                        _EntryRow(
                          key: ValueKey(entry.sessionId),
                          entry: entry,
                          onScheduled: (on) =>
                              resumes.setScheduled(entry.sessionId, on),
                          onOpen: switch (onOpenSession) {
                            final open? => () => open(entry.sessionId),
                            null => null,
                          },
                        ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// An agent stopped at the limit: a click shows it, its switch sets it to
/// go on once the limit resets.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.onScheduled,
    this.onOpen,
  });

  final ResumeEntry entry;
  final ValueChanged<bool> onScheduled;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final onOpen = this.onOpen;
    final row = SettingsRow(
      label: entry.title,
      description: l10n.resumeSettingsEntry(
        entry.project,
        resetTime(entry.resetsAt, l10n),
      ),
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsSwitch(
            value: entry.scheduled,
            semanticLabel: entry.title,
            onChanged: onScheduled,
          ),
          if (onOpen != null) ...[
            const SizedBox(width: 8),
            Icon(
              Codicons.chevronRight,
              size: 14,
              color: SettingsColors.textSecondary,
            ),
          ],
        ],
      ),
    );
    if (onOpen == null) return row;
    return Semantics(
      button: true,
      label: l10n.resumeSettingsOpen(entry.title),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: row),
    );
  }
}
