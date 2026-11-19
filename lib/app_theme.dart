import 'package:material_ui/material_ui.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.paper,
    required this.ink,
    required this.muted,
    required this.green,
    required this.soft,
    required this.border,
    required this.panel,
    required this.keyboard,
    required this.keycap,
  });
  final Color paper, ink, muted, green, soft, border, panel, keyboard, keycap;
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>()!;
  static const light = AppColors(
    paper: Color(0xfff4f5ef),
    ink: Color(0xff172722),
    muted: Color(0xff53665e),
    green: Color(0xff235f48),
    soft: Color(0xffe6efe7),
    border: Color(0xffdce4db),
    panel: Colors.white,
    keyboard: Color(0xffe7ece3),
    keycap: Color(0xfffafbf8),
  );
  static const dark = AppColors(
    paper: Color(0xff101814),
    ink: Color(0xffe3eee7),
    muted: Color(0xffa6b9ae),
    green: Color(0xff9bd8b9),
    soft: Color(0xff233a2e),
    border: Color(0xff3a4c42),
    panel: Color(0xff19241e),
    keyboard: Color(0xff243129),
    keycap: Color(0xff303f35),
  );
  @override
  AppColors copyWith({
    Color? paper,
    Color? ink,
    Color? muted,
    Color? green,
    Color? soft,
    Color? border,
    Color? panel,
    Color? keyboard,
    Color? keycap,
  }) => AppColors(
    paper: paper ?? this.paper,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    green: green ?? this.green,
    soft: soft ?? this.soft,
    border: border ?? this.border,
    panel: panel ?? this.panel,
    keyboard: keyboard ?? this.keyboard,
    keycap: keycap ?? this.keycap,
  );
  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      paper: mix(paper, other.paper),
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      green: mix(green, other.green),
      soft: mix(soft, other.soft),
      border: mix(border, other.border),
      panel: mix(panel, other.panel),
      keyboard: mix(keyboard, other.keyboard),
      keycap: mix(keycap, other.keycap),
    );
  }
}

ThemeData consoleTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff235f48),
    brightness: brightness,
    surface: c.panel,
    primary: c.green,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Console SC',
    brightness: brightness,
    colorScheme: scheme,
    extensions: [c],
    scaffoldBackgroundColor: c.paper,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.paper,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
