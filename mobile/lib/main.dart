// ===========================
// DOSMAN UJIAN - Main Entry Point
// Aplikasi Ujian Online Anti-Kecurangan
// SMAN 1 GIANYAR, Bali
// ===========================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'kiosk_unpin_flow.dart';
import 'screens/exam_screen.dart';
import 'screens/locked_browser_screen.dart';
import 'screens/login_screen.dart';
import 'screens/course_list_screen.dart';
import 'screens/splash_screen.dart';
import 'services/kiosk_controller.dart';
import 'widgets/pin_reminder_layer.dart';

class DosmanHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return host == '36.93.15.146' || host == 'lms.sman1-gianyar.sch.id';
      };
  }
}

void main() async {
  HttpOverrides.global = DosmanHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();

  // Kirim ulang suspend yang gagal saat offline pada sesi ujian sebelumnya.
  ExamScreen.flushPendingSuspend().catchError((_) {});

  // Kunci orientasi ke portrait saja selama ujian
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Sembunyikan status bar system UI agar layar lebih luas saat ujian
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:            Colors.transparent,
      statusBarIconBrightness:   Brightness.light,
      systemNavigationBarColor:  Color(0xFF0F172A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const DosmanUjianApp());
}

class DosmanUjianApp extends StatefulWidget {
  const DosmanUjianApp({super.key});

  @override
  State<DosmanUjianApp> createState() => _DosmanUjianAppState();
}

class _DosmanUjianAppState extends State<DosmanUjianApp> {
  final GlobalKey<NavigatorState> _rootNavKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    KioskController.instance.initKioskBridge(
      rootNavigatorKey:       _rootNavKey,
      onUnpinPasswordRequest: handleKioskUnpinPasswordRequest,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _rootNavKey,
      title:        'Dosman Ujian',
      debugShowCheckedModeBanner: false,

      // ─── Theme ───────────────────────────────────────────────────────────
      theme: ThemeData(
        useMaterial3:    true,
        colorSchemeSeed: const Color(0xFF2563EB),
        fontFamily:      'Roboto',

        // AppBar
        appBarTheme: const AppBarTheme(
          backgroundColor:  Color(0xFF1E3A5F),
          foregroundColor:  Colors.white,
          elevation:        0,
          centerTitle:      false,
          titleTextStyle:   TextStyle(
            fontSize:   17,
            fontWeight: FontWeight.w700,
            color:      Colors.white,
            fontFamily: 'Roboto',
          ),
        ),

        // ElevatedButton
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            foregroundColor: Colors.white,
            elevation:       0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize:   14,
              fontWeight: FontWeight.w600,
              fontFamily: 'Roboto',
            ),
          ),
        ),

        // OutlinedButton
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF2563EB),
            side: const BorderSide(color: Color(0xFF2563EB)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize:   14,
              fontWeight: FontWeight.w600,
              fontFamily: 'Roboto',
            ),
          ),
        ),

        // TextButton
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF2563EB),
            textStyle: const TextStyle(
              fontSize:   14,
              fontWeight: FontWeight.w600,
              fontFamily: 'Roboto',
            ),
          ),
        ),

        // Input / TextField
        inputDecorationTheme: InputDecorationTheme(
          filled:     true,
          fillColor:  const Color(0xFFF9FAFB),
          hintStyle:  const TextStyle(
            color:    Color(0xFF9CA3AF),
            fontSize: 14,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical:   14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:   const BorderSide(color: Color(0xFFE5E7EB), width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:   const BorderSide(color: Color(0xFFE5E7EB), width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:   const BorderSide(color: Color(0xFF2563EB), width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:   const BorderSide(color: Color(0xFFDC2626), width: 1.5),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:   const BorderSide(color: Color(0xFFDC2626), width: 1.5),
          ),
        ),

        // Scaffold background
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),

        // Card
        cardTheme: CardThemeData(
          color:     Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
        ),

        // Dialog
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          titleTextStyle: const TextStyle(
            fontSize:   17,
            fontWeight: FontWeight.w700,
            color:      Color(0xFF1F2937),
            fontFamily: 'Roboto',
          ),
          contentTextStyle: const TextStyle(
            fontSize: 14,
            color:    Color(0xFF374151),
            height:   1.6,
            fontFamily: 'Roboto',
          ),
        ),

        // SnackBar
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF1F2937),
          contentTextStyle: const TextStyle(
            color:    Colors.white,
            fontSize: 13,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      ),

      builder: (context, child) =>
          PinReminderLayer(child: child ?? const SizedBox.shrink()),
      routes: {
        '/login':   (context) => const LoginScreen(),
        '/courses': (context) => const CourseListScreen(),
        '/home':    (context) => const LockedBrowserScreen(),
      },
      home: const SplashScreen(),
    );
  }
}
