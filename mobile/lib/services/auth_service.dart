// ===========================
// DOSMAN UJIAN - Auth Service
// Manajemen token, user info, dan kredensial di secure storage
// ===========================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_service.dart';

class AuthService {
  // Singleton
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  // Secure storage dengan Android Keystore encryption
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // ─── Storage Keys ───────────────────────────────────────────────────────────
  static const _keyToken    = 'dosman_token';
  static const _keyUserId   = 'dosman_userid';
  static const _keyUsername = 'dosman_username';
  static const _keyFullname = 'dosman_fullname';
  static const _keyDepartment = 'dosman_department';
  static const _keyPassword = 'dosman_password'; // untuk auto-login WebView
  static const _keyBlockedStatus    = 'dosman_blocked_status';
  static const _keySuspendedByAdmin = 'dosman_suspended_by_admin';



  // ─── Save ───────────────────────────────────────────────────────────────────

  /// Simpan token Moodle ke secure storage dan set ke ApiService.
  static Future<void> saveToken(String token) async {
    await _storage.write(key: _keyToken, value: token);
    ApiService.setToken(token);
  }

  /// Simpan info user yang didapat dari core_webservice_get_site_info.
  static Future<void> saveUserInfo({
    required int    userId,
    required String username,
    required String fullname,
  }) async {
    await Future.wait([
      _storage.write(key: _keyUserId,   value: userId.toString()),
      _storage.write(key: _keyUsername, value: username),
      _storage.write(key: _keyFullname, value: fullname),
    ]);
  }

  /// Simpan password (terenkripsi) untuk keperluan auto-login WebView.
  static Future<void> savePassword(String password) async {
    await _storage.write(key: _keyPassword, value: password);
  }


  // ─── Read ────────────────────────────────────────────────────────────────────

  static Future<String?> getToken() => _storage.read(key: _keyToken);

  static Future<int> getUserId() async {
    final val = await _storage.read(key: _keyUserId);
    return int.tryParse(val ?? '0') ?? 0;
  }

  static Future<String> getUsername() async {
    return await _storage.read(key: _keyUsername) ?? 'Siswa';
  }

  static Future<String> getFullname() async {
    return await _storage.read(key: _keyFullname) ?? 'Siswa';
  }

  static Future<void> saveDepartment(String department) async {
    await _storage.write(key: _keyDepartment, value: department);
  }

  static Future<String> getDepartment() async {
    return await _storage.read(key: _keyDepartment) ?? '';
  }

  /// Pisahkan nama siswa dan kelas secara rapi tanpa memotong nama.
  static ({String name, String studentClass}) parseNameAndClass(
    String fullname,
    String department,
  ) {
    final raw = fullname.trim();
    if (raw.contains('|')) {
      final parts = raw.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final name = parts.isNotEmpty ? parts.first : raw;
      final cls = parts.length >= 2 ? parts[1] : department.trim();
      return (name: name, studentClass: cls);
    }
    return (name: raw, studentClass: department.trim());
  }

  static Future<String?> getPassword() => _storage.read(key: _keyPassword);
  static Future<bool> getBlockedStatus() async {
    final val = await _storage.read(key: _keyBlockedStatus);
    return val == '1';
  }


  // ─── Auth State ──────────────────────────────────────────────────────────────

  /// Cek apakah user sudah login (ada token di storage).
  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// Restore token ke ApiService setelah app restart.
  /// Dipanggil di SplashScreen sebelum cek auth.
  static Future<bool> restoreSession() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return false;
    ApiService.setToken(token);
    return true;
  }

  // ─── Full Login Flow ─────────────────────────────────────────────────────────

  /// Login lengkap:
  /// 1. Ambil token dari Moodle
  /// 2. Verifikasi token via get_site_info
  /// 3. Simpan semua data ke secure storage
  /// Returns info user {fullname, userid, username}
  static Future<Map<String, dynamic>> login(
    String username,
    String password,
  ) async {
    // 1. Ambil token — exception di sini berarti kredensial salah atau network error
    final token = await ApiService.loginGetToken(username, password);

    // 2. Ambil info user — jika timeout/network error, lanjut dengan data minimal.
    //    Token sudah valid (langkah 1 sukses), siswa tetap bisa masuk.
    int userId = 0;
    String fullname = username;
    try {
      final siteInfo = await ApiService.getSiteInfo(token: token);
      userId   = (siteInfo['userid']   as num?)?.toInt() ?? 0;
      fullname =  siteInfo['fullname'] as String? ?? username;
    } catch (_) {
      // getSiteInfo gagal (jaringan lambat) — lanjut dengan data default
    }

    // 3. Simpan ke secure storage
    await Future.wait([
      saveToken(token),
      savePassword(password),
      saveUserInfo(
        userId:   userId,
        username: username,
        fullname: fullname,
      ),
    ]);

    return {
      'token':    token,
      'userid':   userId,
      'username': username,
      'fullname': fullname,
    };
  }

  // ─── Logout ──────────────────────────────────────────────────────────────────

  /// Hapus data sesi dari storage.
  static Future<void> logout() async {
    await Future.wait([
      _storage.delete(key: _keyToken),
      _storage.delete(key: _keyPassword),
      _storage.delete(key: _keyBlockedStatus),
      _storage.delete(key: _keyUserId),
      _storage.delete(key: _keyUsername),
      _storage.delete(key: _keyFullname),
      _storage.delete(key: _keyDepartment),
      _storage.delete(key: _keySuspendedByAdmin),
    ]);
    ApiService.clearToken();
  }

  static Future<void> saveBlockedStatus(bool blocked) async {
    await _storage.write(key: _keyBlockedStatus, value: blocked ? '1' : '0');
  }

  /// Tandai bahwa akun siswa disuspend oleh admin/guru dari dashboard.
  /// Login screen membaca flag ini untuk menampilkan banner suspend.
  static Future<void> saveSuspendedByAdmin(bool suspended) async {
    await _storage.write(key: _keySuspendedByAdmin, value: suspended ? '1' : '0');
  }

  static Future<bool> getSuspendedByAdmin() async {
    final val = await _storage.read(key: _keySuspendedByAdmin);
    return val == '1';
  }

  // ─── Debug (hapus semua storage) ────────────────────────────────────────────

  /// Hapus seluruh isi secure storage. Hanya untuk debugging.
  static Future<void> clearAll() async {
    await _storage.deleteAll();
    ApiService.clearToken();
  }
}
