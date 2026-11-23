import 'package:flutter/material.dart';

import 'app_breakpoints.dart';

/// Navigation adapts to available window space, not the device's platform.
class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.body,
    this.destinations = const [
      AppDestination('Home', Icons.home_outlined, Icons.home_rounded),
      AppDestination('Settings', Icons.tune_outlined, Icons.tune_rounded),
    ],
    this.title = 'MediSync',
    this.actions,
    this.mobileDestinationIndices,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget body;
  final List<AppDestination> destinations;
  final String title;
  final List<Widget>? actions;

  /// Indices into [destinations] shown in the compact bottom bar.
  final List<int>? mobileDestinationIndices;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = AppBreakpoints.sizeOf(constraints.maxWidth);
        final phone = size == AppWindowSize.phone;
        final extended =
            size == AppWindowSize.desktop &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        final mobileIndices =
            mobileDestinationIndices ??
            List<int>.generate(destinations.length, (index) => index);
        final mobileSelected = mobileIndices.indexOf(selectedIndex);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.medical_services_outlined),
                const SizedBox(width: 12),
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
              ],
            ),
            actions: actions,
          ),
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!phone) ...[
                  NavigationRail(
                    scrollable: true,
                    extended: extended,
                    minExtendedWidth: 232,
                    selectedIndex: selectedIndex,
                    onDestinationSelected: onDestinationSelected,
                    labelType: extended
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    destinations: [
                      for (final item in destinations)
                        NavigationRailDestination(
                          icon: Icon(item.icon),
                          selectedIcon: Icon(item.selectedIcon),
                          label: Text(item.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: body),
              ],
            ),
          ),
          bottomNavigationBar: !phone
              ? null
              : mobileSelected < 0
              ? _UnselectedMobileBar(
                  destinations: [
                    for (final index in mobileIndices) destinations[index],
                  ],
                  onDestinationSelected: (index) =>
                      onDestinationSelected(mobileIndices[index]),
                )
              : NavigationBar(
                  selectedIndex: mobileSelected,
                  onDestinationSelected: (index) =>
                      onDestinationSelected(mobileIndices[index]),
                  destinations: [
                    for (final index in mobileIndices)
                      NavigationDestination(
                        icon: Icon(destinations[index].icon),
                        selectedIcon: Icon(destinations[index].selectedIcon),
                        label: destinations[index].label,
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// NavigationBar requires a selected index. Omitted routes use this neutral bar.
class _UnselectedMobileBar extends StatelessWidget {
  const _UnselectedMobileBar({
    required this.destinations,
    required this.onDestinationSelected,
  });

  final List<AppDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Material(
      key: const Key('unselected-mobile-navigation'),
      color:
          theme.navigationBarTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              for (var index = 0; index < destinations.length; index++)
                Expanded(
                  child: Semantics(
                    button: true,
                    label: destinations[index].label,
                    child: InkWell(
                      onTap: () => onDestinationSelected(index),
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(destinations[index].icon, color: color),
                            const SizedBox(height: 4),
                            Text(
                              destinations[index].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: color,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppDestination {
  const AppDestination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
