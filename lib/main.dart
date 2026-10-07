import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data/app_store.dart';
import 'data/supabase_config.dart';
import 'push_router.dart';
import 'services/push_service.dart';
import 'root_shell.dart';
import 'theme/colors.dart';
import 'theme/theme_provider.dart';
import 'widgets/reset_banner.dart';
import 'widgets/ui_widgets.dart';

Future<void> main() async {
  // Has to happen before anything else touches a plugin (Supabase's client
  // included) — see the Flutter docs on calling plugins before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  // Wires up the real backend (see supabase_config.dart + supabase/
  // schema.sql). AppStore itself doesn't read/write through this yet —
  // this is deliberately just the connection, landing on its own first so
  // a build break is easy to pin on this one change rather than buried
  // inside the bigger real-accounts/friends/DMs/Stories rewiring to come.
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );
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
    _store.load().then((_) => _store.setAppForeground(true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _store.setAppForeground(state == AppLifecycleState.resumed);
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
            navigatorKey: appNavigatorKey,
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

/// The branded splash — shown for a flat 2 seconds every time the app
/// opens, no matter how fast (or slow) AppStore.load() actually finishes.
/// Before this, the old loading screen only showed up for however long the
/// local mock store took to read from disk, which was fast enough to just
/// flash and barely register rather than read as a deliberate splash.
class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  bool _splashElapsed = false;
  bool _tapsHooked = false;

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _splashElapsed = true);
    });
  }

  /// Once the app is actually on screen, start honoring taps on push
  /// notifications (including the one that launched the app).
  void _hookPushTaps(AppStore store) {
    if (_tapsHooked) return;
    _tapsHooked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PushService.listenForTaps((kind, data) => openPushTarget(store, kind, data));
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // Whichever finishes last: the 2s splash timer, or the store actually
    // being ready — so a slow load never drops you into a half-ready app
    // early, and a fast one never skips the splash.
    if (!_splashElapsed || !store.loaded) {
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
    _hookPushTaps(store);
    return const Stack(
      children: [
        RootShell(),
        ResetBanner(),
      ],
    );
  }
}
