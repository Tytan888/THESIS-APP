import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:karaoke_app/import.dart';
import 'package:karaoke_app/notifications.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

void main() async {
  // Ensure Flutter bindings are initialized before calling native code
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (!kIsWeb) {
    await NotificationService.init();
  }
  await NotificationService.setupInitialNotification();

  if (debugNotification) {
    await NotificationService.debugNotification();
  }

  runApp(const KaraokeApp());
}

class KaraokeApp extends StatefulWidget {
  const KaraokeApp({super.key});

  @override
  State<KaraokeApp> createState() => _KaraokeAppState();
}

class _KaraokeAppState extends State<KaraokeApp> {
  bool _isLoading = true;
  bool _hasUsername = false;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // 1. Check if Firebase Auth has an active session
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      // 2. If logged in, safely retrieve the username for your global variable
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? username = prefs.getString("username");

      setState(() {
        _hasUsername = username != null && username.isNotEmpty;
        if (_hasUsername) {
          currentUsername = username!;
        }
        _isLoading = false;
      });
    } else {
      // Not logged in via Firebase Auth
      setState(() {
        _hasUsername = false;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appTitle,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        fontFamily: 'NotoSonsJP',
      ),
      
      builder: (context, child) {
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance.collection('config').doc('app_status').snapshots(),
          builder: (context, snapshot) {
            bool isUnderMaintenance = false;
            String maintenanceMsg = 'Koe.ru is currently undergoing emergency maintenance. Please check back soon!';

            if (snapshot.hasData && snapshot.data!.exists) {
              final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
              isUnderMaintenance = data['maintenance'] ?? false;
              maintenanceMsg = data['message'] ?? maintenanceMsg;
            }

            // Use a Stack to keep the app alive in the background while blocking the UI
            return Stack(
              children: [
                // 1. The active app and its Navigator stay mounted
                child ?? const SizedBox(),
                
                // 2. The Maintenance Screen completely covers it and blocks interaction
                if (isUnderMaintenance)
                  Positioned.fill(
                    child: MaintenanceScreen(message: maintenanceMsg),
                  ),
              ],
            );
          },
        );
      },
      home: _isLoading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_hasUsername ? const MainMenuScreen() : const LoginScreen()),
    );
  }
}
