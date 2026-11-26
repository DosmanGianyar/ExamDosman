<?php
/**
 * Endpoint: Kirim Darurat (Kode Proktor) untuk menyelamatkan jawaban terkunci dari HP siswa
 * ketika attempt di Moodle sudah telanjur ditutup sebagai gaveup (0 terjawab) setelah melewati batas graceperiod.
 *
 * Penjaga keamanan ketat:
 *  - Wajib token aktif milik siswa pemilik attempt.
 *  - Wajib cocok dengan Kode Kirim Darurat Proktor (admin_rescue_password) di DB.
 *  - TIDAK pernah menimpa attempt yang sudah memiliki jawaban tersimpan (HTTP 409).
 *  - Hanya memulihkan attempt kosong (answered_slots == 0) di dalam transaksi DB resmi + mencatat audit log.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

define('NO_MOODLE_COOKIES', true);
define('AJAX_SCRIPT', true);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed']);
    exit;
}

require_once(__DIR__ . '/../../config.php');
require_once($CFG->dirroot . '/mod/quiz/locallib.php');
require_once($CFG->dirroot . '/question/engine/lib.php');

try {
    global $DB;

    $body        = json_decode(file_get_contents('php://input'), true) ?: [];
    $token       = trim((string)($body['token'] ?? ''));
    $attemptId   = (int)($body['attempt_id'] ?? 0);
    $proctorCode = trim((string)($body['proctor_code'] ?? ''));
    $data        = $body['data'] ?? null;
    $lockedAt    = (int)($body['locked_at'] ?? 0);

    if ($token === '' || $attemptId <= 0 || $proctorCode === '' || !is_array($data)) {
        http_response_code(400);
        echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap.']);
        exit;
    }

    // 1. Autentikasi token siswa (izinkan meski akun sempat di-suspend setelah ujian selesai, asal tidak dihapus).
    $now = time();
    $tokRow = $DB->get_record_sql(
        "SELECT et.userid
           FROM {external_tokens} et
           JOIN {user} u ON u.id = et.userid
          WHERE et.token = ?
            AND (et.validuntil = 0 OR et.validuntil > ?)
            AND u.deleted = 0
          LIMIT 1",
        [$token, $now]
    );
    if (!$tokRow) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token login tidak valid atau kedaluwarsa.']);
        exit;
    }
    $student = $DB->get_record('user', ['id' => (int)$tokRow->userid, 'deleted' => 0]);
    if (!$student) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Pengguna tidak ditemukan.']);
        exit;
    }

    // 2. Validasi Kode Kirim Darurat Proktor langsung dari DB (bypass cache).
    $expectedCodeRaw = $DB->get_field('config_plugins', 'value', [
        'plugin' => 'local_dosman_ujian',
        'name'   => 'admin_rescue_password',
    ]);
    $expectedCode = $expectedCodeRaw !== false ? trim((string)$expectedCodeRaw) : '';
    if ($expectedCode === '') {
        http_response_code(403);
        echo json_encode(['success' => false, 'message' => 'Kode Kirim Darurat Proktor belum diatur di Dashboard Proktor.']);
        exit;
    }
    if (!hash_equals($expectedCode, $proctorCode)) {
        http_response_code(403);
        echo json_encode(['success' => false, 'message' => 'Kode Proktor salah. Periksa kode di Dashboard Monitor → Tab Password Keluar & Keamanan.']);
        exit;
    }

    // 3. Validasi kepemilikan attempt siswa.
    $attempt = $DB->get_record('quiz_attempts', [
        'id'     => $attemptId,
        'userid' => (int)$student->id,
    ]);
    if (!$attempt) {
        http_response_code(404);
        echo json_encode(['success' => false, 'message' => 'Attempt ujian tidak ditemukan untuk akun ini.']);
        exit;
    }

    $qubaId = (int)$attempt->uniqueid;
    $cntRow = $DB->get_record_sql(
        "SELECT COUNT(*) AS total_slots,
                SUM(CASE WHEN responsesummary IS NOT NULL AND TRIM(responsesummary) <> '' THEN 1 ELSE 0 END) AS answered_slots
           FROM {question_attempts}
          WHERE questionusageid = ?",
        [$qubaId]
    );
    $totalSlots    = (int)($cntRow->total_slots ?? 0);
    $answeredSlots = (int)($cntRow->answered_slots ?? 0);

    // 4. Penjaga anti-timpa: tolak keras jika attempt sudah memiliki jawaban di server.
    if ($attempt->state === 'finished' && $answeredSlots > 0) {
        http_response_code(409);
        echo json_encode([
            'success'        => false,
            'attempt_id'     => $attemptId,
            'total_slots'    => $totalSlots,
            'answered_slots' => $answeredSlots,
            'message'        => "Attempt ini sudah memiliki {$answeredSlots} jawaban tersimpan di server dan tidak dapat ditimpa.",
        ]);
        exit;
    }

    // 5. Saring payload agar hanya key milik qubaId attempt ini yang diterima.
    $rawAnswerMap      = [];
    $matchedAnswerKeys = 0;
    $prefixPattern     = '/^q' . $qubaId . ':(\d+)_(answer|:sequencecheck)$/';

    foreach ($data as $item) {
        if (!is_array($item)) {
            continue;
        }
        $k = trim((string)($item['name'] ?? ''));
        $v = (string)($item['value'] ?? '');
        if ($k === '' || !preg_match($prefixPattern, $k, $m)) {
            continue;
        }
        $rawAnswerMap[$k] = $v;
        if ($m[2] === 'answer' && trim($v) !== '') {
            $matchedAnswerKeys++;
        }
    }

    if ($matchedAnswerKeys === 0) {
        http_response_code(400);
        echo json_encode(['success' => false, 'message' => 'Data jawaban tidak valid atau tidak cocok dengan attempt ini.']);
        exit;
    }

    // 6. Kembalikan step gaveup kosong lalu proses ulang dengan engine penilaian resmi Moodle.
    $transaction        = $DB->start_delegated_transaction();
    \core\session\manager::set_user($student);
    $originalTimeFinish = (int)$attempt->timefinish;

    if ($attempt->state === 'finished' || $attempt->state === 'abandoned' || $attempt->state === 'overdue') {
        $qaIds = $DB->get_fieldset_select('question_attempts', 'id', 'questionusageid = ?', [$qubaId]);
        if (!empty($qaIds)) {
            list($inQaSql, $qaParams) = $DB->get_in_or_equal($qaIds, SQL_PARAMS_QM);
            $stepIdsToDelete = $DB->get_fieldset_select(
                'question_attempt_steps',
                'id',
                "questionattemptid {$inQaSql} AND sequencenumber > 0",
                $qaParams
            );
            if (!empty($stepIdsToDelete)) {
                list($inStepSql, $stepParams) = $DB->get_in_or_equal($stepIdsToDelete, SQL_PARAMS_QM);
                $DB->delete_records_select('question_attempt_step_data', "attemptstepid {$inStepSql}", $stepParams);
                $DB->delete_records_select('question_attempt_steps', "id {$inStepSql}", $stepParams);
            }
            $DB->execute(
                "UPDATE {question_attempts} SET responsesummary = NULL, timemodified = ? WHERE questionusageid = ?",
                [$now, $qubaId]
            );
        }

        $DB->update_record('quiz_attempts', (object)[
            'id'             => $attemptId,
            'state'          => 'inprogress',
            'timefinish'     => 0,
            'sumgrades'      => null,
            'timecheckstate' => null,
            'timemodified'   => $now,
        ]);
    }

    $attemptobj = \mod_quiz\quiz_attempt::create($attemptId);
    $postData   = [];
    foreach ($attemptobj->get_slots() as $slot) {
        $qa          = $attemptobj->get_question_attempt($slot);
        $fieldPrefix = $qa->get_field_prefix();
        $postData[$fieldPrefix . ':sequencecheck'] = (string)$qa->get_sequence_check_count();
        if (array_key_exists($fieldPrefix . 'answer', $rawAnswerMap)) {
            $postData[$fieldPrefix . 'answer'] = $rawAnswerMap[$fieldPrefix . 'answer'];
        }
    }

    $attemptobj->process_submitted_actions($now, false, $postData);
    $finishTs = $originalTimeFinish > 0 ? $originalTimeFinish : $now;
    $attemptobj->process_finish($now, false, $finishTs, true);

    $finalCnt = $DB->get_record_sql(
        "SELECT COUNT(*) AS total_slots,
                SUM(CASE WHEN responsesummary IS NOT NULL AND TRIM(responsesummary) <> '' THEN 1 ELSE 0 END) AS answered_slots
           FROM {question_attempts}
          WHERE questionusageid = ?",
        [$qubaId]
    );
    $finalAttempt = $DB->get_record('quiz_attempts', ['id' => $attemptId], 'id,quiz,state,sumgrades,timefinish');

    $finalTotal    = (int)($finalCnt->total_slots ?? $totalSlots);
    $finalAnswered = (int)($finalCnt->answered_slots ?? 0);

    $DB->insert_record('local_dosman_ujian_logs', (object)[
        'userid'      => (int)$student->id,
        'courseid'    => (int)$attemptobj->get_courseid(),
        'quizid'      => (int)$attempt->quiz,
        'eventtype'   => 'rescue_submit_attempt',
        'eventdata'   => json_encode([
            'attempt_id'     => $attemptId,
            'matched_inputs' => $matchedAnswerKeys,
            'answered_slots' => $finalAnswered,
            'total_slots'    => $finalTotal,
            'locked_at'      => $lockedAt,
            'sumgrades'      => $finalAttempt ? $finalAttempt->sumgrades : null,
        ]),
        'suspicious'  => 0,
        'timecreated' => $now,
    ]);

    $transaction->allow_commit();

    echo json_encode([
        'success'        => true,
        'attempt_id'     => $attemptId,
        'state'          => $finalAttempt ? (string)$finalAttempt->state : 'finished',
        'total_slots'    => $finalTotal,
        'answered_slots' => $finalAnswered,
        'message'        => 'Jawaban darurat berhasil disimpan & dinilai di Moodle.',
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Gagal memproses kirim darurat di server.']);
}
