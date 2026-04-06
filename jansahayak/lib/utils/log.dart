import 'package:flutter/foundation.dart';

/// Debug-only logger.  All calls compile to no-ops in release builds
/// because [kDebugMode] is a compile-time constant.
abstract final class Log {
  static void d(String tag, String message) {
    if (kDebugMode) debugPrint('[$tag] $message');
  }

  static void w(String tag, String message) {
    if (kDebugMode) debugPrint('[$tag] WARN: $message');
  }

  static void e(String tag, String message, [Object? error]) {
    if (kDebugMode) {
      debugPrint('[$tag] ERROR: $message');
      if (error != null) debugPrint('  → $error');
    }
  }
}
