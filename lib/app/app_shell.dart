import 'package:flutter/material.dart';

import '../features/home/home_screen.dart';
import '../features/auth/auth_controller.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/theme_controller.dart';
import '../shared/layout/adaptive_scaffold.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeController,
    this.authController,
  });

  final ThemeController themeController;
  final AuthController? authController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  void _select(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _select,
      body: _selectedIndex == 0
          ? HomeScreen(authController: widget.authController)
          : SettingsScreen(
              controller: widget.themeController,
              authController: widget.authController,
            ),
    );
  }
}
