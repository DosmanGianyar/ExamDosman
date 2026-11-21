import 'package:dosman_ujian/config/app_config.dart';
import 'package:dosman_ujian/services/api_service.dart';
import 'package:dosman_ujian/services/kiosk_controller.dart';
import 'package:dosman_ujian/services/offline_quiz_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lockdownChannel = MethodChannel(AppConfig.lockdownChannel);

  group('OfflineQuizService.classifySubmitError', () {
    test('classifies already finished and attemptalreadyclosed as alreadyFinished', () {
      expect(
        OfflineQuizService.classifySubmitError(
          ApiException('This attempt has already been finished.', errorCode: 'attemptalreadyclosed'),
        ),
        SubmitErrorAction.alreadyFinished,
      );
      expect(
        OfflineQuizService.classifySubmitError(
          ApiException('This attempt has already been finished.'),
        ),
        SubmitErrorAction.alreadyFinished,
      );
    });

    test('classifies sequence mismatch errors as outOfSequence', () {
      expect(
        OfflineQuizService.classifySubmitError(
          ApiException(
            'You have entered data outside the normal sequence.',
            errorCode: 'submissionoutofsequencefriendlymessage',
          ),
        ),
        SubmitErrorAction.outOfSequence,
      );
    });

    test('classifies token expiry and suspended account errors as authBlocked', () {
      expect(
        OfflineQuizService.classifySubmitError(TokenExpiredException()),
        SubmitErrorAction.authBlocked,
      );
      expect(
        OfflineQuizService.classifySubmitError(
          ApiException('Refused web service access for suspended username: x'),
        ),
        SubmitErrorAction.authBlocked,
      );
    });

    test('classifies network exceptions and 502 errors as retryableNetwork', () {
      expect(
        OfflineQuizService.classifySubmitError(NetworkException()),
        SubmitErrorAction.retryableNetwork,
      );
      expect(
        OfflineQuizService.classifySubmitError(ApiException('HTTP Error: 502')),
        SubmitErrorAction.retryableNetwork,
      );
    });
  });

  group('KioskController reviewer & idempotent lock state', () {
    final invokedMethods = <String>[];

    setUp(() {
      invokedMethods.clear();
      KioskController.instance.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lockdownChannel, (call) async {
        invokedMethods.add(call.method);
        return true;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lockdownChannel, null);
      KioskController.instance.resetForTesting();
    });

    test('isReviewerUsername matches only exact official reviewer accounts', () {
      expect(KioskController.isReviewerUsername('appstore.review'), isTrue);
      expect(KioskController.isReviewerUsername('playstore.review'), isTrue);
      expect(KioskController.isReviewerUsername('admin.reviewer'), isTrue);
      expect(KioskController.isReviewerUsername('apple.review'), isTrue);
      expect(KioskController.isReviewerUsername('  AppStore.Review  '), isTrue);

      expect(KioskController.isReviewerUsername('demoputra'), isFalse);
      expect(KioskController.isReviewerUsername('siswa123'), isFalse);
      expect(KioskController.isReviewerUsername('reviewer_test'), isFalse);
      expect(KioskController.isReviewerUsername(''), isFalse);
      expect(KioskController.isReviewerUsername(null), isFalse);
    });

    test('lock() is idempotent and preserves inExamMode after enterExam()', () async {
      final kiosk = KioskController.instance;

      await kiosk.lock(userId: 10);
      expect(kiosk.active, isTrue);
      expect(kiosk.inExamMode, isFalse);
      expect(invokedMethods.where((m) => m == 'enterLockTask').length, 1);

      kiosk.enterExam();
      expect(kiosk.inExamMode, isTrue);

      await kiosk.lock(userId: 10);
      expect(invokedMethods.where((m) => m == 'enterLockTask').length, 1);
      expect(invokedMethods, contains('setUserId'));
      expect(kiosk.inExamMode, isTrue);
    });

    test('handleFatalViolation ignores violations when not inExamMode', () async {
      final kiosk = KioskController.instance;
      await kiosk.lock(userId: 10);
      expect(kiosk.inExamMode, isFalse);

      final triggered = await kiosk.handleFatalViolation(
        reason: 'Siswa memaksa melepas pinned screen (alarm aktif)',
        userId: 10,
      );
      expect(triggered, isFalse);
      expect(kiosk.isHandlingFatalViolation, isFalse);
    });
  });
}
