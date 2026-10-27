<?php
/**
 * Endpoint: cek apakah username sedang disuspend.
 * Dipakai oleh halaman login untuk menampilkan notifikasi SweetAlert2 yang lebih jelas.
 *
 * Query param:
 *   - username (string)
 *
 * Response:
 *   { "success": true, "suspended": bool }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

define('NO_MOODLE_COOKIES', true);
require_once(__DIR__ . '/../../config.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

$username = optional_param('username', '', PARAM_USERNAME);
if ($username === '' || in_array(core_text::strtolower($username), ['appstore.review', 'playstore.review'], true)) {
    echo json_encode(['success' => true, 'suspended' => false]);
    exit;
}

$user = $DB->get_record(
    'user',
    ['username' => core_text::strtolower($username), 'deleted' => 0],
    'id,suspended',
    IGNORE_MISSING
);

if (!$user) {
    echo json_encode(['success' => true, 'suspended' => false]);
    exit;
}

echo json_encode([
    'success' => true,
    'suspended' => ((int)$user->suspended === 1),
]);

