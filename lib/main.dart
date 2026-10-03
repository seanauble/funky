import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'data/app_store.dart';
import 'root_shell.dart';
import 'theme/colors.dart';
import 'theme/theme_provider.dart';
import 'widgets/reset_banner.dart';
import 'widgets/ui_widgets.dart';

void main() {
  runApp(const FunkyApp());
}

class FunkyApp extends StatefulWidget {
  const FunkyApp({super.key});

  @override
  State<FunkyApp> createState() => _FunkyAppState();
}

class _FunkyAppState extends State<FunkyApp> with WidgetsBindingObserver {
  late final ThemeProvider _themeProvider;
  late final AppStore _store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeProvider = ThemeProvider();
    _store = AppStore();
    _themeProvider.load();
    _store.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    _themeProvider.updateSystemBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  Widget build(BuildContext context) {
    _themeProvider.updateSystemBrightness(MediaQuery.platformBrightnessOf(context));

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _themeProvider),
        ChangeNotifierProvider.value(value: _store),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) {
          final tokens = theme.tokens;
          return MaterialApp(
            title: 'FUNKY',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: theme.isDark ? Brightness.dark : Brightness.light,
              scaffoldBackgroundColor: tokens.bg,
              useMaterial3: true,
              extensions: [FunkyTokens(tokens)],
            ),
            home: const _AppRoot(),
          );
        },
      ),
    );
  }
}

class _AppRoot extends StatelessWidget {
  const _AppRoot();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (!store.loaded) {
      final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
      return Scaffold(
        backgroundColor: tokens.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/branding/funky_mark.png', width: 88, height: 88),
              const SizedBox(height: 14),
              Image.asset('assets/branding/funky_wordmark.png', width: 160),
            ],
          ),
        ),
      );
    }
    return const Stack(
      children: [
        RootShell(),
        ResetBanner(),
      ],
    );
  }
}
