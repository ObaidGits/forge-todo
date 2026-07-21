import 'package:flutter/material.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

extension ForgeLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  MaterialLocalizations get materialL10n => MaterialLocalizations.of(this);
}
