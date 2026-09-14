import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

class ImmediatePostTestScreen extends StatefulWidget {
  final String videoId;
  final String sessionId;
  final List<Map<String, dynamic>> unseenWords;
  final int recoveredIndex;

  const ImmediatePostTestScreen({
    super.key,
    required this.videoId,
    required this.sessionId,
    required this.unseenWords,
    this.recoveredIndex = 0,
  });

  @override
  State<ImmediatePostTestScreen> createState() => _ImmediatePostTestScreenState();
}

class _ImmediatePostTestScreenState extends State<ImmediatePostTestScreen>
    with WidgetsBindingObserver {
  late int _currentIndex;
  final TextEditingController _answerController = TextEditingController();

  final FocusNode _focusNode = FocusNode();

  late DateTime _segmentStartTime;
  int _accumulatedMs = 0;

  final List<Map<String, dynamic>> _testResults = [];
  bool _isSaving = false;
  bool _isLoadingMemory = true;

  DateTime? _lastBackedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _currentIndex = widget.recoveredIndex;
    _segmentStartTime = DateTime.now();

    _loadRecoveredResults();
  }

  Future<void> _loadRecoveredResults() async {
    final prefs = await SharedPreferences.getInstance();
    final savedResults = prefs.getString('active_test_results');
    _accumulatedMs = prefs.getInt('active_accumulated_ms') ?? 0;

    if (savedResults != null) {
      final List<dynamic> decoded = jsonDecode(savedResults);
      setState(() {
        _testResults.addAll(decoded.map((e) => e as Map<String, dynamic>));
      });
    }

    if (mounted) {
      setState(() => _isLoadingMemory = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _answerController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _accumulatedMs += DateTime.now().difference(_segmentStartTime).inMilliseconds;
      _segmentStartTime = DateTime.now();
      _saveSessionState();
    } else if (state == AppLifecycleState.resumed) {
      _segmentStartTime = DateTime.now();
    }
  }

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_session_type', 'immediate_post');
    await prefs.setString('active_video_id', widget.videoId);
    await prefs.setString('active_session_id', widget.sessionId);
    await prefs.setInt('active_current_index', _currentIndex);
    await prefs.setString('active_unseen_words', jsonEncode(widget.unseenWords));
    await prefs.setString('active_test_results', jsonEncode(_testResults));
    await prefs.setInt('active_accumulated_ms', _accumulatedMs);
  }

  Future<void> _handleNext({required bool recognized}) async {
    final currentSegmentMs = DateTime.now().difference(_segmentStartTime).inMilliseconds;
    final totalElapsedMs = _accumulatedMs + currentSegmentMs;
    final currentWord = widget.unseenWords[_currentIndex];
    final answer = _answerController.text.trim();

    // UPDATED: Saving to the immediate_post fields
    _testResults.add({
      'uid': currentWord['uid'],
      'immediate_post_recognition': recognized ? 'yes' : 'no',
      'immediate_post_guess': answer.isEmpty ? null : answer,
      'immediate_post_dwell_time_ms': totalElapsedMs,
    });

    if (_currentIndex < widget.unseenWords.length - 1) {
      _answerController.clear();
      setState(() {
        _currentIndex++;
        _accumulatedMs = 0;
        _segmentStartTime = DateTime.now();
      });

      _focusNode.requestFocus();
      _saveSessionState();
    } else {
      _focusNode.unfocus();
      await _saveAndNavigate();
    }
  }

  void _handleBack() {
    if (_currentIndex > 0) {
      setState(() {
        _testResults.removeLast(); // Remove the previous answer
        _currentIndex--;
        _answerController.clear();
        _accumulatedMs = 0; // Reset timer for the retried word
        _segmentStartTime = DateTime.now();
      });
      _saveSessionState();
    }
  }

  Future<void> _saveAndNavigate() async {
    setState(() => _isSaving = true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_session_type');
    await prefs.remove('active_video_id');
    await prefs.remove('active_session_id');
    await prefs.remove('active_current_index');
    await prefs.remove('active_unseen_words');
    await prefs.remove('active_test_results');
    await prefs.remove('active_accumulated_ms');

    try {
      final batch = FirebaseFirestore.instance.batch();
      final userDocRef = FirebaseFirestore.instance.collection('users').doc(currentUsername);
      final wordlistRef = userDocRef.collection('wordlist');

      // 1. Save the new test fields to the wordlist documents
      for (var result in _testResults) {
        result['immediate_post_tested_on'] = FieldValue.serverTimestamp();
        final docRef = wordlistRef.doc(result['uid']);
        batch.set(docRef, result, SetOptions(merge: true));
      }

      // 2. Fetch user doc to update the weekly_post_test array
      final userDoc = await userDocRef.get();
      if (userDoc.exists) {
        final data = userDoc.data() ?? {};
        List<dynamic> weeklyTests = List.from(data['weekly_post_test'] ?? []);
        final now = DateTime.now();

        // Find the active test and stamp it with the sessionId
        for (int i = 0; i < weeklyTests.length; i++) {
          final test = weeklyTests[i];
          final startDate = (test['start_date'] as Timestamp).toDate();
          final endDate = (test['end_date'] as Timestamp).toDate();
          final telemetryId = test['telemetry_id'] as String? ?? "";

          if (now.isAfter(startDate) && now.isBefore(endDate) && telemetryId.isEmpty) {
            weeklyTests[i]['telemetry_id'] = widget.sessionId;
            break; // Update only the active one
          }
        }
        
        // Push the modified array back to the user document
        batch.update(userDocRef, {'weekly_post_test': weeklyTests});
      }

      await batch.commit();

      if (!mounted) return;

      // Finish the session and return to StudyScreen
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const StudyScreen()),
        (route) => route.isFirst,
      );
    } catch (e) {
      setState(() => _isSaving = false);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error saving: $e")),
      );
    }
  }

  List<String> _getCleanForms(List<dynamic> rawForms) {
    if (rawForms.isEmpty) return [];
    List<String> cleanForms = [];
    for (var form in rawForms) {
      final infoList = form['info'] as List<dynamic>? ?? [];
      if (infoList.isEmpty) {
        cleanForms.add(form['text'].toString());
      }
    }
    if (cleanForms.isEmpty) {
      cleanForms = rawForms.map((f) => f['text'].toString()).toList();
    }
    return cleanForms.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_isSaving || _isLoadingMemory) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final word = widget.unseenWords[_currentIndex];

    final rawWritings = word['writings'] as List<dynamic>? ?? [];
    final rawReadings = word['readings'] as List<dynamic>? ?? [];

    final validWritings = _getCleanForms(rawWritings);
    final rawValidReadings = _getCleanForms(rawReadings);

    Map<String, String> bestReadings = {};

    for (String originalReading in rawValidReadings) {
      String normalizedHiragana = katakanaToHiragana(originalReading);
      if (!bestReadings.containsKey(normalizedHiragana)) {
        bestReadings[normalizedHiragana] = originalReading;
      } else {
        if (originalReading == normalizedHiragana) {
          bestReadings[normalizedHiragana] = originalReading;
        }
      }
    }

    List<String> validReadings = bestReadings.values.toList();

    final bool hasKanji = validWritings.isNotEmpty;
    final primaryMain = hasKanji ? validWritings.first : (validReadings.isNotEmpty ? validReadings.first : "???");
    final primarySub = hasKanji && validReadings.isNotEmpty ? validReadings.first : "";

    final secondaryMains = hasKanji && validWritings.length > 1 ? validWritings.sublist(1).join(', ') : "";
    final secondarySubs = validReadings.length > 1 ? validReadings.sublist(1).join(', ') : "";

    final primaryRomaji = primarySub.isNotEmpty ? kanaToRomaji(primarySub) : kanaToRomaji(primaryMain);
    final secondaryRomaji = secondarySubs.isNotEmpty ? validReadings.sublist(1).map((r) => kanaToRomaji(r)).join(', ') : "";

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        final now = DateTime.now();
        final maxDuration = const Duration(seconds: 2);
        final isWarning = _lastBackedAt == null || now.difference(_lastBackedAt!) > maxDuration;
        if (isWarning) {
          _lastBackedAt = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Press back again to exit the app."),
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text("Post-Test (${_currentIndex + 1} / ${widget.unseenWords.length})"),
          leading: _currentIndex > 0
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _handleBack,
                )
              : null,
          automaticallyImplyLeading: false,
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Do you remember this word?",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  color: Colors.grey,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          primaryMain,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (secondaryMains.isNotEmpty)
                          Text(
                            secondaryMains,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 20,
                              color: Colors.grey,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        if (primarySub.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Divider(
                            color: Colors.grey.withValues(alpha: 0.3),
                            indent: 40,
                            endIndent: 40,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            primarySub,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 28,
                              color: Colors.blueAccent,
                            ),
                          ),
                          if (secondarySubs.isNotEmpty)
                            Text(
                              secondarySubs,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.blueAccent.withValues(alpha: 0.8),
                              ),
                            ),
                        ],
                        if (primaryRomaji.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Divider(
                            color: Colors.grey.withValues(alpha: 0.3),
                            indent: 40,
                            endIndent: 40,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            primaryRomaji,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              color: Colors.greenAccent,
                            ),
                          ),
                          if (secondaryRomaji.isNotEmpty)
                            Text(
                              secondaryRomaji,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.greenAccent.withValues(alpha: 0.8),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              TextField(
                controller: _answerController,
                focusNode: _focusNode,
                autofocus: true,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: "Type meaning here...",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (text) => setState(() {}),
                onSubmitted: (_) {
                  if (_answerController.text.trim().isNotEmpty) {
                    _handleNext(recognized: true);
                  }
                },
              ),
              const SizedBox(height: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ).copyWith(
                      side: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.disabled)) return const BorderSide(color: Colors.grey);
                        return const BorderSide(color: Colors.blueAccent);
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.disabled)) return Colors.grey;
                        return Colors.blueAccent;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.disabled)) return Colors.grey.shade200;
                        return Colors.transparent;
                      }),
                    ),
                    onPressed: _answerController.text.trim().isEmpty
                        ? () => _handleNext(recognized: false)
                        : null,
                    child: const Text(
                      "Never seen/heard it.",
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.grey.shade300,
                      foregroundColor: Colors.black87,
                      elevation: 0,
                    ),
                    onPressed: () => _handleNext(recognized: true),
                    child: Text(
                      _answerController.text.trim().isEmpty
                          ? "Seen it, don't know meaning."
                          : "Submit Answer",
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}