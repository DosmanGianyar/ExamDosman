import 'package:dosman_ujian/config/app_config.dart';
import 'package:dosman_ujian/services/api_service.dart';
import 'package:dosman_ujian/services/device_service.dart';
import 'package:dosman_ujian/services/kiosk_controller.dart';
import 'package:dosman_ujian/services/offline_quiz_service.dart';
import 'package:dosman_ujian/widgets/pin_reminder_layer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

  group('DeviceService.isValidUniqueId', () {
    test('accepts standard UUID and aid_<16hex>, rejects legacy Android Build.ID', () {
      expect(DeviceService.isValidUniqueId('550e8400-e29b-41d4-a716-446655440000'), isTrue);
      expect(DeviceService.isValidUniqueId('aid_0123456789abcdef'), isTrue);

      expect(DeviceService.isValidUniqueId('UP1A.231005.007'), isFalse);
      expect(DeviceService.isValidUniqueId('AP3A.240905.015.A2'), isFalse);
      expect(DeviceService.isValidUniqueId(''), isFalse);
      expect(DeviceService.isValidUniqueId('u123__UP1A.231005.007'), isFalse);
    });
  });

  group('OfflineQuizService image attribute parsing', () {
    test('extracts and replaces only img src attribute without corrupting data-src or alt', () {
      const url = 'https://lms.sman1-gianyar.sch.id:9443/webservice/pluginfile.php/10/q/img.png';
      const html = '<p><img alt="$url" data-src="$url" src="$url" width="100"></p>';

      final urls = OfflineQuizService.extractExternalImageUrlsForTesting(html);
      expect(urls, equals([url]));

      const dataUri = 'data:image/png;base64,AAAA';
      final replaced = OfflineQuizService.replaceCachedImagesForTesting(
        html,
        {url: dataUri},
      );
      expect(replaced, contains('data-src="$url"'));
      expect(replaced, contains('alt="$url"'));
      expect(replaced, contains('src="$dataUri"'));
    });
  });

  group('PinReminderLayer startup grace transition', () {
    const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() {
      KioskController.instance.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lockdownChannel, (call) async {
        if (call.method == 'isGuidedAccessActive' ||
            call.method == 'isLockTaskActive' ||
            call.method == 'isScreenPinningEnabled') {
          return false;
        }
        return true;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lockdownChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
      KioskController.instance.resetForTesting();
    });

    testWidgets('shows iOS unpinned overlay after 3s startup grace expires even if pinned stays false', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: PinReminderLayer(
              child: Scaffold(body: Text('Konten Ujian')),
            ),
          ),
        );
        await tester.pump();

        await KioskController.instance.lock(userId: 10);
        await tester.pump();
        await tester.pump();

        expect(find.text('Mode Ujian Belum Terkunci'), findsNothing);

        KioskController.instance.expirePinStartupGraceForTesting();
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump();

        expect(find.text('Mode Ujian Belum Terkunci'), findsOneWidget);

        await KioskController.instance.unlock();
        await tester.pump();
        expect(find.text('Mode Ujian Belum Terkunci'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
