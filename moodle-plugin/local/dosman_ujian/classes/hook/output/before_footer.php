<?php
/**
 * Hook callback: inject JavaScript heartbeat ke halaman kuis.
 * Menggantikan local_dosman_ujian_before_footer() yang deprecated di Moodle 4.4+.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\hook\output;

class before_footer {

    public static function callback(\core\hook\output\before_footer_html_generation $hook): void {
        global $CFG, $USER, $DB;

        $ua          = $_SERVER['HTTP_USER_AGENT'] ?? '';
        $isDosmanApp = (strpos($ua, 'ExamDosmanAndroid') !== false) || (strpos($ua, 'ExamDosmanIOS') !== false);
        $isAndroid   = $isDosmanApp;
        $isSEB       = !$isDosmanApp && (
            strpos($ua, 'SEB') !== false ||
            strpos($ua, 'SafeExamBrowser') !== false
        );

        if (!$isDosmanApp && !$isSEB) return;

        // ── SEB (iOS): Floating Back Button ───────────────────────────────────
        // Tombol "Kembali" memanggil history.back() di dalam SEB — tidak bisa
        // keluar SEB (itu memerlukan quit password yang sudah dikonfigurasi).
        // Tampil di semua halaman Moodle agar siswa yang tersesat bisa kembali.
        if ($isSEB) {
            $hook->add_html(
                '<style>' .
                '#dosmanBackBtn{' .
                    'position:fixed;bottom:24px;left:20px;z-index:999999;' .
                    'background:rgba(37,99,235,.92);color:#fff;border:none;' .
                    'border-radius:50px;padding:14px 24px;' .
                    'font-family:-apple-system,BlinkMacSystemFont,sans-serif;' .
                    'font-size:17px;font-weight:700;cursor:pointer;' .
                    'box-shadow:0 4px 20px rgba(0,0,0,.35);' .
                    '-webkit-tap-highlight-color:transparent;touch-action:manipulation;' .
                    'display:flex;align-items:center;gap:8px;' .
                '}' .
                '#dosmanBackBtn:active{background:rgba(29,78,216,.98);transform:scale(.95)}' .
                '</style>' .
                '<button id="dosmanBackBtn" onclick="history.back()">' .
                    '&#x2190; Kembali' .
                '</button>' .
                '<script>(function(){' .
                    // Sembunyikan tombol jika tidak ada halaman sebelumnya
                    'function syncBtn(){' .
                        'var b=document.getElementById("dosmanBackBtn");' .
                        'if(!b)return;' .
                        'b.style.display=window.history.length<=1?"none":"flex";' .
                    '}' .
                    'if(document.readyState==="loading"){' .
                        'document.addEventListener("DOMContentLoaded",syncBtn);' .
                    '}else{syncBtn();}' .
                '})();</script>'
            );
            return;
        }

        if (!$isAndroid) return;

        $script = $_SERVER['SCRIPT_NAME'] ?? '';

        // Di halaman login: tampilkan alert khusus bila akun gagal login karena suspend.
        if (preg_match('#/login/index\.php$#', $script)) {
            $checkurl = $CFG->wwwroot . '/local/dosman_ujian/check_suspend_status.php';
            $html = '<script>(function(){' .
                    'if(window.__dosmanSuspendAlertInjected)return;' .
                    'window.__dosmanSuspendAlertInjected=true;' .
                    'function hasLoginError(){' .
                      'var txt=(document.body&&document.body.innerText?document.body.innerText:"").toLowerCase();' .
                      'return txt.indexOf("invalid login")!==-1||txt.indexOf("login salah")!==-1||txt.indexOf("gagal login")!==-1;' .
                    '}' .
                    'function getUsername(){' .
                      'var el=document.getElementById("username");' .
                      'if(!el||!el.value)return"";' .
                      'return (el.value||"").trim();' .
                    '}' .
                    'function loadSwal(){' .
                      'return new Promise(function(resolve){' .
                        'if(window.Swal&&typeof window.Swal.fire==="function"){resolve();return;}' .
                        'var s=document.createElement("script");' .
                        's.src="https://cdn.jsdelivr.net/npm/sweetalert2@11";' .
                        's.onload=function(){resolve();};' .
                        's.onerror=function(){resolve();};' .
                        'document.head.appendChild(s);' .
                      '});' .
                    '}' .
                    'function showSuspendAlert(){' .
                      'var msg="Akun Anda sedang ditangguhkan. Hubungi tim IT atau pengawas ruangan.";' .
                      'if(window.Swal&&typeof window.Swal.fire==="function"){' .
                        'window.Swal.fire({' .
                          'icon:"warning",' .
                          'title:"Akun Ditangguhkan",' .
                          'text:msg,' .
                          'confirmButtonText:"Mengerti",' .
                          'allowOutsideClick:false' .
                        '});' .
                      '}else{alert(msg);}' .
                    '}' .
                    'function run(){' .
                      'if(!hasLoginError())return;' .
                      'var username=getUsername();' .
                      'if(!username)return;' .
                      'fetch("' . $checkurl . '?username="+encodeURIComponent(username),{credentials:"same-origin",cache:"no-store"})' .
                      '.then(function(r){return r.json();})' .
                      '.then(function(d){' .
                        'if(d&&d.success===true&&d.suspended===true){' .
                          'loadSwal().then(showSuspendAlert);' .
                        '}' .
                      '})' .
                      '.catch(function(){});' .
                    '}' .
                    'if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",run);}' .
                    'else{run();}' .
                    '})();</script>';
            $hook->add_html($html);
            return;
        }

        if (!preg_match('#/mod/quiz/(attempt|view|startattempt)\.php#', $script)) return;

        if (empty($USER->id) || \isguestuser($USER)) return;

        $quizid = 0;
        if (strpos($script, 'attempt.php') !== false) {
            $attemptid = (int)($_GET['attempt'] ?? 0);
            if ($attemptid > 0) {
                $quizid = (int)$DB->get_field('quiz_attempts', 'quiz',
                    ['id' => $attemptid, 'userid' => (int)$USER->id]);
            }
        } else {
            $cmid = (int)($_GET['id'] ?? ($_GET['cmid'] ?? 0));
            if ($cmid > 0) {
                $quizid = (int)$DB->get_field('course_modules', 'instance', ['id' => $cmid]);
            }
        }

        if ($quizid <= 0) return;

        $hburl = $CFG->wwwroot . '/local/dosman_ujian/web_heartbeat.php?quizid=' . $quizid;
        $home  = $CFG->wwwroot;

        $html = '<script>(function(){' .
                'function hb(){fetch("' . $hburl . '",{credentials:"same-origin",cache:"no-store"})' .
                '.then(function(r){return r.json();})' .
                '.then(function(d){' .
                  'if(d.status==="blocked"||d.status==="suspended"){location.href="' . $home . '/login/index.php";}' .
                '})' .
                '.catch(function(){});}' .
                'hb();setInterval(hb,15000);' .
                '})();</script>';

        $hook->add_html($html);
    }
}
