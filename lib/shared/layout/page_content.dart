import 'package:flutter/material.dart';

import 'app_breakpoints.dart';

class PageContent extends StatelessWidget {
  const PageContent({super.key, required this.child, required this.storageKey});

  final Widget child;
  final String storageKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: PageStorageKey(storageKey),
        padding: EdgeInsets.all(
          constraints.maxWidth < AppBreakpoints.tablet ? 20 : 40,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppBreakpoints.maxContentWidth,
            ),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    );
  }
}
