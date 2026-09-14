import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:flutter_timezone/flutter_timezone.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    tz.initializeTimeZones();

    final TimezoneInfo currentTimeZone =
        await FlutterTimezone.getLocalTimezone();

    tz.setLocalLocation(tz.getLocation(currentTimeZone.identifier));

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@drawable/app_icon');
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(settings);
  }

  static Future<void> scheduleDailyReminder(TimeOfDay time) async {
    await _notificationsPlugin.cancelAll();

    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    scheduledDate = scheduledDate.add(const Duration(days: 1));

    await _notificationsPlugin.zonedSchedule(
      0,
      'Time to Practice!',
      "You haven't opened the app yet. Jump in before the day ends!",
      scheduledDate,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_reminder_channel_v3',
          'Daily Reminders',
          importance: Importance.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  static Future<void> cancelAll() async {
    await _notificationsPlugin.cancelAll();
  }

  static Future<void> debugNotification() async {
    await _notificationsPlugin.show(
      999,
      'Debug Notification',
      'Notifications are working!',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'debug_channel',
          'Debug Notifications',
          importance: Importance.high,
        ),
      ),
    );
  }

  static Future<void> setupInitialNotification() async {
    await requestPermissions();

    final prefs = await SharedPreferences.getInstance();

    bool isEnabled = prefs.getBool('notifications_enabled') ?? true;
    if (!isEnabled) {
      await cancelAll();
      return;
    }

    int hour = prefs.getInt('notification_hour') ?? 20;
    int minute = prefs.getInt('notification_minute') ?? 0;

    await scheduleDailyReminder(TimeOfDay(hour: hour, minute: minute));
  }

  static Future<void> requestPermissions() async {
    if (Platform.isIOS) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();

      await androidImplementation?.requestNotificationsPermission();
      await androidImplementation?.requestExactAlarmsPermission();
    }
  }
}
