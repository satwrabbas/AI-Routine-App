import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  
  Future<void> init() async {
    if (_isInitialized) return;

    
    await _configureLocalTimeZone();

    
    
    
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    
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
        
        
        print("Notification Tapped with Payload: ${response.payload}");
      },
    );

    _isInitialized = true;
  }

  
  Future<void> _configureLocalTimeZone() async {
    tz.initializeTimeZones();
    try {
      
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));
    } catch (e) {
      
      print("Could not get local timezone: $e");
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
  }

  
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

      
      await androidImplementation?.requestNotificationsPermission();
      
      
      
      
      await androidImplementation?.requestExactAlarmsPermission();
    }
  }

  
  Future<void> scheduleTaskNotification({
    required String taskId, 
    required String title,
    required DateTime scheduledTime,
  }) async {
    
    final tz.TZDateTime tzScheduledTime =
        tz.TZDateTime.from(scheduledTime, tz.local);

    
    if (tzScheduledTime.isBefore(tz.TZDateTime.now(tz.local))) {
      return;
    }

    
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
      'daily_tasks_channel', 
      'Daily Tasks', 
      channelDescription: 'Notifications for your scheduled tasks',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      fullScreenIntent: true, 
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails);

    
    
    await flutterLocalNotificationsPlugin.zonedSchedule(
      taskId.hashCode, 
      'تذكير بالمهمة',
      title,
      tzScheduledTime,
      notificationDetails,
      
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: taskId, 
    );
  }

  
  Future<void> cancelNotification(String taskId) async {
    await flutterLocalNotificationsPlugin.cancel(taskId.hashCode);
  }

  
  Future<void> cancelAll() async {
    await flutterLocalNotificationsPlugin.cancelAll();
  }
}