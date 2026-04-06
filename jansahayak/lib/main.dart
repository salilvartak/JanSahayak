import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'config/env_config.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load .env; gracefully degrade if file missing (e.g. first local run)
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    if (kDebugMode) debugPrint('[main] .env not found — using defaults');
  }

  EnvConfig.validate();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  if (kReleaseMode) {
    // In production, catch uncaught Flutter errors and suppress ugly red screens
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
    };
    runZonedGuarded(
      () => runApp(const JanSahayakApp()),
      (error, stack) {
        // Silently swallowed in production; hook crash reporting here
      },
    );
  } else {
    runApp(const JanSahayakApp());
  }
}

class JanSahayakApp extends StatelessWidget {
  const JanSahayakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JanSahayak',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _RootScreen(),
    );
  }
}

class _RootScreen extends StatefulWidget {
  const _RootScreen();

  @override
  State<_RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<_RootScreen> {
  int _index = 0;
  int _historyRefreshSeed = 0;

  void _onTabChanged(int i) {
    if (i == _index) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _index = i;
      if (i == 1) {
        _historyRefreshSeed++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(isActive: _index == 0),
          HistoryScreen(
            key: ValueKey(_historyRefreshSeed),
            refreshSeed: _historyRefreshSeed,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTabChanged,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.camera_alt_outlined),
            selectedIcon: Icon(Icons.camera_alt_rounded),
            label: '',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: '',
          ),
        ],
      ),
    );
  }
}
