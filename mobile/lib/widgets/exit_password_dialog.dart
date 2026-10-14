// ===========================
// Dialog password keluar / lepas semat — terpisah dari overlay agar tidak siklus impor.
// ===========================

import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/kiosk_controller.dart';

class ExitPasswordDialog extends StatefulWidget {
  /// true = teks untuk siswa yang baru melepas screen pin (Recent+Back).
  final bool forUnpinScreen;

  const ExitPasswordDialog({super.key, this.forUnpinScreen = false});

  @override
  State<ExitPasswordDialog> createState() => _ExitPasswordDialogState();
}

class _ExitPasswordDialogState extends State<ExitPasswordDialog> {
  final _ctrl   = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final username = (await AuthService.getUsername()).toLowerCase().trim();
      final isReviewer = username == 'playstore.review' || username == 'appstore.review';
      final entered = _ctrl.text.trim();

      // Akun reviewer (Play Store & App Store) selalu dapat keluar dengan PIN 123456
      if (isReviewer && entered == '123456') {
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      final fetch = await KioskController.instance.fetchExitPassword();
      if (!mounted) return;
      if (!fetch.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tidak dapat memverifikasi — periksa koneksi lalu coba lagi.',
            ),
            backgroundColor: Color(0xFFD97706),
          ),
        );
        return;
      }
      final isOk = entered == fetch.password.trim() || (isReviewer && entered == '123456');
      Navigator.of(context).pop(isOk);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bodyText = widget.forUnpinScreen
        ? 'Anda melepas semat layar. Masukkan kata sandi administrator untuk melanjutkan — jika salah, aplikasi akan disematkan lagi.'
        : 'Masukkan kata sandi administrator untuk keluar dari mode ujian.';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: const BoxDecoration(
                color: Color(0xFFDC2626),
                borderRadius: BorderRadius.only(
                  topLeft:  Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  const Icon(Icons.lock_outline, color: Colors.white, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    widget.forUnpinScreen
                        ? 'Konfirmasi lepas semat'
                        : 'Keluar Aplikasi',
                    style: const TextStyle(
                      color:      Colors.white,
                      fontSize:   17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    bodyText,
                    style: const TextStyle(
                      fontSize: 13,
                      color:    Color(0xFF6B7280),
                      height:   1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller:      _ctrl,
                    obscureText:     _obscure,
                    autofocus:       true,
                    textInputAction: TextInputAction.done,
                    onSubmitted:     (_) => _submit(),
                    style: const TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w500,
                      color:      Color(0xFF1F2937),
                    ),
                    decoration: InputDecoration(
                      hintText:  'Kata sandi',
                      filled:    true,
                      fillColor: const Color(0xFFF3F4F6),
                      prefixIcon: const Icon(
                        Icons.key_outlined,
                        color: Color(0xFF9CA3AF),
                        size: 20,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: const Color(0xFF9CA3AF),
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                        tooltip: _obscure ? 'Tampilkan' : 'Sembunyikan',
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical:   14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFFE5E7EB),
                          width: 1.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFFDC2626),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loading
                              ? null
                              : () => Navigator.of(context).pop(null),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            foregroundColor: const Color(0xFF6B7280),
                            side: const BorderSide(
                                color: Color(0xFFD1D5DB)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'Batal',
                            style: TextStyle(
                              fontSize:   14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  widget.forUnpinScreen
                                      ? 'Lanjutkan'
                                      : 'Keluar',
                                  style: const TextStyle(
                                    fontSize:   14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
