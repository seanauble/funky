import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'colors.dart';

enum ThemePreference { light, dark, auto }

const _prefsKey = 'funky.themePreference';

/// Light/Dark/Auto picker from rule 11. Persisted the same way the rest of
/// the mock store is, so the choice survives a restart.
class ThemeProvider extends ChangeNotifier {
  ThemePreference _preference = ThemePreference.auto;
  Brightness _systemBrightness = Brightness.dark;

  ThemePreference get preference => _preference;

  bool get isDark {
    if (_preference == ThemePreference.auto) {
      return _systemBrightness != Brightness.light;
    }
    return _preference == ThemePreference.dark;
  }

  ThemeTokens get tokens => isDark ? darkTokens : lightTokens;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null) {
      _preference = ThemePreference.values.firstWhere(
        (p) => p.name == stored,
        orElse: () => ThemePreference.auto,
      );
      notifyListeners();
    }
  }

  void updateSystemBrightness(Brightness brightness) {
    if (_systemBrightness != brightness) {
      _systemBrightness = brightness;
      if (_preference == ThemePreference.auto) notifyListeners();
    }
  }

  Future<void> setPreference(ThemePreference pref) async {
    _preference = pref;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, pref.name);
  }
}
