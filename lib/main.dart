import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notification_service.dart';
import 'auth_screen.dart';
import 'home_screen.dart'; // سنقوم بإنشائها في الخطوة القادمة، سيعطيك خطأ مؤقت الآن
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

   await dotenv.load(fileName: ".env");

  // 3. قراءة القيم من الملف بأمان
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // 2. تهيئة خدمة الإشعارات
  await NotificationService().init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Routine Planner',
      debugShowCheckedModeBanner: false,
      
      // إعداد الثيم الليلي (Dark Night Theme)
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // لون كحلي داكن جداً
        primaryColor: const Color(0xFF6366F1), // لون Indigo
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFFEC4899), // لون Pink للتفاصيل
          surface: Color(0xFF1E293B),
        ),
        useMaterial3: true,
      ),
      
      // التوجيه بناءً على حالة المصادقة
      home: const AuthGate(),
    );
  }
}

// ويدجت بسيطة للاستماع لحالة الدخول
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // أثناء التحميل
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final session = snapshot.data?.session;

        if (session != null) {
          // المستخدم مسجل الدخول -> اذهب للصفحة الرئيسية
          return const HomeScreen(); 
        } else {
          // غير مسجل -> اذهب لصفحة الدخول
          return const AuthScreen();
        }
      },
    );
  }
}