import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/exam_service.dart';

class BlockedScreen extends StatefulWidget {
  const BlockedScreen({
    super.key,
    required this.userId,
    required this.reason,
  });

  final int userId;
  final String reason;

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  Timer? _pollTimer;
  bool _checking = false;
  String _statusText = 'Akun masih diblokir.';

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      _pollBlockedStatus(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollBlockedStatus({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final result = await ExamService.checkBlocked(userId: widget.userId);
      if (!mounted) return;

      if (!result.reachable) {
        if (!silent) {
          setState(() {
            _statusText = 'Tidak dapat menghubungi server. Coba lagi sebentar.';
          });
        }
        return;
      }

      if (!result.blocked) {
        await AuthService.saveBlockedStatus(false);
        await AuthService.saveSuspendedByAdmin(false);
        await ExamService.clearPendingSuspend();
        // Pastikan token REST API aktif kembali setelah di-unsuspend
        // (suspend_student.php menghapus token lama di server).
        final hasSession = await AuthService.restoreSession();
        bool tokenOk = false;
        if (hasSession) {
          try {
            await ApiService.getSiteInfo();
            tokenOk = true;
          } catch (_) {
            tokenOk = false;
          }
        }
        if (!tokenOk) {
          final uname = await AuthService.getUsername();
          final pwd = await AuthService.getPassword();
          if (uname.isNotEmpty && pwd != null && pwd.isNotEmpty) {
            try {
              await AuthService.login(uname, pwd);
              tokenOk = true;
            } catch (_) {}
          }
        }
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          tokenOk ? '/courses' : '/login',
          (route) => false,
        );
        return;
      }

      final reason = result.reason.trim();
      setState(() {
        _statusText = reason.isEmpty ? 'Akun masih diblokir oleh pengawas.' : reason;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7F1D1D),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Center(
                      child: Text('🚫', style: TextStyle(fontSize: 48)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Akun Diblokir',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.reason,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _checking ? null : () => _pollBlockedStatus(),
                      icon: _checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_checking ? 'Memeriksa...' : 'Cek Status Lagi'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
