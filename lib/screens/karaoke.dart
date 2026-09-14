import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:karaoke_app/subtitle_model.dart';
import 'dart:async';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:karaoke_app/import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

class KaraokePlayerScreen extends StatefulWidget {
  final String videoId;
  final List<String> reviewedUids;
  final String sessionId;
  final List<Map<String, dynamic>> unseenWords;

  const KaraokePlayerScreen({
    super.key,
    required this.videoId,
    required this.reviewedUids,
    required this.sessionId,
    required this.unseenWords,
  });

  @override
  State<KaraokePlayerScreen> createState() => _KaraokePlayerScreenState();
}

class _KaraokePlayerScreenState extends State<KaraokePlayerScreen>
    with WidgetsBindingObserver {
  late YoutubePlayerController _controller;

  List<SubtitleLine> _subtitles = [];
  List<SubtitleLine> _visibleSubtitles = [];
  Timer? _syncTimer;
  int _syncRequestId = 0;

  late DateTime _segmentStartTime;
  int accumulatedMs = 0;

  bool _isVideoFinished = false;
  bool _isLoadingMemory = true;

  DateTime? _lastBackedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    debugPrint(widget.videoId);

    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: false,
      params: const YoutubePlayerParams(
        showControls: true,
        mute: false,
        showFullscreenButton: false,
        enableCaption: false,
        enableJavaScript: true,
        privacyEnhancedMode: true,
      ),
    );

    FirebaseFirestore.instance
        .collection("users")
        .doc(currentUsername)
        .collection("telemetry")
        .doc(widget.sessionId)
        .update({'karaoke_start_time': DateTime.now()})
        .catchError((e) => debugPrint("Telemetry start update failed: $e"));

    _controller.listen((event) async {
      if (event.playerState == PlayerState.ended && !_isVideoFinished) {
        if (mounted) {
          setState(() {
            _isVideoFinished = true;
          });
        }
      }

      if (event.hasError) {
        debugPrint("YouTube Player Error: ${event.error}");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "The karaoke player crashed for this song. Please contact the developers...",
              ),
              duration: Duration(seconds: 4),
            ),
          );

          SharedPreferences.getInstance().then((prefs) {
            prefs.remove('active_session_type');
            prefs.remove('active_video_id');
            prefs.remove('active_session_id');
            prefs.remove('active_reviewed_uids');
            prefs.remove('active_karaoke_dwell_time');
          });

          await checkAndNavigatePostTest(
            context,
            widget.videoId,
            widget.sessionId,
            widget.unseenWords,
          );
        }
      }
    });

    _fetchSubtitlesFromDatabase();
    _startSyncTimer();

    _segmentStartTime = DateTime.now();

    _loadRecoveredDwellTimes();
  }

  Future<void> _loadRecoveredDwellTimes() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionType = prefs.getString('active_session_type');
    final savedTime = prefs.getInt('active_karaoke_dwell_time');
    if (sessionType == 'karaoke' && savedTime != null) {
      accumulatedMs = savedTime;
    }

    if (mounted) setState(() => _isLoadingMemory = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _controller.pauseVideo();

      accumulatedMs += DateTime.now()
          .difference(_segmentStartTime)
          .inMilliseconds;
      _segmentStartTime = DateTime.now();

      _saveSessionState();
    } else if (state == AppLifecycleState.resumed) {
      _segmentStartTime = DateTime.now();
    }
  }

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_session_type', 'karaoke');
    await prefs.setString('active_video_id', widget.videoId);
    await prefs.setString('active_session_id', widget.sessionId);
    await prefs.setString(
      'active_reviewed_uids',
      jsonEncode(widget.reviewedUids),
    );
    await prefs.setString(
      'active_unseen_words',
      jsonEncode(widget.unseenWords),
    );
    await prefs.setInt('active_karaoke_dwell_time', accumulatedMs);
  }

  Future<void> _fetchSubtitlesFromDatabase() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('songs')
          .doc(widget.videoId)
          .get();
      if (!doc.exists) {
        debugPrint("Doc does not exist for videoId: ${widget.videoId}");
        return;
      }

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
        });
      }
    } catch (e) {
      debugPrint("FATAL Error fetching subtitles: $e");
    }
  }

  void _startSyncTimer() {
    _syncTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) async {
      int currentRequestId = ++_syncRequestId;

      try {
        double currentSeconds = await _controller.currentTime.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => -1.0,
        );

        if (currentSeconds < 0) return;
        if (currentRequestId != _syncRequestId) return;

        int currentMillis = (currentSeconds * 1000).toInt();

        const int fadeLeadTime = 500;
        const int fadeTrailTime = 300;

        List<SubtitleLine> activeSubs = [];

        for (var sub in _subtitles) {
          if (currentMillis >= (sub.startTimeMs - fadeLeadTime) &&
              currentMillis <= (sub.endTimeMs + fadeTrailTime)) {
            activeSubs.add(sub);
          }
        }

        bool changed =
            _visibleSubtitles.length != activeSubs.length ||
            !_visibleSubtitles.every((s) => activeSubs.contains(s));

        if (changed && mounted) {
          setState(() {
            _visibleSubtitles = activeSubs;
          });
        }
      } catch (e) {
        // Ignore iframe errors
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingMemory) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
          title: GestureDetector(
            onLongPress: () {
              if (!_isVideoFinished && mounted) {
                setState(() {
                  _isVideoFinished = true;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      "Manual override activated. You may finish the session.",
                    ),
                    backgroundColor: Colors.blueAccent,
                  ),
                );
              }
            },
            child: const Text('Karaoke Player'),
          ),
          centerTitle: true,
          automaticallyImplyLeading: false,
        ),
        body: Column(
          children: [
            YoutubePlayer(controller: _controller, aspectRatio: 16 / 9),

            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16.0),
                child: _subtitles.isEmpty
                    ? const Center(
                        child: Text(
                          "Loading lyrics from database...",
                          style: TextStyle(color: Colors.grey, fontSize: 18),
                        ),
                      )
                    : DualSlotLyricsDisplay(
                        visibleSubtitles: _visibleSubtitles,
                        allSubtitles: _subtitles,
                        reviewedUids: widget.reviewedUids,
                      ),
              ),
            ),

            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isVideoFinished
                        ? () async {
                            final batch = FirebaseFirestore.instance.batch();

                            accumulatedMs += DateTime.now()
                                .difference(_segmentStartTime)
                                .inMilliseconds;

                            final prefs = await SharedPreferences.getInstance();
                            await prefs.remove('active_session_type');
                            await prefs.remove('active_video_id');
                            await prefs.remove('active_session_id');
                            await prefs.remove('active_reviewed_uids');
                            await prefs.remove('active_unseen_words');

                            final telemetryRef = FirebaseFirestore.instance
                                .collection("users")
                                .doc(currentUsername)
                                .collection("telemetry")
                                .doc(widget.sessionId);

                            final playlistSongRef = FirebaseFirestore.instance
                                .collection("users")
                                .doc(currentUsername)
                                .collection("playlist")
                                .doc(widget.videoId);

                            final groupId = currentUsername.split('_').first;

                            batch.set(telemetryRef, {
                              'karaoke_end_time': DateTime.now(),
                              'karaoke_dwell_time_ms': accumulatedMs,
                              'karaoke_type': groupId == g2 ? "Regular" : "Augmented",
                            }, SetOptions(merge: true));

                            batch.set(playlistSongRef, {
                              'last_sung_date': DateTime.now(),
                              'times_sung': FieldValue.increment(1),
                            }, SetOptions(merge: true));

                            try {
                              await batch.commit();
                            } catch (e) {
                              debugPrint("Telemetry save failed: $e");
                            }

                            if (!context.mounted) return;

                            await checkAndNavigatePostTest(
                              context,
                              widget.videoId,
                              widget.sessionId,
                              widget.unseenWords,
                            );
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _isVideoFinished
                          ? "Finish Session"
                          : "Sing the whole song to finish!",
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DualSlotLyricsDisplay extends StatefulWidget {
  final List<SubtitleLine> visibleSubtitles;
  final List<SubtitleLine> allSubtitles;
  final List<String> reviewedUids;

  const DualSlotLyricsDisplay({
    super.key,
    required this.visibleSubtitles,
    required this.allSubtitles,
    required this.reviewedUids,
  });

  @override
  State<DualSlotLyricsDisplay> createState() => _DualSlotLyricsDisplayState();
}

class _DualSlotLyricsDisplayState extends State<DualSlotLyricsDisplay> {
  SubtitleLine? _topSub;
  SubtitleLine? _bottomSub;

  bool _topVisible = false;
  bool _bottomVisible = false;

  @override
  void initState() {
    super.initState();
    _updateSlots();
  }

  @override
  void didUpdateWidget(covariant DualSlotLyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSlots();
  }

  void _updateSlots() {
    bool foundTop = false;
    bool foundBottom = false;

    for (var sub in widget.visibleSubtitles) {
      int index = widget.allSubtitles.indexOf(sub);
      if (index % 2 == 0) {
        _topSub = sub;
        foundTop = true;
      } else {
        _bottomSub = sub;
        foundBottom = true;
      }
    }

    setState(() {
      _topVisible = foundTop;
      _bottomVisible = foundBottom;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start, // 1. Left-align the main slots
      children: [
        // Top Slot
        Expanded(
          child: AnimatedOpacity(
            opacity: _topVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 600),
            child: Align(
              alignment: Alignment.centerLeft, // Changed from bottomLeft
              child: _topSub != null
                  ? KaraokeLyricsDisplay(
                      subtitle: _topSub,
                      reviewedUids: widget.reviewedUids,
                    )
                  : const SizedBox(),
            ),
          ),
        ),

        // Separator
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24.0),
          child: Divider(
            color: Colors.white.withValues(alpha: 0.15),
            thickness: 1.5,
          ),
        ),

        // Bottom Slot
        Expanded(
          child: AnimatedOpacity(
            opacity: _bottomVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 600),
            child: Align(
              alignment: Alignment.centerLeft, // Changed from topLeft
              child: _bottomSub != null
                  ? KaraokeLyricsDisplay(
                      subtitle: _bottomSub,
                      reviewedUids: widget.reviewedUids,
                    )
                  : const SizedBox(),
            ),
          ),
        ),
      ],
    );
  }
}

class KaraokeLyricsDisplay extends StatelessWidget {
  final SubtitleLine? subtitle;
  final List<String> reviewedUids;

  const KaraokeLyricsDisplay({
    super.key,
    required this.subtitle,
    required this.reviewedUids,
  });

  List<List<Set<int>>> _combineBidirectionalOverlaps(
    List<String> rawAlignments,
  ) {
    Map<String, Set<String>> graph = {};
    Set<String> nodes = {};

    for (String a in rawAlignments) {
      if (a.isEmpty) continue;

      // --- NEW: THE ALIGNMENT FILTER ---
      // Expected format: "0-1:123456"
      List<String> uidSplit = a.split(':');
      if (uidSplit.length != 2) continue;

      String positions = uidSplit[0]; // "0-1"
      String uid = uidSplit[1]; // "123456"

      // Skip this alignment completely if the user hasn't studied it!
      if (!reviewedUids.contains(uid)) continue;
      // ---------------------------------

      List<String> parts = positions.split('-');
      if (parts.length == 2) {
        String sNode = 's_${parts[0]}';
        String tNode = 't_${parts[1]}';

        graph.putIfAbsent(sNode, () => {}).add(tNode);
        graph.putIfAbsent(tNode, () => {}).add(sNode);
        nodes.add(sNode);
        nodes.add(tNode);
      }
    }

    Set<String> visited = {};
    List<List<Set<int>>> groups = [];

    for (String node in nodes) {
      if (!visited.contains(node)) {
        Set<String> component = {};
        List<String> queue = [node];

        while (queue.isNotEmpty) {
          String curr = queue.removeAt(0);
          if (visited.contains(curr)) continue;

          visited.add(curr);
          component.add(curr);

          for (String neighbor in graph[curr] ?? []) {
            if (!visited.contains(neighbor)) {
              queue.add(neighbor);
            }
          }
        }

        Set<int> groupSources = {};
        Set<int> groupTargets = {};

        for (String n in component) {
          if (n.startsWith('s_')) {
            groupSources.add(int.parse(n.substring(2)));
          } else if (n.startsWith('t_')) {
            groupTargets.add(int.parse(n.substring(2)));
          }
        }

        groups.add([groupSources, groupTargets]);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (subtitle == null) {
      return const Text(
        '...',
        style: TextStyle(fontSize: 28, color: Colors.grey),
      );
    }

    List<String> jpWords = subtitle!.jp.split(' ');
    List<String> roWords = subtitle!.romaji.split(' ');
    List<String> enWords = subtitle!.en.split(' ');
    List<String> rawAlignments = subtitle!.alignments.split(' ');

    final groupId = currentUsername.split('_').first;
    Map<int, Color> jpColors = {};
    Map<int, Color> enColors = {};

    if (groupId != g2) {
      List<Color> highlightColors = [
        Colors.redAccent,
        Colors.lightBlueAccent,
        Colors.greenAccent,
        Colors.orangeAccent,
        Colors.purpleAccent,
        Colors.pinkAccent,
      ];

      List<List<Set<int>>> groupedAlignments = _combineBidirectionalOverlaps(
        rawAlignments,
      );

      for (int i = 0; i < groupedAlignments.length; i++) {
        Color assignedColor = highlightColors[i % highlightColors.length];
        for (int jpIdx in groupedAlignments[i][0]) {
          jpColors[jpIdx] = assignedColor;
        }
        for (int enIdx in groupedAlignments[i][1]) {
          enColors[enIdx] = assignedColor;
        }
      }
    }

    Widget jpRoSection;

    if (jpWords.length == roWords.length) {
      List<Widget> wordPairs = [];
      for (int i = 0; i < jpWords.length; i++) {
        bool isKeyWord = jpColors.containsKey(i);
        FontWeight dynamicWeight = isKeyWord
            ? FontWeight.bold
            : FontWeight.normal;

        wordPairs.add(
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.center, // Left-align stacked words
            children: [
              Text(
                jpWords[i],
                style: TextStyle(
                  color: jpColors[i] ?? Colors.white,
                  fontSize: 18,
                  fontWeight: dynamicWeight,
                  fontFamily: 'NotoSansJP',
                  height: 1.2, // Added line height
                ),
              ),
              Text(
                roWords[i],
                style: TextStyle(
                  color: jpColors[i] ?? Colors.white,
                  fontSize: 24,
                  fontWeight: dynamicWeight,
                  height: 1.2, // Added line height
                ),
              ),
            ],
          ),
        );
      }

      jpRoSection = Wrap(
        alignment: WrapAlignment.start, // Changed from center to left-aligned
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 14.0, // Increased horizontal breathing room
        runSpacing:
            6.0, // Increased vertical breathing room between wrapped lines
        children: wordPairs,
      );
    } else {
      List<TextSpan> jpSpans = [];
      List<TextSpan> roSpans = [];

      for (int i = 0; i < jpWords.length; i++) {
        bool isKeyWord = jpColors.containsKey(i);
        jpSpans.add(
          TextSpan(
            text: '${jpWords[i]} ',
            style: TextStyle(
              color: jpColors[i] ?? Colors.white,
              fontSize: 20,
              fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
              fontFamily: 'NotoSansJP',
              height: 1.2, // Added line height
            ),
          ),
        );
      }

      for (int i = 0; i < roWords.length; i++) {
        bool isKeyWord = jpColors.containsKey(i);
        roSpans.add(
          TextSpan(
            text: '${roWords[i]} ',
            style: TextStyle(
              color: jpColors[i] ?? Colors.white,
              fontSize: 28,
              fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
              height: 1.2, // Added line height
            ),
          ),
        );
      }

      jpRoSection = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.start, // Left-align RichText blocks
        children: [
          RichText(
            textAlign: TextAlign.left,
            text: TextSpan(children: jpSpans),
          ),
          const SizedBox(height: 2), // Replaced tight 4px spacing
          RichText(
            textAlign: TextAlign.left,
            text: TextSpan(children: roSpans),
          ),
        ],
      );
    }

    List<TextSpan> enSpans = [];
    for (int i = 0; i < enWords.length; i++) {
      bool isKeyWord = enColors.containsKey(i);
      enSpans.add(
        TextSpan(
          text: '${enWords[i]} ',
          style: TextStyle(
            color: enColors[i] ?? Colors.white70,
            fontSize: 22,
            fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
            height: 1.2, // Added line height
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),

              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  jpRoSection,
                  const SizedBox(height: 20),
                  RichText(
                    textAlign: TextAlign.left,
                    text: TextSpan(children: enSpans),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
