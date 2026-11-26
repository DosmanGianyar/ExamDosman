// ===========================
// DOSMAN UJIAN - Dialog Kirim Darurat Proktor
// Digunakan proktor/pengawas untuk mengimpor paksa jawaban terkunci di HP siswa
// ke attempt kosong (0 terjawab) di Moodle ketika terlambat kirim > 30 menit.
// ===========================

import 'package:flutter/material.dart';
import '../services/exam_service.dart';
import '../services/offline_quiz_service.dart';

class ProctorRescueDialog {
  ProctorRescueDialog._();

  static Future<bool> show(
    BuildContext context, {
    required OfflineQuizPackage pkg,
  }) async {
    final codeCtrl = TextEditingController();
    var obscure = true;
    var isSending = false;
    String? errorMsg;

    final savedRes = await showDialog<({int totalSlots, int answeredSlots})?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFF59E0B), width: 1.4),
          ),
          title: const Row(
            children: [
              Icon(Icons.shield_rounded, color: Color(0xFFFBBF24), size: 24),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kirim Darurat (Kode Proktor)',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${pkg.quizName} • ID #${pkg.attemptId}\n'
                  'Jawaban terkunci di HP: ${pkg.answeredCount} / ${pkg.questions.length} soal.',
                  style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Masukkan Kode Kirim Darurat Proktor dari Dashboard Monitor Proktor (Tab Password Keluar & Keamanan):',
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeCtrl,
                  obscureText: obscure,
                  enabled: !isSending,
                  style: const TextStyle(color: Colors.white, letterSpacing: 1.2),
                  decoration: InputDecoration(
                    hintText: 'Kode Kirim Darurat Proktor',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    suffixIcon: IconButton(
                      onPressed: isSending
                          ? null
                          : () => setDlgState(() => obscure = !obscure),
                      icon: Icon(
                        obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        color: Colors.white60,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7F1D1D).withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF87171)),
                    ),
                    child: Text(
                      errorMsg!,
                      style: const TextStyle(color: Color(0xFFFECACA), fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSending ? null : () => Navigator.pop(ctx, null),
              child: const Text('Batal', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton.icon(
              onPressed: isSending
                  ? null
                  : () async {
                      final code = codeCtrl.text.trim();
                      if (code.length < 4) {
                        setDlgState(() => errorMsg = 'Masukkan minimal 4 karakter kode proktor.');
                        return;
                      }
                      setDlgState(() {
                        isSending = true;
                        errorMsg = null;
                      });
                      final res = await ExamService.rescueSubmitAttempt(
                        attemptId: pkg.attemptId,
                        proctorCode: code,
                        answerData: OfflineQuizService.buildSubmitPayload(pkg),
                        lockedAtEpochSec: pkg.lockedAtEpochSec,
                      );
                      if (!ctx.mounted) return;
                      if (res.success) {
                        await OfflineQuizService.archiveSubmittedPackage(
                          pkg,
                          serverVerifiedOk: true,
                          serverConfirmedAnswered: res.answeredSlots,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx, (
                            totalSlots: res.totalSlots,
                            answeredSlots: res.answeredSlots,
                          ));
                        }
                      } else {
                        setDlgState(() {
                          isSending = false;
                          errorMsg = res.message;
                        });
                      }
                    },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
              icon: isSending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.upload_rounded, size: 18),
              label: Text(isSending ? 'Mengirim...' : 'Proses Kirim Darurat'),
            ),
          ],
        ),
      ),
    );

    if (savedRes == null || !context.mounted) return false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF064E3B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF34D399), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.verified_rounded, color: Color(0xFF34D399), size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'BUKTI KIRIM DARURAT BERHASIL',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: Text(
          'Terkonfirmasi Server: ${savedRes.answeredSlots} / ${savedRes.totalSlots} soal berhasil disimpan dan dinilai di Moodle.\n\n'
          'Ujian: ${pkg.quizName} (ID #${pkg.attemptId})\n'
          'Salinan jawaban tetap tersimpan permanen di HP ini selama aplikasi tidak dihapus.',
          style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 13, height: 1.5),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              child: const Text('Selesai', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );

    return true;
  }
}
