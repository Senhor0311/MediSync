enum AppWindowSize { phone, tablet, desktop }

abstract final class AppBreakpoints {
  static const double tablet = 600;
  static const double desktop = 1024;
  static const double maxContentWidth = 1120;

  static AppWindowSize sizeOf(double width) => switch (width) {
    < tablet => AppWindowSize.phone,
    < desktop => AppWindowSize.tablet,
    _ => AppWindowSize.desktop,
  };
}
