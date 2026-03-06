import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  // Singleton Pattern
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  // 1. التهيئة الأولية (يجب استدعاؤها في main.dart)
  Future<void> init() async {
    if (_isInitialized) return;

    // إعداد التوقيت المحلي (Timezone)
    await _configureLocalTimeZone();

    // إعدادات Android
    // تأكد من وجود أيقونة باسم 'app_icon' في مجلد android/app/src/main/res/drawable/
    // أو استخدم '@mipmap/ic_launcher' الأيقونة الافتراضية
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // إعدادات iOS
    final DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );

    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // هنا نضع كود عند ضغط المستخدم على الإشعار
        // مثلاً التوجه لتفاصيل المهمة
        print("Notification Tapped with Payload: ${response.payload}");
      },
    );

    _isInitialized = true;
  }

  // ضبط التوقيت حسب جهاز المستخدم
  Future<void> _configureLocalTimeZone() async {
    tz.initializeTimeZones();
    try {
      // التعديل: التعامل مع التوقيت كنص مباشرةً
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));
    } catch (e) {
      // في حال الفشل أو عدم توافق الاسم، نستخدم UTC كاحتياط
      print("Could not get local timezone: $e");
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
  }

  // 2. طلب الأذونات (Android 13+ & iOS)
  Future<void> requestPermissions() async {
    if (Platform.isIOS) {
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    } else if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      // طلب إذن الإشعارات (Android 13+)
      await androidImplementation?.requestNotificationsPermission();
      
      // طلب إذن الجدولة الدقيقة (Exact Alarms)
      // ملاحظة: هذا الإذن قد يتطلب من المستخدم الذهاب للإعدادات يدوياً في بعض الأجهزة
      // ولكننا أضفنا الإذن في AndroidManifest
      await androidImplementation?.requestExactAlarmsPermission();
    }
  }

  // 3. جدولة الإشعار
  Future<void> scheduleTaskNotification({
    required String taskId, // الـ UUID القادم من قاعدة البيانات
    required String title,
    required DateTime scheduledTime,
  }) async {
    // تحويل الوقت إلى TZDateTime
    final tz.TZDateTime tzScheduledTime =
        tz.TZDateTime.from(scheduledTime, tz.local);

    // إذا كان الوقت في الماضي، لا نجدول إشعاراً
    if (tzScheduledTime.isBefore(tz.TZDateTime.now(tz.local))) {
      return;
    }

    // تفاصيل الإشعار
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
      'daily_tasks_channel', // id القناة
      'Daily Tasks', // اسم القناة
      channelDescription: 'Notifications for your scheduled tasks',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      fullScreenIntent: true, // لإيقاظ الشاشة (اختياري)
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails);

    // الجدولة الفعلية
    // نستخدم hashCode للـ UUID لأن المكتبة تقبل int فقط كـ ID
    await flutterLocalNotificationsPlugin.zonedSchedule(
      taskId.hashCode, 
      'تذكير بالمهمة',
      title,
      tzScheduledTime,
      notificationDetails,
      // مهم جداً: لتوفير الطاقة والعمل بدقة
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: taskId, // نمرر المعرف كنص للاستخدام عند الضغط
    );
  }

  // 4. إلغاء إشعار محدد (عند إكمال المهمة أو حذفها)
  Future<void> cancelNotification(String taskId) async {
    await flutterLocalNotificationsPlugin.cancel(taskId.hashCode);
  }

  // إلغاء الكل
  Future<void> cancelAll() async {
    await flutterLocalNotificationsPlugin.cancelAll();
  }
}