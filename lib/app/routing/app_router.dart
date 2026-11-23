import 'package:flutter/material.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/auth/inactivity_session.dart';
import '../../features/home/dashboard_repository.dart';
import '../../features/auth/auth_gate.dart';
import '../../features/auth/auth_models.dart';
import '../../features/clinics/clinic_repository.dart';
import '../../features/records/record_repository.dart';
import '../../features/appointments/appointment_repository.dart';
import '../../features/queue/queue_repository.dart';
import '../../features/notifications/notification_repository.dart';
import '../../features/privacy/privacy_repository.dart';
import '../../features/settings/theme_controller.dart';
import 'role_shell.dart';
import 'route_policy.dart';
import '../../features/encryption/clinical_crypto.dart';
import '../../features/encryption/vault_gate.dart';

class AppPathParser extends RouteInformationParser<String> {
  @override
  Future<String> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final path = routeInformation.uri.path;
    return path.isEmpty ? '/' : path;
  }

  @override
  RouteInformation? restoreRouteInformation(String configuration) =>
      RouteInformation(uri: Uri.parse(configuration));
}

class AppRouter extends RouterDelegate<String>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<String> {
  AppRouter(
    this.controller,
    this.themeController, {
    this.clinicRepository,
    this.recordRepository,
    this.appointmentRepository,
    this.queueRepository,
    this.notificationRepository,
    this.privacyRepository,
    this.dashboardRepository,
  }) {
    controller.addListener(_onAccessChanged);
  }

  final AuthController controller;
  final ThemeController themeController;
  final ClinicRepository? clinicRepository;
  final RecordRepository? recordRepository;
  final AppointmentRepository? appointmentRepository;
  final QueueRepository? queueRepository;
  final NotificationRepository? notificationRepository;
  final PrivacyRepository? privacyRepository;
  final DashboardRepository? dashboardRepository;
  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  String _path = '/';
  AccessKind? _lastKind;

  String get path => _path;

  void navigate(String path) {
    _path = path;
    notifyListeners();
  }

  void _onAccessChanged() {
    if (!controller.busy && controller.access.kind != _lastKind) {
      if (controller.access.kind == AccessKind.signedOut &&
          !_path.startsWith('/invitation/')) {
        _path = '/sign-in';
      } else if (controller.access.kind == AccessKind.pending &&
          !_path.startsWith('/invitation/')) {
        _path = '/pending';
      } else if (controller.access.kind == AccessKind.ready &&
          const [
            '/sign-in',
            '/pending',
            '/verify-email',
            '/complete-profile',
            '/access-unavailable',
          ].contains(_path)) {
        _path = RoutePolicy.contexts(controller.access).first.base;
      }
      _lastKind = controller.access.kind;
    }
    notifyListeners();
  }

  @override
  String get currentConfiguration => _path;

  @override
  Future<void> setNewRoutePath(String configuration) async {
    navigate(configuration);
  }

  @override
  Future<bool> popRoute() async {
    final view = RoutePolicy.resolve(_path, controller.access);
    final base = view.context?.base;
    if (base != null && _path != base) {
      navigate(base);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final view = RoutePolicy.resolve(_path, controller.access);
    final navigator = Navigator(
      key: navigatorKey,
      pages: [
        MaterialPage<void>(
          key: ValueKey(
            controller.busy
                ? 'checking'
                : view.kind == AccessKind.ready
                ? 'ready'
                : view.kind.name,
          ),
          child: controller.busy
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : view.kind == AccessKind.ready
              ? _withVault(
                  RoleShell(
                    dashboardRepository: dashboardRepository,
                    view: view,
                    controller: controller,
                    themeController: themeController,
                    navigate: navigate,
                    clinicRepository: clinicRepository,
                    recordRepository: recordRepository,
                    appointmentRepository: appointmentRepository,
                    queueRepository: queueRepository,
                    notificationRepository: notificationRepository,
                    privacyRepository: privacyRepository,
                  ),
                )
              : AuthGate(
                  controller: controller,
                  themeController: themeController,
                  invitationId: view.invitationId,
                  onInvitationAccepted: () => navigate(
                    RoutePolicy.contexts(controller.access).first.base,
                  ),
                ),
        ),
      ],
      onDidRemovePage: (page) {},
    );
    // Includes Navigator's overlay routes (editors, confirmations and exports).
    return view.kind == AccessKind.ready
        ? InactivitySession(
            key: ValueKey(controller.gateway.currentUser?.uid),
            onExpired: () async {
              ClinicalCrypto.instance?.lock();
              await controller.signOut();
            },
            child: navigator,
          )
        : navigator;
  }

  Widget _withVault(Widget child) {
    final crypto = ClinicalCrypto.instance;
    return crypto == null
        ? child
        : VaultGate(
            crypto: crypto,
            signOut: () async {
              crypto.lock();
              await controller.signOut();
            },
            child: child,
          );
  }

  @override
  void dispose() {
    controller.removeListener(_onAccessChanged);
    super.dispose();
  }
}
