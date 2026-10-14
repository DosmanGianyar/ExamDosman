// ===========================
// DOSMAN UJIAN - QR Login Scanner
// Dialog pemindai kode QR untuk login kartu peserta ujian
// ===========================

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrLoginScannerDialog extends StatefulWidget {
  const QrLoginScannerDialog({super.key});

  /// Tampilkan modal scanner dan kembalikan Map {username, password} jika berhasil.
  static Future<Map<String, String>?> show(BuildContext context) {
    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const QrLoginScannerDialog(),
    );
  }

  @override
  State<QrLoginScannerDialog> createState() => _QrLoginScannerDialogState();
}

class _QrLoginScannerDialogState extends State<QrLoginScannerDialog> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _hasScanned = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _processBarcode(String rawValue) {
    if (_hasScanned) return;

    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) return;

    String? username;
    String? password;
    String? name;

    // Format 1: JSON {"username": "...", "password": "...", "name": "..."}
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = json.decode(trimmed);
        if (decoded is Map) {
          username = (decoded['username'] ?? decoded['user'])?.toString().trim();
          password = (decoded['password'] ?? decoded['pass'])?.toString();
          name = (decoded['name'] ?? decoded['nama'])?.toString().trim();
        }
      } catch (_) {}
    }

    // Format 2: Prefix DOSMAN_LOGIN:user:pass:name atau DOSMAN:user:pass:name
    if (username == null || password == null) {
      if (trimmed.toUpperCase().startsWith('DOSMAN_LOGIN:')) {
        final parts = trimmed.substring('DOSMAN_LOGIN:'.length).split(':');
        if (parts.length >= 2) {
          username = parts[0].trim();
          password = parts[1].trim();
          if (parts.length >= 3) {
            name = parts.sublist(2).join(':').trim();
          }
        }
      } else if (trimmed.toUpperCase().startsWith('DOSMAN:')) {
        final parts = trimmed.substring('DOSMAN:'.length).split(':');
        if (parts.length >= 2) {
          username = parts[0].trim();
          password = parts[1].trim();
          if (parts.length >= 3) {
            name = parts.sublist(2).join(':').trim();
          }
        }
      }
    }

    // Format 3: Plain username:password atau username:password:name
    if (username == null || password == null) {
      final parts = trimmed.split(':');
      if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        username = parts[0].trim();
        password = parts[1].trim();
        if (parts.length >= 3) {
          name = parts.sublist(2).join(':').trim();
        }
      }
    }

    if (username != null && username.isNotEmpty && password != null && password.isNotEmpty) {
      _hasScanned = true;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop({
        'username': username,
        'password': password,
        'name': (name != null && name.isNotEmpty) ? name : username,
      });
    } else {
      setState(() {
        _errorMessage = 'Format QR kartu ujian tidak dikenali';
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _errorMessage = '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = media.size.height * 0.75;

    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner_rounded,
                    color: Color(0xFF60A5FA),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pindai Kartu Ujian',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Arahkan kamera ke QR Code kartu peserta',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
              ],
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          // Area Kamera
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: (capture) {
                    final barcodes = capture.barcodes;
                    for (final b in barcodes) {
                      final val = b.rawValue;
                      if (val != null && val.isNotEmpty) {
                        _processBarcode(val);
                        break;
                      }
                    }
                  },
                ),

                // Overlay reticle scanner
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF3B82F6), width: 2.5),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF3B82F6).withValues(alpha: 0.2),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),

                // Error message overlay
                if (_errorMessage.isNotEmpty)
                  Positioned(
                    bottom: 24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, color: Colors.white, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            _errorMessage,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Toolbar kontrol kamera
          Container(
            padding: EdgeInsets.fromLTRB(20, 14, 20, media.padding.bottom + 14),
            decoration: const BoxDecoration(
              color: Color(0xFF0B1120),
              border: Border(top: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  onPressed: () => _controller.toggleTorch(),
                  icon: const Icon(Icons.flash_on_rounded, size: 18),
                  label: const Text('Lampu', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _controller.switchCamera(),
                  icon: const Icon(Icons.cameraswitch_rounded, size: 18),
                  label: const Text('Ganti Kamera', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
