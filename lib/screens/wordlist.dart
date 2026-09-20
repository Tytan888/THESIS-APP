import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:karaoke_app/subtitle_model.dart'; // NEW: Required for SubtitleLine

class WordlistScreen extends StatefulWidget {
  final String videoId;
  final List<Map<String, dynamic>> allWords;
  final List<Map<String, dynamic>> unseenWords;
  final int recoveredIndex;

  const WordlistScreen({
    super.key,
    required this.videoId,
    required this.allWords,
    required this.unseenWords,
    this.recoveredIndex = 0,
  });

  @override
  State<WordlistScreen> createState() => _WordlistScreenState();
}

class _WordlistScreenState extends State<WordlistScreen>
    with WidgetsBindingObserver {
  late PageController _pageController = PageController();
  late int _currentIndex = 0;

  final Map<String, int> _cumulativeDwellTimeMs = {};
  late DateTime _segmentStartTime;
  late DateTime _studyStartTime;

  bool _isSaving = false;
  bool _isLoadingMemory = true;
  bool _isLoadingSubtitles = true; // NEW: Track subtitle loading
  DateTime? _lastBackedAt;

  List<SubtitleLine> _subtitles = []; // NEW: Store the fetched lyrics

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.recoveredIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _studyStartTime = DateTime.now();
    _segmentStartTime = DateTime.now();

    for (var word in widget.allWords) {
      _cumulativeDwellTimeMs[word['uid']] = 0;
    }
    _loadRecoveredDwellTimes();
    _fetchSubtitlesFromDatabase(); // NEW: Fetch the lyrics on load
  }

  // NEW: Fetch subtitles identical to how karaoke.dart does it
  Future<void> _fetchSubtitlesFromDatabase() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('songs')
          .doc(widget.videoId)
          .get();

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        final rawSubs = data['subtitles'] as List<dynamic>? ?? [];

        List<SubtitleLine> parsedSubs = rawSubs.map((s) {
          double safeParse(dynamic value) {
            if (value == null) return 0.0;
            if (value is num) return value.toDouble();
            if (value is String) return double.tryParse(value) ?? 0.0;
            return 0.0;
          }

          return SubtitleLine(
            jp: s['jp']?.toString() ?? '',
            en: s['en']?.toString() ?? '',
            romaji: s['romaji']?.toString() ?? '',
            alignments: s['alignments']?.toString() ?? '',
            startTimeMs: (safeParse(s['start_time'])).toInt(),
            endTimeMs: (safeParse(s['end_time'])).toInt(),
          );
        }).toList();

        if (mounted) {
          setState(() {
            _subtitles = parsedSubs;
            _isLoadingSubtitles = false;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching subtitles: $e");
      if (mounted) setState(() => _isLoadingSubtitles = false);
    }
  }

  Future<void> _loadRecoveredDwellTimes() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionType = prefs.getString('active_session_type');
    final savedTimes = prefs.getString('active_dwell_times');
    if (sessionType == 'wordlist' && savedTimes != null) {
      final Map<String, dynamic> decoded = jsonDecode(savedTimes);
      decoded.forEach((key, value) {
        _cumulativeDwellTimeMs[key] = value as int;
      });
    }

    if (mounted) setState(() => _isLoadingMemory = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _bankCurrentTime();
      _saveSessionState();
    } else if (state == AppLifecycleState.resumed) {
      _segmentStartTime = DateTime.now();
    }
  }

  void _bankCurrentTime() {
    final previousUid = widget.allWords[_currentIndex]['uid'];
    final timeSpent = DateTime.now()
        .difference(_segmentStartTime)
        .inMilliseconds;
    _cumulativeDwellTimeMs[previousUid] =
        (_cumulativeDwellTimeMs[previousUid] ?? 0) + timeSpent;

    _segmentStartTime = DateTime.now();
  }

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_session_type', 'wordlist');
    await prefs.setString('active_video_id', widget.videoId);
    await prefs.setInt('active_current_index', _currentIndex);
    await prefs.setString('active_all_words', jsonEncode(widget.allWords));
    await prefs.setString(
      'active_unseen_words',
      jsonEncode(widget.unseenWords),
    );
    await prefs.setString(
      'active_dwell_times',
      jsonEncode(_cumulativeDwellTimeMs),
    );
  }

  List<String> _getCleanForms(List<dynamic> rawForms) {
    if (rawForms.isEmpty) return [];
    List<String> cleanForms = [];
    for (var form in rawForms) {
      final infoList = form['info'] as List<dynamic>? ?? [];
      if (infoList.every((info) => info.toString().toLowerCase().contains('ateji'))) {
        cleanForms.add(form['text'].toString());
      }
    }
    if (cleanForms.isEmpty) {
      cleanForms = rawForms.map((f) => f['text'].toString()).toList();
    }
    return cleanForms.take(3).toList();
  }

  void _onPageChanged(int index) {
    _bankCurrentTime();
    setState(() => _currentIndex = index);
    _saveSessionState();
  }

  Future<void> _handleFinish() async {
    _bankCurrentTime();

    setState(() => _isSaving = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('active_session_type');
      await prefs.remove('active_video_id');
      await prefs.remove('active_current_index');
      await prefs.remove('active_all_words');
      await prefs.remove('active_unseen_words');
      await prefs.remove('active_dwell_times');

      final telemetryRef = FirebaseFirestore.instance
          .collection("users")
          .doc(currentUsername)
          .collection("telemetry")
          .doc();

      final String sessionId = telemetryRef.id;
      final DateTime studyEndTime = DateTime.now();

      Map<String, int> activeDwellTimes = {};
      _cumulativeDwellTimeMs.forEach((uid, timeMs) {
        if (timeMs > 0) {
          activeDwellTimes[uid] = timeMs;
        }
      });

      await telemetryRef.set({
        'session_id': sessionId,
        'video_id': widget.videoId,
        'study_start_time': _studyStartTime,
        'study_end_time': studyEndTime,
        'karaoke_start_time': null,
        'karaoke_end_time': null,
        'word_dwell_times_ms': activeDwellTimes,
        'karaoke_dwell_time_ms': null,
        'karaoke_type': null,
        'karaoke_aborted': null,
      });

      if (!mounted) return;

      final groupId = currentUsername.split('_').first;

      if (groupId == g1) {
        await checkAndNavigatePostTest(
          context,
          widget.videoId,
          sessionId,
          widget.unseenWords,
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => KaraokePlayerScreen(
              videoId: widget.videoId,
              reviewedUids: widget.allWords
                  .map((w) => w['uid'] as String)
                  .toList(),
              sessionId: sessionId,
              unseenWords: widget.unseenWords,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error saving session data: $e")));
    }
  }

  Widget _buildPosChips(List<String> posTags) {
    if (posTags.isEmpty) return const SizedBox();
    return Wrap(
      spacing: 6.0,
      runSpacing: 6.0,
      children: posTags
          .map(
            (pos) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                pos,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildNoteLine(String prefix, List<String> items) {
    if (items.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 2.0),
      child: Text(
        "$prefix: ${items.join(', ')}",
        style: TextStyle(
          fontSize: 13,
          color: Colors.white.withValues(alpha: 0.7),
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // NEW: Also check if subtitles are loading
    if (_isSaving || _isLoadingMemory || _isLoadingSubtitles) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isLastWord = _currentIndex == widget.allWords.length - 1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;

        final now = DateTime.now();
        final maxDuration = const Duration(seconds: 2);
        final isWarning =
            _lastBackedAt == null ||
            now.difference(_lastBackedAt!) > maxDuration;
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
          title: Text(
            "Vocabulary (${_currentIndex + 1} / ${widget.allWords.length})",
          ),
          automaticallyImplyLeading: false,
        ),
        body: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                itemCount: widget.allWords.length,
                itemBuilder: (context, index) {
                  final word = widget.allWords[index];

                  final rawWritings = word['writings'] as List<dynamic>? ?? [];
                  final rawReadings = word['readings'] as List<dynamic>? ?? [];

                  final validWritings = _getCleanForms(rawWritings);
                  final rawValidReadings = _getCleanForms(rawReadings);

                  Map<String, String> bestReadings = {};
                  for (String originalReading in rawValidReadings) {
                    String normalizedHiragana = katakanaToHiragana(
                      originalReading,
                    );
                    if (!bestReadings.containsKey(normalizedHiragana)) {
                      bestReadings[normalizedHiragana] = originalReading;
                    } else if (originalReading == normalizedHiragana) {
                      bestReadings[normalizedHiragana] = originalReading;
                    }
                  }
                  List<String> validReadings = bestReadings.values.toList();

                  final bool hasKanji = validWritings.isNotEmpty;
                  final primaryMain = hasKanji
                      ? validWritings.first
                      : (validReadings.isNotEmpty
                            ? validReadings.first
                            : "???");
                  final primarySub = hasKanji && validReadings.isNotEmpty
                      ? validReadings.first
                      : "";

                  final secondaryMains = hasKanji && validWritings.length > 1
                      ? validWritings.sublist(1).join(', ')
                      : "";
                  final secondarySubs = validReadings.length > 1
                      ? validReadings.sublist(1).join(', ')
                      : "";

                  final primaryRomaji = primarySub.isNotEmpty
                      ? kanaToRomaji(primarySub)
                      : kanaToRomaji(primaryMain);
                  final secondaryRomaji = secondarySubs.isNotEmpty
                      ? validReadings
                            .sublist(1)
                            .map((r) => kanaToRomaji(r))
                            .join(', ')
                      : "";

                  final allSenses = word['senses'] as List<dynamic>? ?? [];
                  final displaySenses = allSenses.take(3).toList();

                  // UPDATED: Extract line index from the appearing_in_songs map using the current videoId
                  SubtitleLine? contextLine;
                  final appearingInSongs =
                      word['appearing_in_songs'] as Map<String, dynamic>? ?? {};
                  final firstSeen =
                      appearingInSongs[widget.videoId] as String? ?? "";

                  if (firstSeen.isNotEmpty) {
                    final parts = firstSeen.split(':');
                    if (parts.isNotEmpty) {
                      final lineIndex = int.tryParse(parts[0]);
                      if (lineIndex != null &&
                          lineIndex >= 0 &&
                          lineIndex < _subtitles.length) {
                        contextLine = _subtitles[lineIndex];
                      }
                    }
                  }

                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          const SizedBox(height: 12),
                          Divider(
                            color: Colors.white.withValues(alpha: 0.1),
                            indent: 40,
                            endIndent: 40,
                          ),
                          const SizedBox(height: 12),

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
                                color: Colors.blueAccent.withValues(alpha: 0.6),
                              ),
                            ),
                        ],

                        if (primaryRomaji.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Divider(
                            color: Colors.white.withValues(alpha: 0.1),
                            indent: 40,
                            endIndent: 40,
                          ),
                          const SizedBox(height: 12),

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
                                color: Colors.greenAccent.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                        ],

                        const SizedBox(height: 40),

                        if (displaySenses.isNotEmpty) ...[
                          Text(
                            "Definitions",
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...displaySenses.asMap().entries.map((entry) {
                            int idx = entry.key;
                            Map<String, dynamic> sense = entry.value;

                            String rawMeaningText = sense['meanings'] ?? "";
                            List<String> meaningList = rawMeaningText
                                .split('; ')
                                .where((e) => e.isNotEmpty)
                                .toList();
                            String meaningText = meaningList.take(6).join('; ');

                            List<String> rawPos = List<String>.from(
                              sense['parts_of_speech'] ?? [],
                            );
                            List<String> cleanPos = simplifyPOS(rawPos);

                            List<String> misc = List<String>.from(
                              sense['misc_notes'] ?? [],
                            );
                            List<String> fields = List<String>.from(
                              sense['fields'] ?? [],
                            );
                            List<String> dialects = List<String>.from(
                              sense['dialects'] ?? [],
                            );
                            List<String> extraInfo = List<String>.from(
                              sense['extra_info'] ?? [],
                            );
                            List<String> antonyms = List<String>.from(
                              sense['antonyms'] ?? [],
                            );

                            return Card(
                              elevation: 0,
                              color: const Color(0xFF1E1E1E),
                              margin: const EdgeInsets.only(bottom: 12.0),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (cleanPos.isNotEmpty) ...[
                                      _buildPosChips(cleanPos),
                                      const SizedBox(height: 10),
                                    ],

                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "${idx + 1}. ",
                                          style: TextStyle(
                                            fontSize: 18,
                                            color: Colors.white.withValues(
                                              alpha: 0.3,
                                            ),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            meaningText,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 8),

                                    _buildNoteLine("Field", fields),
                                    _buildNoteLine("Dialect", dialects),
                                    _buildNoteLine("Antonyms", antonyms),
                                    _buildNoteLine("Note", misc),
                                    _buildNoteLine("Info", extraInfo),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],

                        // NEW: Lyric Context Block
                        if (contextLine != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            "In Context",
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            height:
                                160, // Fixed height prevents LayoutBuilder infinity crash
                            padding: const EdgeInsets.all(16.0),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: KaraokeLyricsDisplay(
                              subtitle: contextLine,
                              // Only pass THIS word's UID to uniquely highlight it
                              reviewedUids: [word['uid'] as String],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios),
                    onPressed: _currentIndex == 0
                        ? null
                        : () {
                            _pageController.previousPage(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                            );
                          },
                  ),

                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: isLastWord
                              ? Colors.green
                              : Colors.blueAccent,
                        ),
                        onPressed: isLastWord
                            ? _handleFinish
                            : () {
                                _pageController.nextPage(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                );
                              },
                        child: Text(
                          isLastWord ? "Start Karaoke!" : "Next Word",
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),

                  Opacity(
                    opacity: isLastWord ? 0.0 : 1.0,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_forward_ios),
                      onPressed: isLastWord
                          ? null
                          : () {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                              );
                            },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
