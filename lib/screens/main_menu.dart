import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:karaoke_app/import.dart';
import 'package:karaoke_app/notifications.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForActiveSession();
    });
  }

  Future<void> _checkForActiveSession() async {
    final prefs = await SharedPreferences.getInstance();
    final String? sessionType = prefs.getString('active_session_type');

    // If no session exists, do nothing and let them use the menu normally.
    if (sessionType == null) return;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Session Interrupted"),
        content: const Text(
          "You have an unfinished study session. Let's pick up where you left off!",
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _resumeSession(prefs, sessionType);
            },
            child: const Text("Resume Session"),
          ),
        ],
      ),
    );
  }

  void _resumeSession(SharedPreferences prefs, String sessionType) {
    // Extract the base data every session needs
    final String videoId = prefs.getString('active_video_id') ?? '';
    final String sessionId = prefs.getString('active_session_id') ?? '';

    if (sessionType == 'pre_test') {
      final unseenWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_unseen_words') ?? '[]'),
      );
      final allWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_all_words') ?? '[]'),
      );
      final startIndex = prefs.getInt('active_current_index') ?? 0;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PreTestScreen(
            videoId: videoId,
            unseenWords: unseenWords,
            allWords: allWords,
            recoveredIndex:
                startIndex, // We will add this parameter to PreTest next!
          ),
        ),
      );
    } else if (sessionType == 'wordlist') {
      final allWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_all_words') ?? '[]'),
      );
      final unseenWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_unseen_words') ?? '[]'),
      );
      final startIndex = prefs.getInt('active_current_index') ?? 0;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WordlistScreen(
            videoId: videoId,
            allWords: allWords,
            recoveredIndex:
                startIndex, // We will add this parameter to Wordlist next!
            unseenWords: unseenWords,
          ),
        ),
      );
    } else if (sessionType == 'karaoke') {
      final reviewedUids = List<String>.from(
        jsonDecode(prefs.getString('active_reviewed_uids') ?? '[]'),
      );
      final unseenWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_unseen_words') ?? '[]'),
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => KaraokePlayerScreen(
            videoId: videoId,
            reviewedUids: reviewedUids,
            sessionId: sessionId,
            unseenWords: unseenWords,
          ),
        ),
      );
    } else if (sessionType == 'immediate_post') {
      final unseenWords = List<Map<String, dynamic>>.from(
        jsonDecode(prefs.getString('active_unseen_words') ?? '[]'),
      );
      final startIndex = prefs.getInt('active_current_index') ?? 0;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ImmediatePostTestScreen(
            videoId: videoId,
            sessionId: sessionId,
            unseenWords: unseenWords,
            recoveredIndex: startIndex,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final parts = currentUsername.split('_');
    final groupId = parts.first;
    final username = parts.skip(1).join('_');

    final usernameColor = switch (groupId) {
      'midori' => Colors.green,
      'aoi' => Colors.blue,
      'aka' => const Color(0xFFE76F51),
      _ => Colors.grey,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text(appTitle),
        centerTitle: true,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: _showNotificationSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text.rich(
              TextSpan(
                text: username.isEmpty ? 'Welcome back!' : 'Welcome back, ',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
                children: username.isEmpty
                    ? []
                    : [
                        TextSpan(
                          text: '$username!',
                          style: TextStyle(color: usernameColor),
                        ),
                      ],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            // Button 1: Add/Search Songs
            _buildMenuButton(
              context: context,
              label: "Search & Add Songs",
              icon: Icons.search,
              color: Colors.blueAccent,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SearchScreen()),
                );
              },
            ),
            
            const SizedBox(height: 20), // Space between buttons
            _buildMenuButton(
              context: context,
              label: "See What Others Are Learning",
              icon: Icons.explore,
              color: Colors.teal,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const DiscoverScreen()),
                );
              },
            ),
            const SizedBox(height: 20),
            // Button 2: Playlist
            _buildMenuButton(
              context: context,
              label: "Your Playlist",
              icon: Icons.library_music,
              color: Colors.greenAccent,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PlaylistScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),

            // Button 3: Learn / Flashcards
            _buildMenuButton(
              context: context,
              label: "Start Learning",
              icon: Icons.school,
              color: Colors.purpleAccent,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const StudyScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 20.0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 28),
      label: Text(
        label,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _showNotificationSettings() async {
    final prefs = await SharedPreferences.getInstance();

    // Load current settings (Default: Enabled, 8:00 PM)
    bool isEnabled = prefs.getBool('notifications_enabled') ?? true;
    int hour = prefs.getInt('notification_hour') ?? 20;
    int minute = prefs.getInt('notification_minute') ?? 0;
    TimeOfDay selectedTime = TimeOfDay(hour: hour, minute: minute);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        // Use StatefulBuilder so the dialog can update its own UI (like the Switch)
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Notification Settings"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text("Daily Reminder"),
                    value: isEnabled,
                    onChanged: (bool value) {
                      setStateDialog(() {
                        isEnabled = value;
                      });
                    },
                  ),
                  ListTile(
                    enabled: isEnabled,
                    title: const Text("Reminder Time"),

                    trailing: Text(
                      selectedTime.format(context),
                      style: TextStyle(
                        color: isEnabled ? null : Colors.grey.shade600,
                      ),
                    ),

                    onTap: isEnabled
                        ? () async {
                            final TimeOfDay? picked = await showTimePicker(
                              context: context,
                              initialTime: selectedTime,
                            );
                            if (picked != null && picked != selectedTime) {
                              setStateDialog(() {
                                selectedTime = picked;
                              });
                            }
                          }
                        : null,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await prefs.setBool('notifications_enabled', isEnabled);
                    await prefs.setInt('notification_hour', selectedTime.hour);
                    await prefs.setInt(
                      'notification_minute',
                      selectedTime.minute,
                    );

                    if (isEnabled) {
                      await NotificationService.scheduleDailyReminder(
                        selectedTime,
                      );
                    } else {
                      await NotificationService.cancelAll();
                    }

                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
