<?php
/**
 * Upgrade script for local_dosman_ujian
 *
 * @package    local_dosman_ujian
 * @copyright  2024 Dosman Ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

function xmldb_local_dosman_ujian_upgrade($oldversion) {
    global $DB;
    $dbman = $DB->get_manager();

    if ($oldversion < 2024120200) {
        // Buat tabel sesi lockdown
        $table = new xmldb_table('local_dosman_ujian_sessions');

        $table->add_field('id',               XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, XMLDB_SEQUENCE);
        $table->add_field('userid',           XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('quizid',           XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('courseid',         XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('status',           XMLDB_TYPE_CHAR,    '20',  null, XMLDB_NOTNULL, null, 'active');
        $table->add_field('last_heartbeat',   XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('blocked_reason',   XMLDB_TYPE_CHAR,    '255', null, null,          null);
        $table->add_field('blocked_at',       XMLDB_TYPE_INTEGER, '10',  null, null,          null);
        $table->add_field('pause_granted_at', XMLDB_TYPE_INTEGER, '10',  null, null,          null);
        $table->add_field('reset_count',      XMLDB_TYPE_INTEGER, '5',   null, XMLDB_NOTNULL, null, '0');
        $table->add_field('timecreated',      XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('timemodified',     XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);

        $table->add_key('primary', XMLDB_KEY_PRIMARY, ['id']);
        $table->add_index('idx_userid_quizid',   XMLDB_INDEX_NOTUNIQUE, ['userid', 'quizid']);
        $table->add_index('idx_status',          XMLDB_INDEX_NOTUNIQUE, ['status']);
        $table->add_index('idx_last_heartbeat',  XMLDB_INDEX_NOTUNIQUE, ['last_heartbeat']);

        if (!$dbman->table_exists($table)) {
            $dbman->create_table($table);
        }

        upgrade_plugin_savepoint(true, 2024120200, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2024120300) {
        $table = new xmldb_table('local_dosman_ujian_sessions');

        $field = new xmldb_field('exit_request', XMLDB_TYPE_CHAR, '20', null, XMLDB_NOTNULL, null, 'none');
        if (!$dbman->field_exists($table, $field)) {
            $dbman->add_field($table, $field);
        }

        $field = new xmldb_field('exit_requested_at', XMLDB_TYPE_INTEGER, '10', null, null, null);
        if (!$dbman->field_exists($table, $field)) {
            $dbman->add_field($table, $field);
        }

        $field = new xmldb_field('exit_processed_at', XMLDB_TYPE_INTEGER, '10', null, null, null);
        if (!$dbman->field_exists($table, $field)) {
            $dbman->add_field($table, $field);
        }

        upgrade_plugin_savepoint(true, 2024120300, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026042202) {
        $table = new xmldb_table('local_dosman_ujian_sessions');
        $field = new xmldb_field('useragent', XMLDB_TYPE_CHAR, '512', null, null, null, null);
        if (!$dbman->field_exists($table, $field)) {
            $dbman->add_field($table, $field);
        }
        upgrade_plugin_savepoint(true, 2026042202, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026042200) {
        // Tabel untuk melacak status app siswa (aktif/keluar) secara real-time
        $table = new xmldb_table('local_dosman_ujian_appstatus');

        $table->add_field('id',        XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, XMLDB_SEQUENCE);
        $table->add_field('userid',    XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('lastping',  XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
        $table->add_field('ipaddress', XMLDB_TYPE_CHAR,    '45',  null, null,          null, '');

        $table->add_key('primary', XMLDB_KEY_PRIMARY, ['id']);
        $table->add_index('idx_userid',   XMLDB_INDEX_UNIQUE,    ['userid']);
        $table->add_index('idx_lastping', XMLDB_INDEX_NOTUNIQUE, ['lastping']);

        if (!$dbman->table_exists($table)) {
            $dbman->create_table($table);
        }

        upgrade_plugin_savepoint(true, 2026042201, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026042402) {
        $table = new xmldb_table('local_dosman_ujian_appstatus');
        if ($dbman->table_exists($table)) {
            $field = new xmldb_field('lock_status', XMLDB_TYPE_INTEGER, '1', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($table, $field)) {
                $dbman->add_field($table, $field);
            }
            $index = new xmldb_index('idx_lock_status', XMLDB_INDEX_NOTUNIQUE, ['lock_status']);
            if (!$dbman->index_exists($table, $index)) {
                $dbman->add_index($table, $index);
            }
        }
        upgrade_plugin_savepoint(true, 2026042402, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026042403) {
        // Kolom untuk melacak quizid yang sedang aktif dikerjakan siswa
        $table = new xmldb_table('local_dosman_ujian_appstatus');
        if ($dbman->table_exists($table)) {
            $field = new xmldb_field('current_quizid', XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($table, $field)) {
                $dbman->add_field($table, $field);
            }
        }
        upgrade_plugin_savepoint(true, 2026042403, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026042600) {
        // Perbaikan: pastikan tabel appstatus dan semua kolomnya ada,
        // terlepas dari urutan upgrade sebelumnya yang mungkin tidak konsisten.
        $table = new xmldb_table('local_dosman_ujian_appstatus');
        if (!$dbman->table_exists($table)) {
            $table->add_field('id',             XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, XMLDB_SEQUENCE);
            $table->add_field('userid',         XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null);
            $table->add_field('lastping',       XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null);
            $table->add_field('ipaddress',      XMLDB_TYPE_CHAR,    '45', null, null,          null, '');
            $table->add_field('lock_status',    XMLDB_TYPE_INTEGER, '1',  null, XMLDB_NOTNULL, null, '0');
            $table->add_field('current_quizid', XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null, '0');
            $table->add_key('primary', XMLDB_KEY_PRIMARY, ['id']);
            $table->add_index('idx_userid',      XMLDB_INDEX_UNIQUE,    ['userid']);
            $table->add_index('idx_lastping',    XMLDB_INDEX_NOTUNIQUE, ['lastping']);
            $table->add_index('idx_lock_status', XMLDB_INDEX_NOTUNIQUE, ['lock_status']);
            $dbman->create_table($table);
        } else {
            // Tabel ada — pastikan setiap kolom yang diperlukan ada
            $field = new xmldb_field('lock_status', XMLDB_TYPE_INTEGER, '1', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($table, $field)) {
                $dbman->add_field($table, $field);
            }
            $field = new xmldb_field('current_quizid', XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($table, $field)) {
                $dbman->add_field($table, $field);
            }
        }
        upgrade_plugin_savepoint(true, 2026042600, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026050100) {
        $table = new xmldb_table('local_dosman_ujian_devices');
        if (!$dbman->table_exists($table)) {
            $table->add_field('id',           XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, XMLDB_SEQUENCE);
            $table->add_field('device_id',    XMLDB_TYPE_CHAR,    '128', null, XMLDB_NOTNULL, null);
            $table->add_field('userid',       XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
            $table->add_field('platform',     XMLDB_TYPE_CHAR,    '10',  null, XMLDB_NOTNULL, null, 'android');
            $table->add_field('model',        XMLDB_TYPE_CHAR,    '100', null, null,          null);
            $table->add_field('status',       XMLDB_TYPE_CHAR,    '20',  null, XMLDB_NOTNULL, null, 'active');
            $table->add_field('block_reason', XMLDB_TYPE_CHAR,    '255', null, null,          null);
            $table->add_field('blocked_at',   XMLDB_TYPE_INTEGER, '10',  null, null,          null);
            $table->add_field('registered_at',XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
            $table->add_field('last_seen',    XMLDB_TYPE_INTEGER, '10',  null, XMLDB_NOTNULL, null);
            $table->add_key('primary', XMLDB_KEY_PRIMARY, ['id']);
            $table->add_index('idx_device_id', XMLDB_INDEX_UNIQUE,    ['device_id']);
            $table->add_index('idx_userid',    XMLDB_INDEX_NOTUNIQUE, ['userid']);
            $table->add_index('idx_status',    XMLDB_INDEX_NOTUNIQUE, ['status']);
            $dbman->create_table($table);
        }
        upgrade_plugin_savepoint(true, 2026050100, 'local', 'dosman_ujian');
    }

    if ($oldversion < 2026050200) {
        $devicesTable = new xmldb_table('local_dosman_ujian_devices');
        if ($dbman->table_exists($devicesTable)) {
            $field = new xmldb_field('app_version', XMLDB_TYPE_CHAR, '32', null, null, null, null);
            if (!$dbman->field_exists($devicesTable, $field)) {
                $dbman->add_field($devicesTable, $field);
            }
            $field = new xmldb_field('app_build', XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($devicesTable, $field)) {
                $dbman->add_field($devicesTable, $field);
            }
        }

        $appstatusTable = new xmldb_table('local_dosman_ujian_appstatus');
        if ($dbman->table_exists($appstatusTable)) {
            $field = new xmldb_field('platform', XMLDB_TYPE_CHAR, '20', null, null, null, '');
            if (!$dbman->field_exists($appstatusTable, $field)) {
                $dbman->add_field($appstatusTable, $field);
            }
            $field = new xmldb_field('app_version', XMLDB_TYPE_CHAR, '32', null, null, null, null);
            if (!$dbman->field_exists($appstatusTable, $field)) {
                $dbman->add_field($appstatusTable, $field);
            }
            $field = new xmldb_field('app_build', XMLDB_TYPE_INTEGER, '10', null, XMLDB_NOTNULL, null, '0');
            if (!$dbman->field_exists($appstatusTable, $field)) {
                $dbman->add_field($appstatusTable, $field);
            }
        }

        upgrade_plugin_savepoint(true, 2026050200, 'local', 'dosman_ujian');
    }

    return true;
}
