import 'package:flutter/material.dart';
import '../models/course.dart';

class CourseCard extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;
  final int colorIndex;
  final int? finishedAttempts;
  final int? inProgressCount;

  const CourseCard({
    super.key,
    required this.course,
    required this.onTap,
    required this.colorIndex,
    this.finishedAttempts,
    this.inProgressCount,
  });

  static const List<List<Color>> _cardGradients = [
    [Color(0xFF1E3A8A), Color(0xFF2563EB)], // Navy -> Royal Blue
    [Color(0xFF0F172A), Color(0xFF334155)], // Dark Slate
    [Color(0xFF1D4ED8), Color(0xFF0284C7)], // Blue -> Cyan
    [Color(0xFF5B21B6), Color(0xFF7C3AED)], // Deep Violet
    [Color(0xFF065F46), Color(0xFF059669)], // Emerald
    [Color(0xFFB45309), Color(0xFFD97706)], // Amber Gold
  ];

  List<Color> get _gradient =>
      _cardGradients[colorIndex % _cardGradients.length];

  @override
  Widget build(BuildContext context) {
    final accent = _gradient.last;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Ikon Gradien Mewah
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),

              // Detail Mata Pelajaran / Course
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      course.fullname,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            course.categoryname.isNotEmpty
                                ? course.categoryname
                                : course.shortname,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: accent,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (finishedAttempts != null) _buildAttemptBadge(),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Tombol Masuk Elegan
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Buka',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: Color(0xFFFBBF24),
                      size: 12,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttemptBadge() {
    final fin = finishedAttempts ?? 0;
    final inp = inProgressCount ?? 0;

    final Color bg;
    final Color fg;
    final IconData icon;
    final String text;

    if (fin > 0) {
      bg = const Color(0xFFDCFCE7);
      fg = const Color(0xFF15803D);
      icon = Icons.check_circle_rounded;
      text = 'Nilai Terkirim • ${fin}x Dikerjakan';
    } else if (inp > 0) {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFB45309);
      icon = Icons.pending_rounded;
      text = 'Belum Dikirim';
    } else {
      bg = const Color(0xFFF1F5F9);
      fg = const Color(0xFF475569);
      icon = Icons.radio_button_unchecked_rounded;
      text = '0x Dikerjakan';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
