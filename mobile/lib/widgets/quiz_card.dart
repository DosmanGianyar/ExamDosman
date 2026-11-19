import 'package:flutter/material.dart';
import '../models/quiz.dart';

class QuizCard extends StatelessWidget {
  final Quiz quiz;
  final VoidCallback onTap;
  final int? finishedAttempts;
  final int? inProgressCount;

  const QuizCard({
    super.key,
    required this.quiz,
    required this.onTap,
    this.finishedAttempts,
    this.inProgressCount,
  });

  @override
  Widget build(BuildContext context) {
    final isOpen = quiz.isOpen;

    return GestureDetector(
      onTap: isOpen ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border(
            left: BorderSide(
              color: isOpen ? const Color(0xFF2563EB) : const Color(0xFF9CA3AF),
              width: 4,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Nama quiz + status badge ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      quiz.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isOpen
                            ? const Color(0xFF1F2937)
                            : const Color(0xFF9CA3AF),
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(isOpen: isOpen),
                ],
              ),

              // ── Intro / deskripsi ──
              if (quiz.intro.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  quiz.intro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                    height: 1.5,
                  ),
                ),
              ],

              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFF3F4F6)),
              const SizedBox(height: 12),

              // ── Info row: waktu & jadwal ──
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _InfoChip(
                    icon: Icons.timer_outlined,
                    label: quiz.timeLimitLabel,
                    color: const Color(0xFF2563EB),
                  ),
                  if (quiz.attempts > 0)
                    _InfoChip(
                      icon: Icons.replay_outlined,
                      label: '${quiz.attempts}x maks',
                      color: const Color(0xFF7C3AED),
                    ),
                  if (finishedAttempts != null)
                    _InfoChip(
                      icon: (finishedAttempts ?? 0) > 0
                          ? Icons.check_circle_rounded
                          : ((inProgressCount ?? 0) > 0
                              ? Icons.pending_rounded
                              : Icons.radio_button_unchecked_rounded),
                      label: (finishedAttempts ?? 0) > 0
                          ? 'Nilai Terkirim (${finishedAttempts}x)'
                          : ((inProgressCount ?? 0) > 0
                              ? 'Belum Dikirim'
                              : 'Belum Dikerjakan (0x)'),
                      color: (finishedAttempts ?? 0) > 0
                          ? const Color(0xFF15803D)
                          : ((inProgressCount ?? 0) > 0
                              ? const Color(0xFFB45309)
                              : const Color(0xFF475569)),
                    ),
                ],
              ),

              if (quiz.scheduleLabel != 'Selalu tersedia') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    _InfoChip(
                      icon: Icons.calendar_today_outlined,
                      label: quiz.scheduleLabel,
                      color: const Color(0xFF059669),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 14),

              // ── Tombol Mulai ──
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isOpen ? onTap : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isOpen
                        ? const Color(0xFF2563EB)
                        : const Color(0xFFE5E7EB),
                    foregroundColor: isOpen
                        ? Colors.white
                        : const Color(0xFF9CA3AF),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    isOpen ? '🔒  Masuk Mode Ujian' : '⏳  Belum Tersedia',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Status Badge ────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final bool isOpen;
  const _StatusBadge({required this.isOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isOpen
            ? const Color(0xFFDCFCE7)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isOpen ? '🟢 Tersedia' : '⚫ Tutup',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isOpen
              ? const Color(0xFF15803D)
              : const Color(0xFF6B7280),
        ),
      ),
    );
  }
}

// ─── Info Chip ───────────────────────────────────────────────────────────────

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
