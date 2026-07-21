import 'package:forge/l10n/generated/app_localizations.dart';

/// Maps stable note failure codes to localized, presentation-safe strings so a
/// technical code never leaks to the UI (ux-design §12).
abstract final class NoteLabels {
  static String failure(AppLocalizations l10n, String code) => switch (code) {
    'note.not_found' => l10n.errorNoteNotFound,
    'notes.unavailable' => l10n.notesUnavailable,
    _ when code.startsWith('note.') => l10n.errorNoteInvalid,
    _ => l10n.errorUnexpected,
  };
}
