<?php
/**
 * Scheduled task: suspend siswa yang tidak aktif (app ping atau heartbeat stale).
 *
 * Jalan setiap menit via Moodle cron. Menggantikan ketergantungan pada
 * ping siswa lain atau admin membuka dashboard untuk memicu stale-check.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\task;

class suspend_stale_users_task extends \core\task\scheduled_task {

    // Harus sinkron dengan konstanta di stale_app_ping_suspend.inc.php dan heartbeat.php
    const STALE_APP_PING_SEC = 90;
    const HEARTBEAT_TIMEOUT  = 45;
    const HEARTBEAT_GRACE    = 120;

    public function get_name(): string {
        return get_string('task_suspend_stale_users', 'local_dosman_ujian');
    }

    public function execute(): void {
        // FIX: Kehilangan koneksi internet (Wi-Fi drop / signal loss) BUKAN bentuk kecurangan.
        // Auto-suspend via cron dinonaktifkan agar siswa tidak tersuspend false-positive
        // saat jaringan internet sekolah terputus sementara waktu.
        return;
    }

    /**
     * Suspend siswa Android (lock_status=1) yang tidak mengirim app_ping
     * lebih dari STALE_APP_PING_SEC detik DAN tidak punya heartbeat aktif.
     */
    private function suspend_stale_app_ping(int $now): int {
        global $DB;

        $pingThreshold = $now - self::STALE_APP_PING_SEC;
        $hbThreshold   = $now - self::HEARTBEAT_TIMEOUT;

        $sql = "SELECT a.userid
                  FROM {local_dosman_ujian_appstatus} a
                  JOIN {user} u ON u.id = a.userid AND u.deleted = 0 AND u.suspended = 0
                 WHERE a.lock_status = 1
                   AND a.lastping < :ping_threshold
                   AND NOT EXISTS (
                       SELECT 1 FROM {local_dosman_ujian_sessions} s
                        WHERE s.userid = a.userid
                          AND s.status = 'active'
                          AND s.last_heartbeat >= :hb_threshold
                   )";

        $candidates = $DB->get_fieldset_sql($sql, [
            'ping_threshold' => $pingThreshold,
            'hb_threshold'   => $hbThreshold,
        ]);

        return $this->do_suspend($candidates, 'Keluar aplikasi (otomatis — app ping stale)', $now);
    }

    /**
     * Suspend siswa Android yang sedang ujian tapi heartbeat-nya stale.
     * Hanya menarget Android (lock_status=1) karena SEB tidak punya heartbeat
     * periodik — SEB hanya update last_heartbeat saat load halaman, bukan tiap 10 detik.
     * Cakupan: semua quiz aktif.
     */
    private function suspend_stale_heartbeat(int $now): int {
        global $DB;

        $hbThreshold    = $now - self::HEARTBEAT_TIMEOUT;
        $graceThreshold = $now - self::HEARTBEAT_GRACE;

        // Hanya Android (lock_status=1): punya mekanisme heartbeat tiap 10 detik dari Flutter.
        // SEB (lock_status=0) dikecualikan — mereka tidak punya heartbeat periodik.
        $sql = "SELECT DISTINCT s.userid
                  FROM {local_dosman_ujian_sessions} s
                  JOIN {user} u ON u.id = s.userid AND u.deleted = 0 AND u.suspended = 0
                  JOIN {local_dosman_ujian_appstatus} a ON a.userid = s.userid AND a.lock_status = 1
                 WHERE s.status = 'active'
                   AND s.last_heartbeat < :hb_threshold
                   AND s.timecreated < :grace";

        $candidates = $DB->get_fieldset_sql($sql, [
            'hb_threshold' => $hbThreshold,
            'grace'        => $graceThreshold,
        ]);

        return $this->do_suspend($candidates, 'Keluar saat ujian (otomatis — heartbeat timeout)', $now);
    }

    /**
     * Suspend daftar userid: suspend akun Moodle, hapus token, putus sesi,
     * update appstatus dan sessions, catat log.
     */
    private function do_suspend(array $candidates, string $reason, int $now): int {
        global $DB;

        if (empty($candidates)) {
            return 0;
        }

        $siteAdmins    = array_filter(array_map('trim', explode(',', (string)(get_config('core', 'siteadmins') ?? ''))));
        $mobileService = $DB->get_record('external_services', ['shortname' => 'dosman_ujian_mobile']);
        $logCourseId   = (int)($DB->get_field_sql('SELECT MIN(id) FROM {course}') ?: 1);

        $suspended = 0;

        foreach ($candidates as $rawUid) {
            $userid = (int)$rawUid;
            if ($userid <= 1) {
                continue;
            }
            if (in_array((string)$userid, $siteAdmins, true)) {
                continue;
            }
            // Lewati manager / guru
            $isPrivileged = $DB->record_exists_sql(
                "SELECT 1
                   FROM {role_assignments} ra
                   JOIN {role} r ON r.id = ra.roleid
                  WHERE ra.userid = :uid
                    AND r.archetype IN ('manager','coursecreator','editingteacher','teacher')",
                ['uid' => $userid]
            );
            if ($isPrivileged) {
                continue;
            }

            try {
                // Suspend akun Moodle
                $DB->set_field('user', 'suspended',    1,    ['id' => $userid]);
                $DB->set_field('user', 'timemodified', $now, ['id' => $userid]);

                // Hapus token API mobile
                if ($mobileService) {
                    $DB->delete_records('external_tokens', [
                        'externalserviceid' => (int)$mobileService->id,
                        'userid'            => $userid,
                    ]);
                }

                // Putus semua sesi Moodle
                \core\session\manager::kill_user_sessions($userid);

                // Blokir semua sesi ujian aktif
                $DB->execute(
                    "UPDATE {local_dosman_ujian_sessions}
                        SET status         = 'blocked',
                            blocked_reason = ?,
                            blocked_at     = ?,
                            timemodified   = ?
                      WHERE userid = ? AND status = 'active'",
                    [$reason, $now, $now, $userid]
                );

                // Update appstatus: tandai terblokir
                if ($DB->record_exists('local_dosman_ujian_appstatus', ['userid' => $userid])) {
                    $DB->execute(
                        "UPDATE {local_dosman_ujian_appstatus}
                            SET lock_status   = 2,
                                current_quizid = 0,
                                lastping       = ?
                          WHERE userid = ?",
                        [$now, $userid]
                    );
                }

                // Log kejadian
                $DB->insert_record('local_dosman_ujian_logs', (object)[
                    'userid'      => $userid,
                    'courseid'    => $logCourseId,
                    'quizid'      => 0,
                    'eventtype'   => 'app_ping_stale_auto_suspend',
                    'eventdata'   => json_encode([
                        'reason'           => $reason,
                        'stale_seconds'    => self::STALE_APP_PING_SEC,
                    ], JSON_UNESCAPED_UNICODE),
                    'suspicious'  => 1,
                    'timecreated' => $now,
                ]);

                $suspended++;

            } catch (\Throwable $e) {
                mtrace("dosman_ujian: gagal suspend userid {$userid}: " . $e->getMessage());
            }
        }

        return $suspended;
    }
}
