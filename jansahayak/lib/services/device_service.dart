import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Generates and persists a UUID device identifier in SharedPreferences.
/// Now uses platform hardware IDs for consistency across installs.
class DeviceService {
  DeviceService._();

  static const _prefKey = 'jan_device_id';
  static String? _cache;

  /// Returns the device ID, generating and persisting one on first call.
  static Future<String> getDeviceId() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_prefKey);

    if (id == null) {
      // Try to get a hardware-based persistent ID
      final hwId = await _getPersistentHardwareId();
      if (hwId != null) {
        id = hwId;
      } else {
        // Fallback to random if all else fails
        id = const Uuid().v4();
      }
      await prefs.setString(_prefKey, id);
    }
    _cache = id;
    return id;
  }

  /// Attempts to get a platform-specific ID that survives uninstalls.
  static Future<String?> _getPersistentHardwareId() async {
    try {
      if (Platform.isAndroid) {
        // In modern Android, android_id package provides the most stable ID (SSAID)
        const androidIdPlugin = AndroidId();
        final ssaid = await androidIdPlugin.getId();
        if (ssaid != null) {
          // Backend expects UUID format, generate deterministic v5 from SSAID
          // NAMESPACE_URL = 6ba7b811-9dad-11d1-80b4-00c04fd430c8
          return const Uuid().v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8', 'android-$ssaid');
        }
      } else if (Platform.isIOS) {
        final devInfo = DeviceInfoPlugin();
        final iosInfo = await devInfo.iosInfo;
        // identifierForVendor is persistent as long as at least one vendor app is installed
        return iosInfo.identifierForVendor;
      }
    } catch (e) {
      debugPrint('Error getting device info: $e');
    }
    return null;
  }

  /// Overwrites the stored ID (called when the backend mints a new one).
  static Future<void> updateDeviceId(String newId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, newId);
    _cache = newId;
  }
}
