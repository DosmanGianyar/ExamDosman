import 'dart:convert';
import 'dart:io';

import 'package:dosman_ujian/config/app_config.dart';
import 'package:dosman_ujian/services/api_service.dart';
import 'package:dosman_ujian/services/exam_service.dart';
import 'package:dosman_ujian/services/offline_quiz_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  void installMocks() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockdownChannel, (call) async {
      if (call.method == 'getAppFilesDir') return tempAppDir.path;
      return true;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = call.arguments as Map<dynamic, dynamic>?;
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          return key != null ? storage[key] : null;
        case 'write':
          if (key != null) storage[key] = args?['value'] as String? ?? '';
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

  void clearMocks() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockdownChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  }

  OfflineQuizPackage makeSamplePkg({
    int quizId = 248,
    int attemptId = 38774,
    int userId = 2373,
    OfflineSubmissionStatus status = OfflineSubmissionStatus.inProgress,
  }) {
    return OfflineQuizPackage(
      quizId: quizId,
      courseId: 142,
      attemptId: attemptId,
      userId: userId,
      quizName: 'SAS | BIOLOGI',
      endTimeEpochSec: 1795667830,
      parserVersion: OfflineQuizService.kCurrentParserVersion,
      submissionStatus: status,
      questions: [
        OfflineQuestion(
          slot: 1,
          number: 1,
          type: 'multichoice',
          questionHtml: '<p>Soal gambar <img src="data:image/png;base64,AAAA"/></p>',
          answerFieldName: 'q42429:1_answer',
          sequenceCheckName: 'q42429:1_:sequencecheck',
          sequenceCheckValue: '1',
          options: const [
            OfflineOption(value: '0', labelLetter: 'A', html: '<p>Opsi A</p>'),
            OfflineOption(value: '1', labelLetter: 'B', html: '<p>Opsi B</p>'),
          ],
          selectedValue: '1',
          isFlagged: false,
        ),
        OfflineQuestion(
          slot: 2,
          number: 2,
          type: 'multichoice',
          questionHtml: '<p>Soal 2</p>',
          answerFieldName: 'q42429:2_answer',
          sequenceCheckName: 'q42429:2_:sequencecheck',
          sequenceCheckValue: '1',
          options: const [
            OfflineOption(value: '0', labelLetter: 'A', html: '<p>2A</p>'),
            OfflineOption(value: '1', labelLetter: 'B', html: '<p>2B</p>'),
          ],
          selectedValue: '0',
          isFlagged: true,
        ),
      ],
    );
  }

  setUp(() async {
    tempAppDir = await Directory.systemTemp.createTemp('dosman_persist_test_');
    storage.clear();
    OfflineQuizService.resetStorageDirCacheForTesting();
    installMocks();
    ApiService.setToken('tok_test_2373');
  });

  tearDown(() async {
    clearMocks();
    ApiService.clearToken();
    if (await tempAppDir.exists()) {
      await tempAppDir.delete(recursive: true);
    }
  });

  test('OfflineSubmissionStatus serializes and deserializes all 4 states with safe default', () {
    for (final s in OfflineSubmissionStatus.values) {
      expect(OfflineSubmissionStatus.fromWireString(s.toWireString()), s);
    }
    expect(OfflineSubmissionStatus.fromWireString(null), OfflineSubmissionStatus.inProgress);
    expect(OfflineSubmissionStatus.fromWireString('unknown_future_state'), OfflineSubmissionStatus.inProgress);

    // Backward compatibility: legacy JSON without new fields
    final legacyPkg = OfflineQuizPackage.fromJson({
      'quizId': 10,
      'courseId': 2,
      'attemptId': 99,
      'userId': 2373,
      'quizName': 'Legacy Quiz',
      'endTimeEpochSec': 1700000000,
      'questions': [],
    });
    expect(legacyPkg.submissionStatus, OfflineSubmissionStatus.inProgress);
    expect(legacyPkg.lockedAtEpochSec, 0);
    expect(legacyPkg.submittedAtEpochSec, 0);
    expect(legacyPkg.serverConfirmedAnswered, isNull);
    expect(legacyPkg.isLocked, isFalse);
    expect(legacyPkg.needsSubmission, isTrue);
    expect(legacyPkg.isArchived, isFalse);
  });

  test('stripQuestionContentForArchive removes question/option HTML while preserving submit payload', () {
    final pkg = makeSamplePkg();
    final originalPayload = OfflineQuizService.buildSubmitPayload(pkg);

    final stripped = OfflineQuizService.stripQuestionContentForArchive(
      pkg,
      submissionStatus: OfflineSubmissionStatus.lockedPending,
      lockedAtEpochSec: 1795667800,
    );

    expect(stripped.questions[0].questionHtml, isEmpty);
    expect(stripped.questions[0].options[0].html, isEmpty);
    expect(stripped.questions[0].selectedValue, '1');
    expect(stripped.questions[1].selectedValue, '0');
    expect(stripped.questions[1].isFlagged, isTrue);
    expect(OfflineQuizService.buildSubmitPayload(stripped), equals(originalPayload));
  });

  test('lockPackageForSubmission and archiveSubmittedPackage persist permanently and filter pending vs archive', () async {
    final pkg1 = makeSamplePkg(quizId: 248, attemptId: 38774);
    final locked1 = await OfflineQuizService.lockPackageForSubmission(pkg1);
    expect(locked1.submissionStatus, OfflineSubmissionStatus.lockedPending);
    expect(locked1.isLocked, isTrue);
    expect(locked1.needsSubmission, isTrue);
    expect(locked1.questions[0].questionHtml, isEmpty);

    // lockedPending stays in findPendingPackages so user is prompted to send
    var pending = await OfflineQuizService.findPendingPackages(2373);
    expect(pending.length, 1);
    expect(pending.first.submissionStatus, OfflineSubmissionStatus.lockedPending);

    // Archive as submittedVerified: removed from pending, kept permanently on disk!
    await OfflineQuizService.archiveSubmittedPackage(
      locked1,
      serverVerifiedOk: true,
      serverConfirmedAnswered: 2,
    );
    pending = await OfflineQuizService.findPendingPackages(2373);
    expect(pending, isEmpty);

    final allSaved = await OfflineQuizService.findAllSavedPackages(2373);
    expect(allSaved.length, 1);
    expect(allSaved.first.submissionStatus, OfflineSubmissionStatus.submittedVerified);
    expect(allSaved.first.serverConfirmedAnswered, 2);
    expect(allSaved.first.answeredCount, 2);

    // Only explicit clearSavedPackage removes it
    await OfflineQuizService.clearSavedPackage(userId: 2373, quizId: 248);
    expect(await OfflineQuizService.findAllSavedPackages(2373), isEmpty);
  });

  test('isServerSaveMismatch flags 0 server answers only when endpoint reachable and local answered > 0', () {
    expect(
      OfflineQuizService.isServerSaveMismatch(
        localAnswered: 38,
        verifyReachable: true,
        serverAnsweredSlots: 0,
      ),
      isTrue,
    );
    expect(
      OfflineQuizService.isServerSaveMismatch(
        localAnswered: 38,
        verifyReachable: true,
        serverAnsweredSlots: 38,
      ),
      isFalse,
    );
    expect(
      OfflineQuizService.isServerSaveMismatch(
        localAnswered: 38,
        verifyReachable: false,
        serverAnsweredSlots: 0,
      ),
      isFalse,
    );
    expect(
      OfflineQuizService.isServerSaveMismatch(
        localAnswered: 0,
        verifyReachable: true,
        serverAnsweredSlots: 0,
      ),
      isFalse,
    );
  });

  test('ExamService.verifyAttemptSaved parses valid server counts and falls back cleanly on network errors', () async {
    final mockOk = MockClient((req) async {
      expect(req.url.path, contains('/local/dosman_ujian/verify_attempt_saved.php'));
      final body = json.decode(req.body) as Map<String, dynamic>;
      expect(body['attempt_id'], 38774);
      return http.Response(
        json.encode({
          'success': true,
          'attempt_id': 38774,
          'state': 'finished',
          'total_slots': 40,
          'answered_slots': 0,
        }),
        200,
      );
    });

    await http.runWithClient(() async {
      final res = await ExamService.verifyAttemptSaved(attemptId: 38774);
      expect(res.reachable, isTrue);
      expect(res.state, 'finished');
      expect(res.totalSlots, 40);
      expect(res.answeredSlots, 0);
    }, () => _NonClosingHttpClient(mockOk));

    final mockErr = MockClient((_) async => throw const SocketException('offline'));
    await http.runWithClient(() async {
      final res = await ExamService.verifyAttemptSaved(attemptId: 38774);
      expect(res.reachable, isFalse);
      expect(res.answeredSlots, 0);
    }, () => _NonClosingHttpClient(mockErr));
  });

  test('downloadQuizPackage returns lockedPending immediately without calling startQuizAttempt', () async {
    final pkg = makeSamplePkg(quizId: 248, attemptId: 38774);
    await OfflineQuizService.lockPackageForSubmission(pkg);

    var apiCalled = false;
    final mockNoCall = MockClient((_) async {
      apiCalled = true;
      return http.Response('unexpected', 500);
    });

    await http.runWithClient(() async {
      final loaded = await OfflineQuizService.downloadQuizPackage(
        quizId: 248,
        courseId: 142,
        userId: 2373,
        quizName: 'SAS | BIOLOGI',
        timeLimitSec: 3600,
        timeCloseEpochSec: 1795667830,
      );
      expect(apiCalled, isFalse);
      expect(loaded.submissionStatus, OfflineSubmissionStatus.lockedPending);
      expect(loaded.answeredCount, 2);
    }, () => _NonClosingHttpClient(mockNoCall));
  });

  test('downloadQuizPackage with discardExistingSavedAnswers=true wipes old archive before starting fresh attempt', () async {
    final oldPkg = makeSamplePkg(
      quizId: 248,
      attemptId: 38774,
      status: OfflineSubmissionStatus.serverEmptyWarning,
    );
    await OfflineQuizService.savePackage(oldPkg);

    final mockFresh = MockClient((req) async {
      final body = req.method == 'POST'
          ? Uri.splitQueryString(req.body)
          : req.url.queryParameters;
      final fn = body['wsfunction'] ?? '';
      if (fn == 'mod_quiz_get_user_attempts') {
        return http.Response(json.encode({'attempts': []}), 200);
      }
      if (fn == 'mod_quiz_start_attempt') {
        return http.Response(
          json.encode({
            'attempt': {'id': 99001, 'state': 'inprogress', 'timestart': 1795670000}
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
                'sequencecheck': 1,
                'html': '''
                  <div class="qtext"><p>Soal baru</p></div>
                  <div class="answer">
                    <div class="r0"><input type="radio" name="q99001:1_answer" value="0"><label>A</label></div>
                    <div class="r1"><input type="radio" name="q99001:1_answer" value="1"><label>B</label></div>
                  </div>
                ''',
              }
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      final fresh = await OfflineQuizService.downloadQuizPackage(
        quizId: 248,
        courseId: 142,
        userId: 2373,
        quizName: 'SAS | BIOLOGI',
        timeLimitSec: 3600,
        timeCloseEpochSec: 1795673600,
        discardExistingSavedAnswers: true,
      );
      expect(fresh.attemptId, 99001);
      expect(fresh.submissionStatus, OfflineSubmissionStatus.inProgress);
      expect(fresh.answeredCount, 0);
      expect(fresh.questions[0].selectedValue, isNull);
    }, () => _NonClosingHttpClient(mockFresh));
  });
}
