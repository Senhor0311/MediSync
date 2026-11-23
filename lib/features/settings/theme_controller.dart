import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ThemePreferenceStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Stores only a non-sensitive appearance preference, never account data.
class LocalThemePreferenceStore implements ThemePreferenceStore {
  LocalThemePreferenceStore() : _preferences = SharedPreferencesAsync();

  static const key = 'medisync.themeMode';
  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read() => _preferences.getString(key);

  @override
  Future<void> write(String value) => _preferences.setString(key, value);
}

class ThemeController extends ChangeNotifier {
  ThemeController(this._store);

  final ThemePreferenceStore _store;
  ThemeMode _mode = ThemeMode.system;
  bool _saving = false;
  String? _error;

  ThemeMode get mode => _mode;
  bool get saving => _saving;
  String? get error => _error;

  Future<void> load() async {
    try {
      final value = await _store.read();
      _mode = switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      _error = null;
    } catch (_) {
      _mode = ThemeMode.system;
      _error =
          'Your saved appearance could not be loaded. '
          'Try saving your preference again.';
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    // Serialize writes so an older selection cannot overwrite a newer one.
    if (_saving) return;
    _mode = value;
    _saving = true;
    _error = null;
    notifyListeners();
    try {
      await _store.write(value.name);
    } catch (_) {
      _error =
          'This appearance is applied for now, but could not be saved. '
          'Try again to save your preference.';
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
