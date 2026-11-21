import 'dart:convert';
import 'dart:io';

import 'package:dosman_ujian/config/app_config.dart';
import 'package:dosman_ujian/screens/blocked_screen.dart';
import 'package:dosman_ujian/screens/course_list_screen.dart';
import 'package:dosman_ujian/services/api_service.dart';
import 'package:dosman_ujian/services/auth_service.dart';
import 'package:dosman_ujian/services/exam_service.dart';
import 'package:dosman_ujian/services/kiosk_controller.dart';
import 'package:dosman_ujian/services/offline_quiz_service.dart';
import 'package:dosman_ujian/widgets/pin_reminder_layer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Client pembungkus yang mengabaikan `.close()` agar zona `http.runWithClient`
/// tetap dapat melayani beberapa request berurutan dengan MockClient yang sama.
class _NonClosingHttpClient extends http.BaseClient {
  final http.Client _inner;
  _NonClosingHttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lockdownChannel = MethodChannel(AppConfig.lockdownChannel);
  const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late Directory tempAppDir;
  final storage = <String, String>{};
  final nativeCalls = <String>[];
  bool isPinnedState = true;

  // 1x1 PNG transparan valid (68 bytes)
  final validPngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  );

  void installPlatformMocks() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockdownChannel, (call) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'getAppFilesDir':
          return tempAppDir.path;
        case 'isLockTaskActive':
        case 'isGuidedAccessActive':
          return isPinnedState;
        case 'isScreenPinningEnabled':
          return true;
        default:
          return true;
      }
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = call.arguments as Map<dynamic, dynamic>?;
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          return key != null ? storage[key] : null;
        case 'write':
          if (key != null) {
            storage[key] = args?['value'] as String? ?? '';
          }
          return null;
        case 'delete':
          if (key != null) storage.remove(key);
          return null;
        case 'deleteAll':
          storage.clear();
          return null;
        default:
          return null;
      }
    });
  }

  void clearPlatformMocks() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockdownChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  }

  String sampleQuestionHtml({
    required int slot,
    required int qNumber,
    required String seqVal,
    String extraBodyHtml = '<p>Teks soal normal</p>',
  }) {
    return '''
<div id="question-100-$slot" class="que multichoice deferredfeedback">
  <div class="info"><h3 class="no">Question <span class="qno">$qNumber</span></h3></div>
  <div class="content">
    <div class="formulation clearfix">
      <div class="qtext">
        <!--StartFragment-->
        <div class="WordSection1">
          $extraBodyHtml
        </div>
      </div>
      <div class="ablock">
        <div class="answer">
          <div class="r0">
            <input type="radio" name="q100:${slot}_answer" value="0" id="q100_${slot}_0">
            <label for="q100_${slot}_0"><span class="answernumber">a. </span><div class="flex-fill ml-1"><p>Opsi A</p></div></label>
          </div>
          <div class="r1">
            <input type="radio" name="q100:${slot}_answer" value="1" id="q100_${slot}_1">
            <label for="q100_${slot}_1"><span class="answernumber">b. </span><div class="flex-fill ml-1"><p>Opsi B</p></div></label>
          </div>
        </div>
      </div>
      <input type="hidden" name="q100:${slot}_:sequencecheck" value="$seqVal" />
    </div>
  </div>
</div>
''';
  }

  setUpAll(() {
    tempAppDir = Directory.systemTemp.createTempSync('dosman_chaos_sim_');
  });

  tearDownAll(() {
    if (tempAppDir.existsSync()) {
      tempAppDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    storage.clear();
    nativeCalls.clear();
    isPinnedState = true;
    ApiService.clearToken();
    ApiService.resetServerClockForTesting();
    KioskController.instance.resetForTesting();
    installPlatformMocks();
    await AuthService.saveToken('INIT_TOKEN_123');
    await AuthService.saveUserInfo(
      userId: 2003,
      username: 'siswa2026',
      fullname: '01 Siswa Uji | XII A | 2024',
    );
    await AuthService.saveDepartment('XII A');
    await AuthService.savePassword('rahasia123');
  });

  tearDown(() {
    for (final f in tempAppDir.listSync()) {
      f.deleteSync(recursive: true);
    }
    KioskController.instance.resetForTesting();
    ApiService.resetServerClockForTesting();
    clearPlatformMocks();
  });

  group('Grup 1-2: OfflineQuizService download, image chaos retry, & Wi-Fi drop recovery', () {
    test('downloads multi-page quiz with 502 image retry, 404 resilience, and saves package locally', () async {
      var retryImgAttempts = 0;

      final mock = MockClient((req) async {
        final ws = req.url.queryParameters['wsfunction'] ?? '';
        if (req.url.path.endsWith('/webservice/rest/server.php')) {
          final bodyMap = req.method == 'POST'
              ? Uri.splitQueryString(req.body)
              : req.url.queryParameters;
          final fn = bodyMap['wsfunction'] ?? ws;

          if (fn == 'mod_quiz_get_user_attempts') {
            return http.Response(json.encode({'attempts': []}), 200);
          }
          if (fn == 'mod_quiz_start_attempt') {
            return http.Response(
              json.encode({
                'attempt': {
                  'id': 7701,
                  'quiz': 209,
                  'userid': 2003,
                  'timestart': 1795250000,
                  'state': 'inprogress',
                },
              }),
              200,
            );
          }
          if (fn == 'mod_quiz_get_attempt_data') {
            final page = int.tryParse(bodyMap['page'] ?? '0') ?? 0;
            if (page == 0) {
              return http.Response(
                json.encode({
                  'nextpage': 1,
                  'questions': [
                    {
                      'slot': 1,
                      'number': 1,
                      'type': 'multichoice',
                      'sequencecheck': 1,
                      'html': sampleQuestionHtml(
                        slot: 1,
                        qNumber: 1,
                        seqVal: '1',
                        extraBodyHtml:
                            '<p>Perhatikan grafik: <img alt="/pluginfile.php/10/q/ok.png" src="/pluginfile.php/10/q/ok.png">'
                            '<img src="https://lms.sman1-gianyar.sch.id:9443/pluginfile.php/10/q/flaky.jpg"></p>',
                      ),
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              json.encode({
                'nextpage': -1,
                'questions': [
                  {
                    'slot': 2,
                    'number': 2,
                    'type': 'multichoice',
                    'sequencecheck': 1,
                    'html': sampleQuestionHtml(
                      slot: 2,
                      qNumber: 2,
                      seqVal: '1',
                      extraBodyHtml: '<p>Gambar hilang: <img src="/pluginfile.php/10/q/missing404.png"></p>',
                    ),
                  },
                ],
              }),
              200,
            );
          }
        }

        if (req.url.path.contains('/webservice/pluginfile.php/10/q/ok.png')) {
          return http.Response.bytes(validPngBytes, 200, headers: {'content-type': 'image/png'});
        }
        if (req.url.path.contains('/webservice/pluginfile.php/10/q/flaky.jpg')) {
          retryImgAttempts++;
          if (retryImgAttempts == 1) {
            return http.Response('Bad Gateway', 502);
          }
          return http.Response.bytes(validPngBytes, 200, headers: {'content-type': 'image/jpeg'});
        }
        if (req.url.path.contains('/webservice/pluginfile.php/10/q/missing404.png')) {
          return http.Response('Not Found', 404);
        }

        return http.Response('Not found: ${req.url}', 404);
      });

      await http.runWithClient(() async {
        final pkg = await OfflineQuizService.downloadQuizPackage(
          quizId: 209,
          courseId: 50,
          userId: 2003,
          quizName: 'SIMULASI CHAOS',
          timeLimitSec: 3600,
          timeCloseEpochSec: 1795256000,
        );

        expect(pkg.attemptId, 7701);
        expect(pkg.questions.length, 2);
        expect(retryImgAttempts, 2);

        final q1 = pkg.questions[0];
        expect(q1.questionHtml, contains('alt="/pluginfile.php/10/q/ok.png"'));
        expect(q1.questionHtml, contains('data:image/png;base64,'));
        expect(q1.questionHtml, contains('data:image/jpeg;base64,'));

        // Gambar 404 tetap tidak menggagalkan download paket soal
        final q2 = pkg.questions[1];
        expect(q2.questionHtml, contains('missing404.png'));

        // Simpan jawaban siswa lalu pastikan Wi-Fi putus total tetap memulihkan paket & jawaban lokal
        q1.selectedValue = '1';
        q1.isFlagged = true;
        await OfflineQuizService.saveAnswersState(pkg);

        final pending = await OfflineQuizService.findPendingPackages(2003);
        expect(pending.length, 1);
        expect(pending.first.questions[0].selectedValue, '1');
        expect(pending.first.questions[0].isFlagged, isTrue);
      }, () => _NonClosingHttpClient(mock));

      // Simulasi Wi-Fi putus total sebelum masuk ulang ke ujian
      final offlineMock = MockClient((_) async {
        throw const SocketException('Wi-Fi dropped');
      });

      await http.runWithClient(() async {
        final recovered = await OfflineQuizService.downloadQuizPackage(
          quizId: 209,
          courseId: 50,
          userId: 2003,
          quizName: 'SIMULASI CHAOS',
          timeLimitSec: 3600,
          timeCloseEpochSec: 1795256000,
        );
        expect(recovered.attemptId, 7701);
        expect(recovered.questions[0].selectedValue, '1');
        expect(recovered.questions[0].isFlagged, isTrue);
      }, () => _NonClosingHttpClient(offlineMock));
    });
  });

  group('Grup 3-4: Submit Chaos (502 -> outOfSequence -> authBlocked -> Silent Re-Login -> Finished)', () {
    OfflineQuizPackage buildSamplePkg() {
      return OfflineQuizPackage(
        quizId: 209,
        courseId: 50,
        attemptId: 8801,
        userId: 2003,
        quizName: 'Tes Submit Chaos',
        endTimeEpochSec: 1795256000,
        parserVersion: OfflineQuizService.kCurrentParserVersion,
        questions: [
          OfflineQuestion(
            slot: 1,
            number: 1,
            type: 'multichoice',
            questionHtml: '<p>Soal 1</p>',
            answerFieldName: 'q100:1_answer',
            sequenceCheckName: 'q100:1_:sequencecheck',
            sequenceCheckValue: '1',
            selectedValue: '0',
            options: const [
              OfflineOption(value: '0', labelLetter: 'A', html: '<p>Benar</p>'),
              OfflineOption(value: '1', labelLetter: 'B', html: '<p>Salah</p>'),
            ],
          ),
        ],
      );
    }

    test('handles 502 retry, outOfSequence sequencecheck refresh, and finishes clean', () async {
      final pkg = buildSamplePkg();
      await OfflineQuizService.savePackage(pkg);

      var processCallCount = 0;
      String? finalSubmittedSeqVal;

      final mock = MockClient((req) async {
        final bodyMap = req.method == 'POST'
            ? Uri.splitQueryString(req.body)
            : req.url.queryParameters;
        final fn = bodyMap['wsfunction'] ?? '';

        if (fn == 'mod_quiz_process_attempt') {
          processCallCount++;
          if (processCallCount == 1) {
            return http.Response('Bad Gateway', 502);
          }
          if (processCallCount == 2) {
            return http.Response(
              json.encode({
                'exception': 'moodle_exception',
                'errorcode': 'submissionoutofsequencefriendlymessage',
                'message': 'You have entered data outside the normal sequence.',
              }),
              200,
            );
          }
          finalSubmittedSeqVal = bodyMap['data[0][value]'];
          return http.Response(json.encode({'state': 'finished'}), 200);
        }

        if (fn == 'mod_quiz_get_user_attempts') {
          return http.Response(
            json.encode({
              'attempts': [
                {'id': 8801, 'state': 'inprogress'},
              ],
            }),
            200,
          );
        }

        if (fn == 'mod_quiz_get_attempt_data') {
          return http.Response(
            json.encode({
              'nextpage': -1,
              'questions': [
                {
                  'slot': 1,
                  'number': 1,
                  'type': 'multichoice',
                  'sequencecheck': 2,
                  'html': sampleQuestionHtml(slot: 1, qNumber: 1, seqVal: '2'),
                },
              ],
            }),
            200,
          );
        }

        return http.Response('Unexpected $fn', 500);
      });

      await http.runWithClient(() async {
        // Percobaan #1: HTTP 502 -> retryableNetwork
        try {
          await ApiService.processQuizAttempt(
            pkg.attemptId,
            OfflineQuizService.buildSubmitPayload(pkg),
          );
          fail('Harus melempar ApiException 502');
        } catch (e) {
          expect(OfflineQuizService.classifySubmitError(e), SubmitErrorAction.retryableNetwork);
        }

        // Percobaan #2: outOfSequence -> refreshSequenceChecks -> resubmit
        try {
          await ApiService.processQuizAttempt(
            pkg.attemptId,
            OfflineQuizService.buildSubmitPayload(pkg),
          );
          fail('Harus melempar ApiException outOfSequence');
        } catch (e) {
          expect(OfflineQuizService.classifySubmitError(e), SubmitErrorAction.outOfSequence);
        }

        final st = await OfflineQuizService.refreshSequenceChecks(pkg);
        expect(st, 'inprogress');
        expect(pkg.questions.first.sequenceCheckValue, '2');
        expect(pkg.questions.first.selectedValue, '0');

        final resultState = await ApiService.processQuizAttempt(
          pkg.attemptId,
          OfflineQuizService.buildSubmitPayload(pkg),
        );
        expect(resultState, 'finished');
        expect(finalSubmittedSeqVal, '2');
      }, () => _NonClosingHttpClient(mock));
    });

    test('handles invalidtoken authBlocked -> silent re-login -> resubmit with refreshed token', () async {
      final pkg = buildSamplePkg();
      String? tokenOnFinalSubmit;

      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/login/token.php')) {
          return http.Response(json.encode({'token': 'NEW_FRESH_TOKEN_999'}), 200);
        }

        final bodyMap = req.method == 'POST'
            ? Uri.splitQueryString(req.body)
            : req.url.queryParameters;
        final fn = bodyMap['wsfunction'] ?? '';
        final tok = bodyMap['wstoken'] ?? '';

        if (fn == 'core_webservice_get_site_info') {
          return http.Response(
            json.encode({
              'userid': 2003,
              'fullname': '01 Siswa Uji | XII A | 2024',
              'username': 'siswa2026',
            }),
            200,
          );
        }

        if (fn == 'mod_quiz_process_attempt') {
          if (tok == 'INIT_TOKEN_123') {
            return http.Response(
              json.encode({
                'exception': 'moodle_exception',
                'errorcode': 'invalidtoken',
                'message': 'Invalid token - token not found',
              }),
              200,
            );
          }
          tokenOnFinalSubmit = tok;
          return http.Response(json.encode({'state': 'finished'}), 200);
        }

        return http.Response('{}', 200);
      });

      await http.runWithClient(() async {
        try {
          await ApiService.processQuizAttempt(
            pkg.attemptId,
            OfflineQuizService.buildSubmitPayload(pkg),
          );
          fail('Harus melempar TokenExpiredException');
        } catch (e) {
          expect(OfflineQuizService.classifySubmitError(e), SubmitErrorAction.authBlocked);
        }

        await AuthService.login('siswa2026', 'rahasia123');
        expect(ApiService.currentToken, 'NEW_FRESH_TOKEN_999');

        final st = await ApiService.processQuizAttempt(
          pkg.attemptId,
          OfflineQuizService.buildSubmitPayload(pkg),
        );
        expect(st, 'finished');
        expect(tokenOnFinalSubmit, 'NEW_FRESH_TOKEN_999');
      }, () => _NonClosingHttpClient(mock));
    });
  });

  group('Grup 5-6: Real HTTP suspend/checkBlocked/appPing contracts + BlockedScreen recovery flow', () {
    test('handleFatalViolation & flushPendingSuspend respect real HTTP ignored:true without mock override', () async {
      await ExamService.savePendingSuspend(2003);

      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/suspend_student.php')) {
          return http.Response(
            json.encode({
              'success': false,
              'ignored': true,
              'message': 'Siswa tidak sedang mengerjakan ujian aktif',
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      await http.runWithClient(() async {
        final kiosk = KioskController.instance;
        await kiosk.ensureLockedAndEnterExam(userId: 2003);

        var notified = false;
        kiosk.addViolationListener((_) => notified = true);

        final triggered = await kiosk.handleFatalViolation(
          reason: 'Siswa memaksa melepas pinned screen (alarm aktif)',
          userId: 2003,
        );

        expect(triggered, isFalse);
        expect(notified, isFalse);
        expect(kiosk.active, isTrue);
        expect(kiosk.inExamMode, isTrue);
        expect(storage.containsKey('dosman_pending_suspend_userid'), isFalse);

        // Simpan lagi lalu uji flushPendingSuspend saat server balas ignored:true
        await ExamService.savePendingSuspend(2003);
        await ExamService.flushPendingSuspend();
        expect(storage.containsKey('dosman_pending_suspend_userid'), isFalse);
      }, () => _NonClosingHttpClient(mock));
    });

    test('pingAppLogin & checkBlocked stay fail-open on SocketException and enforce 401 suspended', () async {
      final dropMock = MockClient((_) async {
        throw const SocketException('Timeout');
      });

      await http.runWithClient(() async {
        final pingOk = await ExamService.pingAppLogin(quizId: 209);
        expect(pingOk, isTrue);

        final blk = await ExamService.checkBlocked(userId: 2003);
        expect(blk.reachable, isFalse);
        expect(blk.blocked, isFalse);
      }, () => _NonClosingHttpClient(dropMock));

      final suspMock = MockClient((req) async {
        if (req.url.path.endsWith('/app_ping.php')) {
          return http.Response(json.encode({'success': false, 'suspended': true}), 401);
        }
        return http.Response(json.encode({'blocked': true, 'reason': 'Pelanggaran kuncian'}), 200);
      });

      await http.runWithClient(() async {
        expect(await ExamService.pingAppLogin(quizId: 209), isFalse);
        final blk = await ExamService.checkBlocked(userId: 2003);
        expect(blk.reachable, isTrue);
        expect(blk.blocked, isTrue);
        expect(blk.reason, 'Pelanggaran kuncian');
      }, () => _NonClosingHttpClient(suspMock));
    });

    testWidgets('offline fatal violation pushes BlockedScreen, polls check_blocked, and recovers to /courses', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      KioskController.instance.initKioskBridge(rootNavigatorKey: navKey);

      var serverUnblocked = false;
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/suspend_student.php')) {
          throw const SocketException('No signal');
        }
        if (req.url.path.endsWith('/check_blocked.php')) {
          if (!serverUnblocked) {
            return http.Response(
              json.encode({'blocked': true, 'reason': 'Masih ditangguhkan oleh pengawas ruang.'}),
              200,
            );
          }
          return http.Response(json.encode({'blocked': false, 'reason': ''}), 200);
        }
        if (req.url.path.endsWith('/webservice/rest/server.php')) {
          return http.Response(json.encode({'userid': 2003, 'fullname': 'Siswa Uji'}), 200);
        }
        return http.Response('{}', 200);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            routes: {
              '/': (_) => const Scaffold(body: Text('ACTIVE_EXAM_HOME')),
              '/courses': (_) => const Scaffold(body: Text('COURSES_RECOVERY_LANDING')),
              '/login': (_) => const Scaffold(body: Text('LOGIN_FALLBACK')),
            },
          ),
        );

        await KioskController.instance.ensureLockedAndEnterExam(userId: 2003);
        final triggered = await KioskController.instance.handleFatalViolation(
          reason: 'Pelanggaran keamanan ujian: bluetooth_audio',
          userId: 2003,
        );
        await tester.pumpAndSettle();

        expect(triggered, isTrue);
        expect(storage['dosman_pending_suspend_userid'], '2003');
        expect(storage['dosman_blocked_status'], '1');
        expect(find.text('Akun Diblokir'), findsOneWidget);

        // Poll pertama: masih diblokir → status terbarui
        await tester.tap(find.text('Cek Status Lagi'));
        await tester.pumpAndSettle();
        expect(find.text('Masih ditangguhkan oleh pengawas ruang.'), findsOneWidget);

        // Pengawas buka blokir → poll kedua pulih ke /courses dan pendingSuspend bersih
        serverUnblocked = true;
        await tester.tap(find.text('Cek Status Lagi'));
        await tester.pumpAndSettle();

        expect(find.text('COURSES_RECOVERY_LANDING'), findsOneWidget);
        expect(storage['dosman_blocked_status'], '0');
        expect(storage.containsKey('dosman_pending_suspend_userid'), isFalse);
      }, () => _NonClosingHttpClient(mock));
    });
  });

  group('Grup 7: Responsive & Zero-Overflow UI Simulation (small/std phone & tablet + CourseList old quiz filter)', () {
    Future<void> pumpAtViewport(
      WidgetTester tester, {
      required Size size,
      required double textScale,
      required Widget child,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: child,
        ),
      );
    }

    testWidgets('BlockedScreen renders without RenderFlex overflow on small 320px screen with 1.3x font', (tester) async {
      await pumpAtViewport(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        child: const MaterialApp(
          home: BlockedScreen(
            userId: 2003,
            reason: 'Akun Anda ditangguhkan karena pelanggaran keamanan ujian yang sangat panjang untuk menguji pembungkusan teks di layar kecil.',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Akun Diblokir'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PinReminderLayer shows zero overflow on Android 320px@1.3x and Tablet 800px@1.2x', (tester) async {
      isPinnedState = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        for (final vp in [
          (size: const Size(320, 568), scale: 1.3),
          (size: const Size(800, 1280), scale: 1.2),
        ]) {
          KioskController.instance.resetForTesting();
          await pumpAtViewport(
            tester,
            size: vp.size,
            textScale: vp.scale,
            child: MaterialApp(
              key: ValueKey('pin_${vp.size.width}x${vp.size.height}'),
              home: const PinReminderLayer(
                child: Scaffold(body: Center(child: Text('Konten Utama'))),
              ),
            ),
          );
          await tester.pump();
          await KioskController.instance.lock(userId: 2003);
          KioskController.instance.expirePinStartupGraceForTesting();
          await tester.pump(const Duration(milliseconds: 900));
          await tester.pump();

          expect(find.text('Aplikasi Belum Disematkan'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await KioskController.instance.unlock();
          await tester.pump(const Duration(seconds: 6));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('CourseListScreen filters old >24h exams out of 0x Dikerjakan badge & has zero UI overflow', (tester) async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final mock = MockClient((req) async {
        final ws = req.url.queryParameters['wsfunction'] ?? '';
        if (ws == 'core_user_get_users_by_field') {
          return http.Response(
            json.encode([
              {'id': 2003, 'fullname': '01 Siswa Uji | XII A | 2024', 'department': 'XII A'},
            ]),
            200,
          );
        }
        if (ws == 'core_enrol_get_users_courses') {
          return http.Response(
            json.encode([
              {
                'id': 10,
                'fullname': 'Matematika Wajib XII',
                'shortname': 'MTK-XII',
                'categoryname': 'Kelas XII',
                'visible': 1,
              },
              {
                'id': 11,
                'fullname': 'Sejarah Indonesia Lampau',
                'shortname': 'SEJ-OLD',
                'categoryname': 'Kelas XII',
                'visible': 1,
              },
            ]),
            200,
          );
        }
        if (ws == 'mod_quiz_get_quizzes_by_courses') {
          return http.Response(
            json.encode({
              'quizzes': [
                {
                  'id': 501,
                  'course': 10,
                  'name': 'SAS Matematika Aktif',
                  'visible': 1,
                  'timeopen': nowSec - 600,
                  'timeclose': nowSec + 3000,
                },
                {
                  'id': 502,
                  'course': 11,
                  'name': 'Ujian Sejarah 3 Hari Lalu',
                  'visible': 1,
                  'timeopen': nowSec - 300000,
                  'timeclose': nowSec - 200000, // > 24 jam lalu
                },
              ],
            }),
            200,
          );
        }
        if (ws == 'mod_quiz_get_user_attempts') {
          final qid = int.tryParse(req.url.queryParameters['quizid'] ?? '0') ?? 0;
          if (qid == 501) {
            return http.Response(
              json.encode({
                'attempts': [
                  {'id': 9001, 'state': 'finished'},
                ],
              }),
              200,
            );
          }
          return http.Response(json.encode({'attempts': []}), 200);
        }
        return http.Response('{}', 200);
      });

      await http.runWithClient(() async {
        for (final vp in [
          (size: const Size(320, 568), scale: 1.3),
          (size: const Size(390, 844), scale: 1.0),
          (size: const Size(800, 1280), scale: 1.2),
        ]) {
          await pumpAtViewport(
            tester,
            size: vp.size,
            textScale: vp.scale,
            child: MaterialApp(
              key: ValueKey('courses_${vp.size.width}x${vp.size.height}'),
              home: const CourseListScreen(),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Matematika Wajib XII'), findsOneWidget);
          await tester.drag(find.byType(ListView), const Offset(0, -250));
          await tester.pumpAndSettle();
          expect(find.text('Sejarah Indonesia Lampau'), findsOneWidget);
          expect(find.textContaining('0x Dikerjakan'), findsNothing);
          expect(tester.takeException(), isNull);
        }
      }, () => _NonClosingHttpClient(mock));
    });
  });

  group('Grup 8: Server Clock Offset, 15s Auto-Submit Buffer & Silent Backup Autosave', () {
    test('syncs server clock offset from Date header, persists in package, and fires 15s before server deadline', () async {
      final localEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final serverDateHdr = HttpDate.format(
        DateTime.fromMillisecondsSinceEpoch((localEpoch + 180) * 1000, isUtc: true),
      );

      final mock = MockClient((req) async {
        return http.Response(
          json.encode({'attempts': []}),
          200,
          headers: {'date': serverDateHdr},
        );
      });

      await http.runWithClient(() async {
        await ApiService.getUserQuizAttempts(230, 2003);
      }, () => _NonClosingHttpClient(mock));

      expect(ApiService.hasServerClockSync, isTrue);
      expect(ApiService.serverClockOffsetSec, inInclusiveRange(178, 182));

      final pkg = OfflineQuizPackage(
        quizId: 230,
        courseId: 10,
        attemptId: 29862,
        userId: 2003,
        quizName: 'SAS EKONOMI',
        endTimeEpochSec: 1795250000,
        serverClockOffsetSec: ApiService.serverClockOffsetSec,
        questions: [],
      );
      await OfflineQuizService.savePackage(pkg);
      final restored = await OfflineQuizService.loadSavedPackage(userId: 2003, quizId: 230);
      expect(restored, isNotNull);
      final offset = restored!.serverClockOffsetSec;
      expect(offset, ApiService.serverClockOffsetSec);

      // Meskipun jam HP tertinggal ~180 detik dari server:
      // 16 detik sebelum deadline server -> sisa efektif 1 detik
      final localAtTMinus16 = 1795250000 - 16 - offset;
      final remAtTMinus16 = OfflineQuizService.computeEffectiveRemainingSec(
        endTimeEpochSec: 1795250000,
        nowServerEpochSec: localAtTMinus16 + offset,
      );
      expect(remAtTMinus16, 1);

      // 15 detik sebelum deadline server -> sisa efektif 0 (memicu auto-submit lebih awal)
      final localAtTMinus15 = 1795250000 - 15 - offset;
      final remAtTMinus15 = OfflineQuizService.computeEffectiveRemainingSec(
        endTimeEpochSec: 1795250000,
        nowServerEpochSec: localAtTMinus15 + offset,
      );
      expect(remAtTMinus15, 0);
    });

    test('computeBackupCheckpointsSec spreads attempt traffic smoothly with deterministic jitter', () {
      final set1 = <int>{};
      final set2 = <int>{};
      for (var attId = 29800; attId < 29900; attId++) {
        final cp = OfflineQuizService.computeBackupCheckpointsSec(attId);
        expect(cp.firstCheckpointSec, inInclusiveRange(300, 389));
        expect(cp.secondCheckpointSec, inInclusiveRange(60, 104));
        set1.add(cp.firstCheckpointSec);
        set2.add(cp.secondCheckpointSec);
      }
      expect(set1.length, greaterThan(20));
      expect(set2.length, greaterThan(15));
    });

    test('silentBackupAnswers sends finishattempt=0, syncs sequencecheck to 2, allows clean final submit, and survives 502 offline error', () async {
      final backupPayloads = <Map<String, String>>[];
      final finalPayloads = <Map<String, String>>[];

      final mock = MockClient((req) async {
        final bodyMap = req.method == 'POST'
            ? Uri.splitQueryString(req.body)
            : req.url.queryParameters;
        final fn = bodyMap['wsfunction'] ?? '';

        if (fn == 'mod_quiz_process_attempt') {
          if (bodyMap['finishattempt'] == '0') {
            if (bodyMap['attemptid'] == '9999') {
              return http.Response('Bad Gateway', 502);
            }
            backupPayloads.add(bodyMap);
            return http.Response(json.encode({'state': 'inprogress', 'warnings': []}), 200);
          }
          finalPayloads.add(bodyMap);
          return http.Response(json.encode({'state': 'finished', 'warnings': []}), 200);
        }
        if (fn == 'mod_quiz_get_user_attempts') {
          return http.Response(
            json.encode({
              'attempts': [
                {'id': 8801, 'state': 'inprogress'},
              ],
            }),
            200,
          );
        }
        if (fn == 'mod_quiz_get_attempt_data') {
          return http.Response(
            json.encode({
              'nextpage': -1,
              'questions': [
                {
                  'slot': 1,
                  'number': 1,
                  'type': 'multichoice',
                  'sequencecheck': 2,
                  'html': sampleQuestionHtml(slot: 1, qNumber: 1, seqVal: '2'),
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final pkg = OfflineQuizPackage(
        quizId: 230,
        courseId: 10,
        attemptId: 8801,
        userId: 2003,
        quizName: 'SAS EKONOMI',
        endTimeEpochSec: 1795250000,
        questions: [
          OfflineQuestion(
            slot: 1,
            number: 1,
            type: 'multichoice',
            questionHtml: '<p>Soal 1</p>',
            answerFieldName: 'q100:1_answer',
            sequenceCheckName: 'q100:1_:sequencecheck',
            sequenceCheckValue: '1',
            options: const [
              OfflineOption(value: '0', labelLetter: 'A', html: '<p>A</p>'),
              OfflineOption(value: '1', labelLetter: 'B', html: '<p>B</p>'),
            ],
            selectedValue: '0',
          ),
        ],
      );

      await http.runWithClient(() async {
        // 1. Silent backup saat ~5 menit tersisa
        final backupRes = await OfflineQuizService.silentBackupAnswers(pkg);
        expect(backupRes.saved, isTrue);
        expect(backupRes.alreadyClosed, isFalse);
        expect(backupPayloads.length, 1);
        expect(backupPayloads.first['finishattempt'], '0');
        expect(backupPayloads.first['timeup'], '0');
        expect(pkg.questions.first.sequenceCheckValue, '2');

        // 2. Siswa ubah jawaban menjadi '1' lalu submit final (harus mengirim sequencecheck=2)
        pkg.questions.first.selectedValue = '1';
        final finalState = await ApiService.processQuizAttempt(
          pkg.attemptId,
          OfflineQuizService.buildSubmitPayload(pkg),
          finishAttempt: true,
        );
        expect(finalState, 'finished');
        expect(finalPayloads.length, 1);
        expect(finalPayloads.first['finishattempt'], '1');
        expect(finalPayloads.first['data[0][value]'], '2');
        expect(finalPayloads.first['data[1][value]'], '1');

        // 3. Simulasi error jaringan/502 saat silent backup -> tidak throw & jawaban tetap aman
        final flakyPkg = OfflineQuizPackage(
          quizId: 230,
          courseId: 10,
          attemptId: 9999,
          userId: 2003,
          quizName: 'SAS EKONOMI',
          endTimeEpochSec: 1795250000,
          questions: [pkg.questions.first],
        );
        final flakyRes = await OfflineQuizService.silentBackupAnswers(flakyPkg);
        expect(flakyRes.saved, isFalse);
        expect(flakyRes.alreadyClosed, isFalse);
        expect(flakyPkg.questions.first.selectedValue, '1');
      }, () => _NonClosingHttpClient(mock));
    });
  });
}
