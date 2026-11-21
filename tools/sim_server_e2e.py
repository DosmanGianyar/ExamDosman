#!/usr/bin/env python3
"""
Simulasi Nyata End-to-End & Load Test Server Dosman Ujian (Lapisan 1)
---------------------------------------------------------------------
Menjalankan 15 skenario fungsional + 1 stress test paralel (300 request)
langsung ke endpoint HTTPS produksi menggunakan akun dummy terisolasi
(uid=2003 siswa & uid=2004 daput1) pada quiz simulasi (qid=209), lalu
membersihkan seluruh jejak tes 100% di blok `finally`.

Penggunaan (PowerShell / Bash):
  DOSMAN_SSH_PASS=... python tools/sim_server_e2e.py
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import getpass
import json
import os
import secrets
import shutil
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any


DUMMY_UID_1 = 2003
DUMMY_UID_2 = 2004
ADMIN_UID = 2
REVIEWER_UID = 3401
SIM_QUIZ_ID = 209
API_KEY = "dosman-exam-sman1gianyar-2024"


@dataclass
class HttpResult:
    status: int
    body: str
    elapsed_ms: float
    json_data: dict[str, Any] | None = None
    error: str | None = None


@dataclass
class TestState:
    start_ts: int
    admin_token: str = ""
    uid1_token: str = ""
    uid2_token: str = ""
    created_token_ids: list[int] = field(default_factory=list)
    created_attempt_ids: list[int] = field(default_factory=list)
    created_override_ids: list[int] = field(default_factory=list)
    saved_tokens_backup: list[dict[str, Any]] = field(default_factory=list)


class RemoteRunner:
    def __init__(self, host: str, user: str, password: str) -> None:
        self.host = host
        self.user = user
        self.password = password
        self.plink = shutil.which("plink")

    def run_bash(self, script: str) -> str:
        payload = base64.b64encode(script.replace("\r\n", "\n").encode("utf-8")).decode("ascii")
        remote_cmd = f"echo {payload} | base64 -d | bash"
        if self.plink and self.password:
            cmd = [self.plink, "-batch", "-pw", self.password, f"{self.user}@{self.host}", remote_cmd]
        else:
            cmd = ["ssh", "-o", "BatchMode=yes", f"{self.user}@{self.host}", remote_cmd]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            raise RuntimeError(f"Remote command failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
        return proc.stdout

    def run_php_json(self, php_body: str, args_obj: dict[str, Any] | None = None) -> dict[str, Any]:
        args_b64 = base64.b64encode(json.dumps(args_obj or {}).encode("utf-8")).decode("ascii")
        wrapper = f"""set -e
php << 'PHPEOF'
<?php
$ARGS = json_decode(base64_decode('{args_b64}'), true) ?: [];
$src = file_get_contents('/www/wwwroot/moodledosman.test/config.php');
$cfg = [];
foreach (['dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $k) {{
    if (preg_match('/\\$CFG->' . $k . '\\s*=\\s*[\\\'\\"]([^\\\'\\"]*)[\\\'\\"]/', $src, $m)) {{
        $cfg[$k] = $m[1];
    }}
}}
$p = $cfg['prefix'] ?? 'mdl_';
$pdo = new PDO(
    "mysql:host={{$cfg['dbhost']}};dbname={{$cfg['dbname']}};charset=utf8mb4",
    $cfg['dbuser'],
    $cfg['dbpass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
{php_body}
PHPEOF
"""
        out = self.run_bash(wrapper).strip()
        last_line = [ln for ln in out.splitlines() if ln.strip()][-1]
        return json.loads(last_line)


def http_json(
    base_url: str,
    endpoint: str,
    method: str = "POST",
    payload: dict[str, Any] | None = None,
    query: dict[str, Any] | None = None,
    timeout: float = 8.0,
) -> HttpResult:
    url = f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data_bytes = None
    headers = {"Accept": "application/json", "User-Agent": "DosmanExamSim/1.0"}
    if payload is not None:
        data_bytes = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data_bytes, headers=headers, method=method)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            elapsed = (time.perf_counter() - t0) * 1000.0
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = None
            return HttpResult(resp.status, raw, elapsed, parsed)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        elapsed = (time.perf_counter() - t0) * 1000.0
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = None
        return HttpResult(e.code, raw, elapsed, parsed)
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000.0
        return HttpResult(0, "", elapsed, None, str(e))


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def issue_temp_token(remote: RemoteRunner, state: TestState, userid: int, service_shortname: str) -> str:
    tok = "sim" + secrets.token_hex(14)
    res = remote.run_php_json(
        """
        $svcId = (int)$pdo->query("SELECT id FROM {$p}external_services WHERE shortname = " . $pdo->quote($ARGS['svc']) . " LIMIT 1")->fetchColumn();
        if ($svcId <= 0) throw new RuntimeException('service missing');
        $now = time();
        $stmt = $pdo->prepare(
            "INSERT INTO {$p}external_tokens
                (token, tokentype, userid, externalserviceid, contextid, creatorid, validuntil, timecreated, name)
             VALUES (?, 0, ?, ?, 1, 2, ?, ?, 'sim_server_e2e_temp')"
        );
        $stmt->execute([$ARGS['tok'], (int)$ARGS['uid'], $svcId, $now + 1800, $now]);
        echo json_encode(['id' => (int)$pdo->lastInsertId()]) . "\n";
        """,
        {"uid": userid, "svc": service_shortname, "tok": tok},
    )
    state.created_token_ids.append(int(res["id"]))
    return tok


def create_temp_attempt(remote: RemoteRunner, state: TestState, userid: int, timestart: int, quizid: int = SIM_QUIZ_ID) -> int:
    res = remote.run_php_json(
        """
        $maxUniq = (int)$pdo->query("SELECT COALESCE(MAX(uniqueid), 100000) FROM {$p}quiz_attempts")->fetchColumn();
        $maxAtt  = (int)$pdo->query("SELECT COALESCE(MAX(attempt), 0) FROM {$p}quiz_attempts WHERE quiz=" . (int)$ARGS['qid'] . " AND userid=" . (int)$ARGS['uid'])->fetchColumn();
        $stmt = $pdo->prepare(
            "INSERT INTO {$p}quiz_attempts
                (quiz, userid, attempt, uniqueid, layout, currentpage, preview, state, timestart, timefinish, timemodified, timemodifiedoffline, timecheckstate, sumgrades)
             VALUES (?, ?, ?, ?, '1,0', 0, 0, 'inprogress', ?, 0, ?, 0, NULL, NULL)"
        );
        $stmt->execute([(int)$ARGS['qid'], (int)$ARGS['uid'], max(9000, $maxAtt + 1), $maxUniq + random_int(500, 5000), (int)$ARGS['ts'], (int)$ARGS['ts']]);
        echo json_encode(['id' => (int)$pdo->lastInsertId()]) . "\n";
        """,
        {"uid": userid, "qid": quizid, "ts": timestart},
    )
    att_id = int(res["id"])
    state.created_attempt_ids.append(att_id)
    return att_id


def delete_attempt(remote: RemoteRunner, attempt_id: int) -> None:
    remote.run_php_json(
        """
        $pdo->prepare("DELETE FROM {$p}quiz_attempts WHERE id = ?")->execute([(int)$ARGS['id']]);
        echo json_encode(['ok' => true]) . "\n";
        """,
        {"id": attempt_id},
    )


def create_temp_override(
    remote: RemoteRunner, state: TestState, userid: int, timeclose: int | None, timelimit: int | None, quizid: int = SIM_QUIZ_ID
) -> int:
    res = remote.run_php_json(
        """
        $stmt = $pdo->prepare(
            "INSERT INTO {$p}quiz_overrides (quiz, userid, groupid, timeopen, timeclose, timelimit)
             VALUES (?, ?, NULL, NULL, ?, ?)"
        );
        $stmt->execute([(int)$ARGS['qid'], (int)$ARGS['uid'], $ARGS['close'], $ARGS['limit']]);
        echo json_encode(['id' => (int)$pdo->lastInsertId()]) . "\n";
        """,
        {"uid": userid, "qid": quizid, "close": timeclose, "limit": timelimit},
    )
    ov_id = int(res["id"])
    state.created_override_ids.append(ov_id)
    return ov_id


def delete_override(remote: RemoteRunner, ov_id: int) -> None:
    remote.run_php_json(
        """
        $pdo->prepare("DELETE FROM {$p}quiz_overrides WHERE id = ?")->execute([(int)$ARGS['id']]);
        echo json_encode(['ok' => true]) . "\n";
        """,
        {"id": ov_id},
    )


def inspect_uid(remote: RemoteRunner, userid: int, start_ts: int) -> dict[str, Any]:
    return remote.run_php_json(
        """
        $uid = (int)$ARGS['uid'];
        $ts  = (int)$ARGS['ts'];
        $u = $pdo->query("SELECT suspended FROM {$p}user WHERE id=$uid")->fetch(PDO::FETCH_ASSOC);
        $a = $pdo->query("SELECT lock_status, current_quizid, platform FROM {$p}local_dosman_ujian_appstatus WHERE userid=$uid")->fetch(PDO::FETCH_ASSOC);
        $devs = $pdo->query("SELECT device_id, status, block_reason FROM {$p}local_dosman_ujian_devices WHERE userid=$uid", PDO::FETCH_ASSOC)->fetchAll();
        $toks = (int)$pdo->query("SELECT COUNT(*) FROM {$p}external_tokens t JOIN {$p}external_services s ON s.id=t.externalserviceid WHERE t.userid=$uid AND s.shortname IN ('dosman_ujian_mobile','moodle_mobile_app')")->fetchColumn();
        $logs = $pdo->query("SELECT eventtype, quizid, COUNT(*) AS c FROM {$p}local_dosman_ujian_logs WHERE userid=$uid AND timecreated >= $ts GROUP BY eventtype, quizid", PDO::FETCH_ASSOC)->fetchAll();
        echo json_encode([
            'suspended' => (int)($u['suspended'] ?? -1),
            'appstatus' => $a ?: null,
            'devices' => $devs,
            'mobile_token_count' => $toks,
            'logs' => $logs,
        ]) . "\n";
        """,
        {"uid": userid, "ts": start_ts},
    )


def reset_dummy_state(remote: RemoteRunner, uid: int) -> None:
    remote.run_php_json(
        """
        $uid = (int)$ARGS['uid'];
        $pdo->prepare("UPDATE {$p}user SET suspended = 0 WHERE id = ?")->execute([$uid]);
        $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_appstatus WHERE userid = ?")->execute([$uid]);
        $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_devices WHERE userid = ?")->execute([$uid]);
        $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_sessions WHERE userid = ?")->execute([$uid]);
        @unlink('/dev/shm/dosman_app_users_cache.json');
        echo json_encode(['ok' => true]) . "\n";
        """,
        {"uid": uid},
    )


def setup_environment(remote: RemoteRunner, state: TestState) -> None:
    snap = remote.run_php_json(
        """
        $toks = $pdo->query("SELECT token, tokentype, userid, externalserviceid, sid, contextid, creatorid, iprestriction, validuntil, timecreated, lastaccess, name FROM {$p}external_tokens WHERE userid IN (2003, 2004)", PDO::FETCH_ASSOC)->fetchAll();
        echo json_encode(['now' => time(), 'tokens' => $toks]) . "\n";
        """
    )
    state.saved_tokens_backup = snap["tokens"]
    state.admin_token = issue_temp_token(remote, state, ADMIN_UID, "dosman_ujian_mobile")
    state.uid1_token = issue_temp_token(remote, state, DUMMY_UID_1, "dosman_ujian_mobile")
    state.uid2_token = issue_temp_token(remote, state, DUMMY_UID_2, "dosman_ujian_mobile")
    reset_dummy_state(remote, DUMMY_UID_1)
    reset_dummy_state(remote, DUMMY_UID_2)


def cleanup_environment(remote: RemoteRunner, state: TestState) -> dict[str, Any]:
    return remote.run_php_json(
        """
        foreach ($ARGS['attempt_ids'] as $id) {
            $pdo->prepare("DELETE FROM {$p}quiz_attempts WHERE id = ?")->execute([(int)$id]);
        }
        foreach ($ARGS['override_ids'] as $id) {
            $pdo->prepare("DELETE FROM {$p}quiz_overrides WHERE id = ?")->execute([(int)$id]);
        }
        foreach ($ARGS['token_ids'] as $id) {
            $pdo->prepare("DELETE FROM {$p}external_tokens WHERE id = ?")->execute([(int)$id]);
        }
        foreach ([2003, 2004] as $uid) {
            $pdo->prepare("UPDATE {$p}user SET suspended = 0 WHERE id = ?")->execute([$uid]);
            $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_devices WHERE userid = ?")->execute([$uid]);
            $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_appstatus WHERE userid = ?")->execute([$uid]);
            $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_sessions WHERE userid = ?")->execute([$uid]);
            $pdo->prepare("DELETE FROM {$p}local_dosman_ujian_logs WHERE userid = ? AND timecreated >= ?")->execute([$uid, (int)$ARGS['start_ts']]);
            $pdo->prepare("DELETE FROM {$p}sessions WHERE userid = ?")->execute([$uid]);
        }
        // Restore any pre-existing dummy tokens if deleted by suspend_student tests
        $insTok = $pdo->prepare(
            "INSERT IGNORE INTO {$p}external_tokens
                (token, tokentype, userid, externalserviceid, sid, contextid, creatorid, iprestriction, validuntil, timecreated, lastaccess, name)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        );
        foreach ($ARGS['saved_tokens'] as $t) {
            $exists = (int)$pdo->query("SELECT COUNT(*) FROM {$p}external_tokens WHERE token=" . $pdo->quote($t['token']))->fetchColumn();
            if ($exists === 0) {
                $insTok->execute([
                    $t['token'], $t['tokentype'], $t['userid'], $t['externalserviceid'],
                    $t['sid'], $t['contextid'], $t['creatorid'], $t['iprestriction'],
                    $t['validuntil'], $t['timecreated'], $t['lastaccess'], $t['name']
                ]);
            }
        }
        @unlink('/dev/shm/dosman_app_users_cache.json');

        $remDev  = (int)$pdo->query("SELECT COUNT(*) FROM {$p}local_dosman_ujian_devices WHERE userid IN (2003, 2004)")->fetchColumn();
        $remApp  = (int)$pdo->query("SELECT COUNT(*) FROM {$p}local_dosman_ujian_appstatus WHERE userid IN (2003, 2004)")->fetchColumn();
        $remSusp = (int)$pdo->query("SELECT COUNT(*) FROM {$p}user WHERE id IN (2003, 2004) AND suspended = 1")->fetchColumn();
        $remQid  = (int)$pdo->query("SELECT COUNT(*) FROM {$p}local_dosman_ujian_appstatus WHERE current_quizid > 0")->fetchColumn();
        $adminSusp = (int)$pdo->query("SELECT suspended FROM {$p}user WHERE id = 2")->fetchColumn();
        $revSusp   = (int)$pdo->query("SELECT suspended FROM {$p}user WHERE id = 3401")->fetchColumn();
        echo json_encode([
            'rem_dev' => $remDev,
            'rem_app' => $remApp,
            'rem_susp' => $remSusp,
            'rem_qid' => $remQid,
            'admin_susp' => $adminSusp,
            'rev_susp' => $revSusp,
        ]) . "\n";
        """,
        {
            "attempt_ids": state.created_attempt_ids,
            "override_ids": state.created_override_ids,
            "token_ids": state.created_token_ids,
            "start_ts": state.start_ts,
            "saved_tokens": state.saved_tokens_backup,
        },
    )


def run_all_tests(args: argparse.Namespace) -> int:
    ssh_pass = args.ssh_pass or os.environ.get("DOSMAN_SSH_PASS", "")
    if not ssh_pass and sys.stdin.isatty():
        ssh_pass = getpass.getpass(f"SSH password for {args.ssh_user}@{args.ssh_host}: ")
    if not ssh_pass:
        print("ERROR: SSH password wajib diisi via DOSMAN_SSH_PASS atau --ssh-pass", file=sys.stderr)
        return 2

    remote = RemoteRunner(args.ssh_host, args.ssh_user, ssh_pass)
    server_now = int(remote.run_bash("date +%s").strip())
    state = TestState(start_ts=server_now - 2)
    base_url = args.base_url
    results: list[tuple[str, bool, str]] = []

    def record(name: str, fn) -> None:
        t0 = time.perf_counter()
        try:
            detail = fn() or "OK"
            dt = (time.perf_counter() - t0) * 1000.0
            print(f"[PASS] {name} ({dt:.0f} ms) - {detail}")
            results.append((name, True, detail))
        except Exception as exc:
            dt = (time.perf_counter() - t0) * 1000.0
            print(f"[FAIL] {name} ({dt:.0f} ms) - {exc}")
            results.append((name, False, str(exc)))

    try:
        setup_environment(remote, state)
        print(f"=== Lapisan 1: Simulasi Nyata HTTPS ke {base_url} (dummy uid={DUMMY_UID_1},{DUMMY_UID_2}) ===")

        # T01: app_ping di luar ujian abaikan quizid usang
        def t01() -> str:
            r = http_json(base_url, "app_ping.php", "POST", {
                "token": state.uid1_token,
                "platform": "android",
                "quizid": 221,
            })
            assert_true(r.status == 200 and r.json_data and r.json_data.get("success") is True, f"bad resp: {r.status} {r.body}")
            assert_true(r.json_data.get("lock_status") == 1, f"expected lock_status=1 got {r.json_data}")
            st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
            assert_true(st["appstatus"] is not None and int(st["appstatus"]["current_quizid"]) == 0, f"expected current_quizid=0 got {st['appstatus']}")
            return "app_ping syncs current_quizid=0 despite stale quizid=221"

        # T02: suspend_student di luar jam ujian diabaikan
        def t02() -> str:
            r = http_json(base_url, "suspend_student.php", "POST", {
                "apikey": API_KEY,
                "userid": DUMMY_UID_1,
                "reason": "Siswa memaksa melepas pinned screen (alarm aktif)",
            })
            assert_true(r.status == 200 and r.json_data and r.json_data.get("ignored") is True and r.json_data.get("success") is False, f"expected ignored got {r.body}")
            st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
            assert_true(st["suspended"] == 0, f"expected suspended=0 got {st['suspended']}")
            return "pre-quiz suspend safely ignored"

        # T03: block_device di luar jam ujian diabaikan
        def t03() -> str:
            r = http_json(base_url, "block_device.php", "POST", {
                "token": state.uid1_token,
                "device_id": "aid_1122334455667788",
                "reason": "Keluar aplikasi saat ujian aktif",
            })
            assert_true(r.status == 200 and r.json_data and r.json_data.get("ignored") is True and r.json_data.get("success") is False, f"expected ignored got {r.body}")
            st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
            assert_true(len(st["devices"]) == 0, f"expected no blocked device got {st['devices']}")
            return "pre-quiz block_device safely ignored"

        # T04: Attempt unbounded > 3 jam terbengkalai diabaikan
        def t04() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 14400)
            try:
                rp = http_json(base_url, "app_ping.php", "POST", {"token": state.uid1_token, "platform": "android", "quizid": SIM_QUIZ_ID})
                assert_true(rp.status == 200 and rp.json_data and rp.json_data.get("success") is True, f"app_ping failed: {rp.body}")
                st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
                assert_true(int(st["appstatus"]["current_quizid"]) == 0, f"stale attempt leaked current_quizid={st['appstatus']}")

                rs = http_json(base_url, "suspend_student.php", "POST", {
                    "apikey": API_KEY,
                    "userid": DUMMY_UID_1,
                    "reason": "Pelanggaran keamanan ujian: bluetooth_audio",
                })
                assert_true(rs.status == 200 and rs.json_data and rs.json_data.get("ignored") is True, f"stale attempt caused suspend: {rs.body}")
                return "unbounded attempt >3h treated as abandoned (current_quizid=0, ignored=true)"
            finally:
                delete_attempt(remote, att_id)

        # T05: Attempt aktif valid disinkronkan app_ping
        def t05() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 60)
            try:
                rp = http_json(base_url, "app_ping.php", "POST", {"token": state.uid1_token, "platform": "android"})
                assert_true(rp.status == 200 and rp.json_data and rp.json_data.get("success") is True, f"ping failed: {rp.body}")
                st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
                assert_true(int(st["appstatus"]["current_quizid"]) == SIM_QUIZ_ID, f"expected current_quizid={SIM_QUIZ_ID} got {st['appstatus']}")
                return f"active attempt synced current_quizid={SIM_QUIZ_ID}"
            finally:
                delete_attempt(remote, att_id)

        # T06: Legacy overlay/screen_cast/mirroring saat ujian aktif tetap diabaikan
        def t06() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 60)
            try:
                for reason in [
                    "Pelanggaran keamanan ujian: overlay detected",
                    "Pelanggaran keamanan ujian: screen_cast",
                    "Screen Mirroring aktif",
                ]:
                    rs = http_json(base_url, "suspend_student.php", "POST", {"apikey": API_KEY, "userid": DUMMY_UID_1, "reason": reason})
                    assert_true(rs.status == 200 and rs.json_data and rs.json_data.get("ignored") is True, f"legacy reason not ignored ({reason}): {rs.body}")
                    rb = http_json(base_url, "block_device.php", "POST", {"token": state.uid1_token, "device_id": "aid_1122334455667788", "reason": reason})
                    assert_true(rb.status == 200 and rb.json_data and rb.json_data.get("ignored") is True, f"legacy block_device not ignored ({reason}): {rb.body}")
                return "all 3 legacy rules ignored across both endpoints"
            finally:
                delete_attempt(remote, att_id)

        # T07: Override kedaluwarsa ditolak
        def t07() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 4000)
            ov_id = create_temp_override(remote, state, DUMMY_UID_1, now_s - 600, 3600)
            try:
                rs = http_json(base_url, "suspend_student.php", "POST", {
                    "apikey": API_KEY,
                    "userid": DUMMY_UID_1,
                    "reason": "Pelanggaran keamanan ujian: split_screen",
                })
                assert_true(rs.status == 200 and rs.json_data and rs.json_data.get("ignored") is True, f"expired override triggered suspend: {rs.body}")
                return "expired user override safely ignored"
            finally:
                delete_override(remote, ov_id)
                delete_attempt(remote, att_id)

        # T08: Override susulan diperpanjang terdeteksi aktif
        def t08() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 60)
            ov_id = create_temp_override(remote, state, DUMMY_UID_1, now_s + 3600, 3600)
            try:
                rp = http_json(base_url, "app_ping.php", "POST", {"token": state.uid1_token, "platform": "android"})
                assert_true(rp.status == 200 and rp.json_data and rp.json_data.get("success") is True, f"ping err: {rp.body}")
                st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
                assert_true(int(st["appstatus"]["current_quizid"]) == SIM_QUIZ_ID, f"override active not detected: {st['appstatus']}")
                return f"susulan override detected current_quizid={SIM_QUIZ_ID}"
            finally:
                delete_override(remote, ov_id)
                delete_attempt(remote, att_id)

        # T09: Burst 10x suspend_student paralel bersamaan -> atomic dedup 1 log
        def t09() -> str:
            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 60)
            try:
                def fire(_idx: int) -> HttpResult:
                    return http_json(base_url, "suspend_student.php", "POST", {
                        "apikey": API_KEY,
                        "userid": DUMMY_UID_1,
                        "reason": "Pelanggaran keamanan ujian: bluetooth_audio",
                    })

                with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
                    resps = list(pool.map(fire, range(10)))

                bad = [r for r in resps if r.status != 200 or not r.json_data or r.json_data.get("success") is not True]
                assert_true(len(bad) == 0, f"burst had errors/failures: {[(b.status, b.body) for b in bad]}")
                st = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
                assert_true(st["suspended"] == 1, "expected user suspended=1")
                assert_true(st["mobile_token_count"] == 0, f"tokens not deleted: {st['mobile_token_count']}")
                susp_logs = [x for x in st["logs"] if x["eventtype"] == "account_suspended"]
                assert_true(len(susp_logs) == 1 and int(susp_logs[0]["c"]) == 1, f"expected exact 1 account_suspended log, got {susp_logs}")
                assert_true(int(susp_logs[0]["quizid"]) == SIM_QUIZ_ID, f"expected log quizid={SIM_QUIZ_ID}, got {susp_logs}")

                cb = http_json(base_url, "check_blocked.php", "GET", query={"userid": DUMMY_UID_1})
                assert_true(cb.status == 200 and cb.json_data and cb.json_data.get("blocked") is True, f"check_blocked wrong: {cb.body}")

                ap = http_json(base_url, "app_ping.php", "POST", {"token": state.uid1_token, "platform": "android"})
                assert_true(ap.status == 401 and ap.json_data and ap.json_data.get("suspended") is True, f"old token still worked: {ap.status} {ap.body}")
                return "10x parallel burst -> 10x HTTP 200, 1 log, 0 tokens left, old token rejected 401"
            finally:
                delete_attempt(remote, att_id)

        # T10: unsuspend_student memulihkan akun
        def t10() -> str:
            r = http_json(base_url, "unsuspend_student.php", "POST", {
                "token": state.admin_token,
                "userid": DUMMY_UID_1,
            })
            assert_true(r.status == 200 and r.json_data and r.json_data.get("success") is True, f"unsuspend failed: {r.body}")
            cb = http_json(base_url, "check_blocked.php", "GET", query={"userid": DUMMY_UID_1})
            assert_true(cb.status == 200 and cb.json_data and cb.json_data.get("blocked") is False, f"still blocked: {cb.body}")
            state.uid1_token = issue_temp_token(remote, state, DUMMY_UID_1, "dosman_ujian_mobile")
            return "unsuspend restored account & check_blocked=false"

        # T11: Isolasi Build.ID Android lintas siswa
        def t11() -> str:
            shared_build = "UP1A.231005.007"
            r1 = http_json(base_url, "register_device.php", "POST", {
                "token": state.uid1_token, "device_id": shared_build, "platform": "android", "model": "TestPhone",
                "app_version": "2.8.1", "app_build": 153,
            })
            r2 = http_json(base_url, "register_device.php", "POST", {
                "token": state.uid2_token, "device_id": shared_build, "platform": "android", "model": "TestPhone",
                "app_version": "2.8.1", "app_build": 153,
            })
            assert_true(r1.status == 200 and r1.json_data and r1.json_data.get("device_blocked") is False, f"r1 bad: {r1.body}")
            assert_true(r2.status == 200 and r2.json_data and r2.json_data.get("device_blocked") is False, f"r2 bad: {r2.body}")

            now_s = int(remote.run_bash("date +%s").strip())
            att_id = create_temp_attempt(remote, state, DUMMY_UID_1, now_s - 60)
            try:
                rb = http_json(base_url, "block_device.php", "POST", {
                    "token": state.uid1_token,
                    "device_id": shared_build,
                    "reason": "Keluar aplikasi saat ujian aktif",
                })
                assert_true(rb.status == 200 and rb.json_data and rb.json_data.get("success") is True, f"block_device failed: {rb.body}")

                cd_raw = http_json(base_url, "check_device.php", "POST", {"device_id": shared_build})
                assert_true(cd_raw.status == 200 and cd_raw.json_data and cd_raw.json_data.get("blocked") is False, f"shared Build.ID leaked block: {cd_raw.body}")

                r2_after = http_json(base_url, "register_device.php", "POST", {
                    "token": state.uid2_token, "device_id": shared_build, "platform": "android", "model": "TestPhone",
                })
                assert_true(r2_after.status == 200 and r2_after.json_data and r2_after.json_data.get("device_blocked") is False, f"uid2 affected: {r2_after.body}")

                ru = http_json(base_url, "unblock_device.php", "POST", {
                    "token": state.admin_token,
                    "device_id": f"u{DUMMY_UID_1}__{shared_build}",
                })
                assert_true(ru.status == 200 and ru.json_data and ru.json_data.get("success") is True, f"unblock_device failed: {ru.body}")

                cb = http_json(base_url, "check_blocked.php", "GET", query={"userid": DUMMY_UID_1})
                assert_true(cb.status == 200 and cb.json_data and cb.json_data.get("blocked") is False, f"uid1 still blocked: {cb.body}")
                return "shared Build.ID scoped u2003__/u2004__ cleanly; zero cross-student impact"
            finally:
                delete_attempt(remote, att_id)

        # T12: Proteksi admin (uid=2) dan reviewer (uid=3401) sebelum tulis appstatus
        def t12() -> str:
            for target_uid, label in [(ADMIN_UID, "admin"), (REVIEWER_UID, "reviewer")]:
                before = inspect_uid(remote, target_uid, state.start_ts)
                rs = http_json(base_url, "suspend_student.php", "POST", {
                    "apikey": API_KEY, "userid": target_uid, "reason": "Simulasi uji proteksi",
                })
                assert_true(rs.status == 200 and rs.json_data and rs.json_data.get("success") is False, f"{label} suspend not rejected: {rs.body}")

                rl = http_json(base_url, "set_lock_status.php", "POST", {
                    "token": state.admin_token, "userid": target_uid, "lock_status": 2,
                })
                assert_true(rl.status == 200 and rl.json_data and rl.json_data.get("success") is False, f"{label} set_lock_status(2) not rejected: {rl.body}")

                after = inspect_uid(remote, target_uid, state.start_ts)
                assert_true(after["suspended"] == 0, f"{label} was suspended!")
                assert_true(after["appstatus"] == before["appstatus"], f"{label} appstatus mutated from {before['appstatus']} to {after['appstatus']}")
            return "admin & reviewer protected from suspend_student & set_lock_status(2) with zero DB mutation"

        # T13: set_lock_status(2) -> set_lock_status(1) full cycle on uid=2003
        def t13() -> str:
            r_blk = http_json(base_url, "set_lock_status.php", "POST", {
                "token": state.admin_token, "userid": DUMMY_UID_1, "lock_status": 2,
            })
            assert_true(r_blk.status == 200 and r_blk.json_data and r_blk.json_data.get("success") is True, f"lock=2 failed: {r_blk.body}")
            st_blk = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
            assert_true(st_blk["suspended"] == 1 and int(st_blk["appstatus"]["lock_status"]) == 2, f"bad blk state: {st_blk}")
            cb_blk = http_json(base_url, "check_blocked.php", "GET", query={"userid": DUMMY_UID_1})
            assert_true(cb_blk.json_data and cb_blk.json_data.get("blocked") is True, f"check_blocked expected true: {cb_blk.body}")

            r_un = http_json(base_url, "set_lock_status.php", "POST", {
                "token": state.admin_token, "userid": DUMMY_UID_1, "lock_status": 1,
            })
            assert_true(r_un.status == 200 and r_un.json_data and r_un.json_data.get("success") is True, f"lock=1 failed: {r_un.body}")
            st_un = inspect_uid(remote, DUMMY_UID_1, state.start_ts)
            assert_true(st_un["suspended"] == 0 and int(st_un["appstatus"]["lock_status"]) == 1, f"bad unblk state: {st_un}")
            cb_un = http_json(base_url, "check_blocked.php", "GET", query={"userid": DUMMY_UID_1})
            assert_true(cb_un.json_data and cb_un.json_data.get("blocked") is False, f"check_blocked expected false: {cb_un.body}")
            state.uid1_token = issue_temp_token(remote, state, DUMMY_UID_1, "dosman_ujian_mobile")
            return "set_lock_status 2 -> 1 symmetric suspend/unsuspend verified"

        # T14: verify_unblock_token tolak Build.ID anonim
        def t14() -> str:
            r = http_json(base_url, "verify_unblock_token.php", "POST", {
                "device_id": "UP1A.231005.007",
                "code": "123456",
            })
            assert_true(r.status == 200 and r.json_data and r.json_data.get("success") is False, f"anonymous Build.ID should be rejected: {r.body}")
            return "shared Build.ID rejected by verify_unblock_token"

        # T15: exitpwd reviewer vs regular
        def t15() -> str:
            r_rev = http_json(base_url, "exitpwd.php", "GET", query={"apikey": API_KEY, "username": "appstore.review"})
            assert_true(r_rev.status == 200 and r_rev.json_data and r_rev.json_data.get("password") == "123456", f"reviewer exitpwd wrong: {r_rev.body}")
            r_stu = http_json(base_url, "exitpwd.php", "GET", query={"apikey": API_KEY, "username": "siswa"})
            assert_true(r_stu.status == 200 and r_stu.json_data and "password" in r_stu.json_data, f"student exitpwd wrong: {r_stu.body}")
            return "exitpwd returned 123456 for reviewer and valid password field for student"

        # T16: Real Concurrent Load Test (N requests, M concurrent workers)
        def t16() -> str:
            total = args.load_requests
            conc = args.load_concurrency
            jobs: list[tuple[str, str, dict[str, Any] | None, dict[str, Any] | None]] = []
            for i in range(total):
                mod = i % 6
                if mod in (0, 1):
                    tok = state.uid1_token if mod == 0 else state.uid2_token
                    jobs.append(("app_ping.php", "POST", {"token": tok, "platform": "android"}, None))
                elif mod in (2, 3):
                    uid = DUMMY_UID_1 if mod == 2 else DUMMY_UID_2
                    jobs.append(("check_blocked.php", "GET", None, {"userid": uid}))
                elif mod == 4:
                    jobs.append(("check_device.php", "POST", {"device_id": "aid_0123456789abcdef"}, None))
                else:
                    jobs.append(("get_app_users.php", "GET", None, {"apikey": API_KEY}))

            def run_job(job: tuple[str, str, dict[str, Any] | None, dict[str, Any] | None]) -> HttpResult:
                ep, m, pl, q = job
                return http_json(base_url, ep, m, payload=pl, query=q, timeout=15.0)

            t0 = time.perf_counter()
            with concurrent.futures.ThreadPoolExecutor(max_workers=conc) as pool:
                resps = list(pool.map(run_job, jobs))
            wall_s = time.perf_counter() - t0

            errs = [r for r in resps if r.status != 200 or r.error is not None]
            lats = sorted(r.elapsed_ms for r in resps)
            p50 = statistics.median(lats)
            p95 = lats[min(len(lats) - 1, int(len(lats) * 0.95))]
            p99 = lats[min(len(lats) - 1, int(len(lats) * 0.99))]
            max_ms = lats[-1]
            rps = len(resps) / wall_s if wall_s > 0 else 0.0

            srv_stats = remote.run_bash("echo \"procs=$(pgrep -c php-fpm || echo 0) load=$(cat /proc/loadavg | cut -d' ' -f1-3)\"; tail -n 5 /www/server/php/83/var/log/php-fpm.log 2>/dev/null || true").strip()
            assert_true(len(errs) == 0, f"{len(errs)}/{total} errors (first 3: {[(e.status, e.error, e.body[:120]) for e in errs[:3]]})")
            return (
                f"{total} req @ {conc} workers in {wall_s:.2f}s ({rps:.1f} req/s), "
                f"lat P50={p50:.0f}ms P95={p95:.0f}ms P99={p99:.0f}ms max={max_ms:.0f}ms, 0 errors; "
                f"server=[{srv_stats.replace(chr(10), ' | ')}]"
            )

        for name, fn in [
            ("T01 app_ping ignores stale client quizid", t01),
            ("T02 suspend_student pre-quiz ignored", t02),
            ("T03 block_device pre-quiz ignored", t03),
            ("T04 abandoned >3h attempt ignored", t04),
            ("T05 active attempt synced cleanly", t05),
            ("T06 legacy overlay/screen_cast/mirroring ignored", t06),
            ("T07 expired quiz_override ignored", t07),
            ("T08 extended susulan override active", t08),
            ("T09 10x parallel suspend_student dedup", t09),
            ("T10 unsuspend_student restores access", t10),
            ("T11 shared Android Build.ID isolation", t11),
            ("T12 admin & reviewer DB immutability", t12),
            ("T13 set_lock_status 2 -> 1 symmetric cycle", t13),
            ("T14 verify_unblock_token rejects anonymous Build.ID", t14),
            ("T15 exitpwd reviewer & student response", t15),
            (f"T16 concurrent load burst ({args.load_requests} req / {args.load_concurrency} workers)", t16),
        ]:
            record(name, fn)

    finally:
        cleanup_res = cleanup_environment(remote, state)
        print(f"=== CLEANUP VERIFICATION: {json.dumps(cleanup_res)} ===")

    failed = [r for r in results if not r[1]]
    cleanup_ok = (
        cleanup_res["rem_dev"] == 0
        and cleanup_res["rem_app"] == 0
        and cleanup_res["rem_susp"] == 0
        and cleanup_res["rem_qid"] == 0
        and cleanup_res["admin_susp"] == 0
        and cleanup_res["rev_susp"] == 0
    )
    print(f"=== SUMMARY: {len(results) - len(failed)}/{len(results)} PASSED, cleanup_clean={cleanup_ok} ===")
    return 0 if (not failed and cleanup_ok) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Real HTTPS E2E & load test for Dosman Ujian server")
    parser.add_argument("--ssh-host", default="100.119.100.104")
    parser.add_argument("--ssh-user", default="dosman")
    parser.add_argument("--ssh-pass", default="")
    parser.add_argument("--base-url", default="https://lms.sman1-gianyar.sch.id:9443/local/dosman_ujian")
    parser.add_argument("--load-requests", type=int, default=300)
    parser.add_argument("--load-concurrency", type=int, default=100)
    args = parser.parse_args()
    return run_all_tests(args)


if __name__ == "__main__":
    sys.exit(main())
