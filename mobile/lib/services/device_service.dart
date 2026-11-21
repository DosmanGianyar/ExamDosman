import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/app_config.dart';

class DeviceService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _kDeviceId = 'dosman_device_binding_id';
  static const _channel = MethodChannel(AppConfig.lockdownChannel);

  /// Validasi apakah [value] merupakan device ID unik (UUID v4/vendor atau `aid_<16hex>`),
  /// bukan Android `Build.ID` peninggalan versi APK lama.
  static bool isValidUniqueId(String value) {
    final v = value.trim();
    if (RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(v)) {
      return true;
    }
    return RegExp(r'^aid_[0-9a-f]{16}$').hasMatch(v);
  }

  /// Returns stable unique device ID:
  /// - Android: `aid_<Settings.Secure.ANDROID_ID>` (unique per app-signing key & device)
  /// - iOS: `identifierForVendor` UUID cached in Keychain
  /// - Fallback: random UUID persisted in SecureStorage
  static Future<String> getDeviceId() async {
    if (Platform.isAndroid) {
      try {
        final raw = ((await _channel.invokeMethod<String>('getAndroidId')) ?? '')
            .trim()
            .toLowerCase();
        if (RegExp(r'^[0-9a-f]{16}$').hasMatch(raw) &&
            raw != '9774d56d682e549c' &&
            raw != '0000000000000000') {
          final id = 'aid_$raw';
          await _storage.write(key: _kDeviceId, value: id);
          return id;
        }
      } catch (_) {}
    } else if (Platform.isIOS) {
      try {
        final cached = await _storage.read(key: _kDeviceId);
        if (cached != null && isValidUniqueId(cached)) return cached;
        final info = await DeviceInfoPlugin().iosInfo;
        final vid = (info.identifierForVendor ?? '').trim();
        if (vid.isNotEmpty) {
          await _storage.write(key: _kDeviceId, value: vid);
          return vid;
        }
      } catch (_) {}
    }
    return _getOrCreateUuid();
  }

  static Future<String> _getOrCreateUuid() async {
    final cached = await _storage.read(key: _kDeviceId);
    if (cached != null && isValidUniqueId(cached)) return cached;
    final uuid = _generateUuid();
    await _storage.write(key: _kDeviceId, value: uuid);
    return uuid;
  }

  static String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20,32)}';
  }

  static Future<String> getDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        return '${info.manufacturer} ${info.model}'.trim();
      }
      if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        final machine = info.utsname.machine.trim();
        if (machine.isNotEmpty && machine != info.model) {
          return 'Apple ${info.model} ($machine)';
        }
        return 'Apple ${info.model}';
      }
    } catch (_) {}
    return 'Unknown';
  }

  static String get platform => Platform.isAndroid ? 'android' : 'ios';
}
