import 'package:flutter/material.dart';

import '../features/settings/theme_controller.dart';
import '../features/auth/auth_controller.dart';
import '../features/clinics/clinic_repository.dart';
import '../features/records/record_repository.dart';
import '../features/appointments/appointment_repository.dart';
import '../features/home/dashboard_repository.dart';
import 'app_shell.dart';
import 'routing/app_router.dart';
import 'theme/app_theme.dart';

class MediSyncApp extends StatefulWidget {
  const MediSyncApp({
    super.key,
    required this.themeController,
    this.authController,
    this.clinicRepository,
    this.recordRepository,
    this.appointmentRepository,
    this.dashboardRepository,
    this.emulatorMode = false,
  });

  final ThemeController themeController;
  final AuthController? authController;
  final ClinicRepository? clinicRepository;
  final RecordRepository? recordRepository;
  final AppointmentRepository? appointmentRepository;
  final DashboardRepository? dashboardRepository;
  final bool emulatorMode;

  @override
  State<MediSyncApp> createState() => _MediSyncAppState();
}

class _MediSyncAppState extends State<MediSyncApp> {
  AppRouter? _router;
  final AppPathParser _parser = AppPathParser();

  @override
  void initState() {
    super.initState();
    if (widget.authController != null) {
      _router = AppRouter(
        widget.authController!,
        widget.themeController,
        clinicRepository: widget.clinicRepository,
        recordRepository: widget.recordRepository,
        appointmentRepository: widget.appointmentRepository,
        dashboardRepository: widget.dashboardRepository,
      );
    }
  }

  @override
  void didUpdateWidget(MediSyncApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authController != widget.authController ||
        oldWidget.themeController != widget.themeController ||
        oldWidget.clinicRepository != widget.clinicRepository ||
        oldWidget.recordRepository != widget.recordRepository ||
        oldWidget.appointmentRepository != widget.appointmentRepository ||
        oldWidget.dashboardRepository != widget.dashboardRepository) {
      _router?.dispose();
      _router = widget.authController == null
          ? null
          : AppRouter(
              widget.authController!,
              widget.themeController,
              clinicRepository: widget.clinicRepository,
              recordRepository: widget.recordRepository,
              appointmentRepository: widget.appointmentRepository,
              dashboardRepository: widget.dashboardRepository,
            );
    }
  }

  @override
  void dispose() {
    _router?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, child) => _router == null
          ? MaterialApp(
              title: 'MediSync',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: widget.themeController.mode,
              home: AppShell(themeController: widget.themeController),
            )
          : MaterialApp.router(
              builder: (context, child) => widget.emulatorMode
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: child!),
                        Material(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Text(
                                'Local demo emulators · synthetic data only',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : child!,
              title: 'MediSync',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: widget.themeController.mode,
              routeInformationParser: _parser,
              routerDelegate: _router!,
            ),
    );
  }
}
