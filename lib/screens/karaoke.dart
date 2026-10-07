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
  final bool fromPlaylist;

  const KaraokePlayerScreen({
    super.key,
    required this.videoId,
    required this.reviewedUids,
    required this.sessionId,
    required this.unseenWords,
    required this.fromPlaylist,
  });

  @override
  State<KaraokePlayerScreen> createState() => _KaraokePlayerScreenState();
}

class _KaraokePlayerScreenState extends State<KaraokePlayerScreen>
    with WidgetsBindingObserver {
  late YoutubePlayerController _controller;
  final GlobalKey _youtubeKey = GlobalKey();

  List<SubtitleLine> _subtitles = [];
  List<SubtitleLine> _visibleSubtitles = [];
  Timer? _syncTimer;
  int _syncRequestId = 0;

  late DateTime _segmentStartTime;
  int accumulatedMs = 0;

  bool _isVideoFinished = false;
  bool _isLoadingMemory = true;
  bool _wasAborted = false;

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

    final telemetryRef = FirebaseFirestore.instance
        .collection("users")
        .doc(currentUsername)
        .collection("telemetry")
        .doc(widget.sessionId);

    telemetryRef
        .get()
        .then((snap) {
          final isFirstStart = snap.data()?['karaoke_start_time'] == null;
          return telemetryRef.update({
            if (isFirstStart) 'karaoke_start_time': DateTime.now(),
            if (!isFirstStart)
              'karaoke_resumed_at': FieldValue.arrayUnion([Timestamp.now()]),
            'karaoke_type': currentUsername.split('_').first == g2
                ? 'Regular'
                : 'Augmented',
          });
        })
        .catchError(
          (e) => logClientError(widget.sessionId, 'karaoke_start_update', e),
        );

    _controller.listen((event) async {
      if (event.playerState == PlayerState.ended && !_isVideoFinished) {
        if (mounted) {
          setState(() {
            _isVideoFinished = true;
          });
        }
      }

      if (event.hasError) {
        if (_isFinishing) return;
        _isFinishing = true;

        logClientError(widget.sessionId, 'player_error', event.error);

        FirebaseFirestore.instance
            .collection('users')
            .doc(currentUsername)
            .collection('telemetry')
            .doc(widget.sessionId)
            .set({
              'karaoke_end_time': DateTime.now(),
              'karaoke_exit_reason': 'player_error',
              'karaoke_dwell_time_ms':
                  accumulatedMs +
                  DateTime.now().difference(_segmentStartTime).inMilliseconds,
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 3))
            .catchError((_) {});
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
            prefs.remove('from_playlist');
            prefs.remove('active_unseen_words');
          });

          await checkAndNavigatePostTest(
            context,
            widget.videoId,
            widget.sessionId,
            widget.unseenWords,
            widget.fromPlaylist,
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

    await _saveSessionState();

    if (mounted) setState(() => _isLoadingMemory = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Removed the 'inactive' check to prevent iframe focus from killing the video
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
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

  bool _isFinishing = false;

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isFinishing) return;

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
    await prefs.setBool('from_playlist', widget.fromPlaylist);

    if (_isFinishing) return;
    await prefs.setString('active_session_type', 'karaoke');
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

      List<SubtitleLine> parsedSubs = rawSubs
          .map((s) {
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
          })
          .where(
            (sub) =>
                sub.jp.trim().isNotEmpty ||
                sub.romaji.trim().isNotEmpty ||
                sub.en.trim().isNotEmpty,
          )
          .toList();

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
      final state = await _controller.playerState;
      if (state != PlayerState.playing) return;

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

    final screenWidth = MediaQuery.of(context).size.width;
    final videoHeight = screenWidth / (16 / 9);

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
                setState(() {
                  _wasAborted = true;
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
            SizedBox(
              key:
                  _youtubeKey, // Locks the video in place to prevent the layout crash
              width: screenWidth,
              height: videoHeight,
              child: IgnorePointer(
                ignoring:
                    false, // Ensures the browser feels your physical touch
                child: YoutubePlayer(controller: _controller),
              ),
            ),

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
                            if (_isFinishing) return;
                            _isFinishing = true;

                            accumulatedMs += DateTime.now()
                                .difference(_segmentStartTime)
                                .inMilliseconds;
                            _segmentStartTime =
                                DateTime.now(); // so a retry doesn't double-count

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

                            // 1) Research data first, on its own
                            try {
                              await telemetryRef
                                  .set({
                                    'karaoke_end_time': DateTime.now(),
                                    'karaoke_dwell_time_ms': accumulatedMs,
                                    'karaoke_type': groupId == g2
                                        ? "Regular"
                                        : "Augmented",
                                    'karaoke_aborted': _wasAborted,
                                    'karaoke_exit_reason': _wasAborted
                                        ? 'manual_override'
                                        : 'finished',
                                  }, SetOptions(merge: true))
                                  .timeout(const Duration(seconds: 10));
                            } catch (e) {
                              logClientError(
                                widget.sessionId,
                                'finish_telemetry',
                                e,
                              );
                              _isFinishing = false;
                              if (context.mounted) {
                                final code = e is FirebaseException
                                    ? e.code
                                    : e.runtimeType.toString();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      "Couldn't save your session ($code). Check your connection and tap Finish again.",
                                    ),
                                    duration: const Duration(seconds: 6),
                                  ),
                                );
                              }
                              return;
                            }

                            // 3) Playlist bookkeeping is best-effort and can't take telemetry down with it
                            try {
                              await playlistSongRef
                                  .set({
                                    'last_sung_date': DateTime.now(),
                                    'times_sung': FieldValue.increment(1),
                                  }, SetOptions(merge: true))
                                  .timeout(const Duration(seconds: 10));
                            } catch (e) {
                              logClientError(
                                widget.sessionId,
                                'finish_playlist',
                                e,
                              );
                            }

                            final prefs = await SharedPreferences.getInstance();
                            await prefs.remove('active_session_type');
                            await prefs.remove('active_video_id');
                            await prefs.remove('active_session_id');
                            await prefs.remove('active_reviewed_uids');
                            await prefs.remove('active_unseen_words');
                            await prefs.remove('active_karaoke_dwell_time');
                            await prefs.remove('from_playlist');

                            if (!context.mounted) return;
                            await checkAndNavigatePostTest(
                              context,
                              widget.videoId,
                              widget.sessionId,
                              widget.unseenWords,
                              widget.fromPlaylist,
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
          padding: const EdgeInsets.symmetric(vertical: 12.0),
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
  final bool isContextMode;

  const KaraokeLyricsDisplay({
    super.key,
    required this.subtitle,
    required this.reviewedUids,
    this.isContextMode = false,
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

    if (groupId != g2 || isContextMode) {
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

    // Builds the lyric block at a given font scale. Called with a fixed
    // scale of 1.0 in Wordlist context mode, and with a *dynamically
    // shrinking* scale in Karaoke mode (see _ShrinkToFitLyrics below).
    // Because the words are re-wrapped at this scale rather than the whole
    // block being visually scaled down, every line keeps using the full
    // available width no matter how small the font ends up.
    Widget buildContent(double scale) {
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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  jpWords[i],
                  style: TextStyle(
                    color: jpColors[i] ?? Colors.white,
                    fontSize: 18 * scale,
                    fontWeight: dynamicWeight,
                    fontFamily: 'NotoSansJP',
                    height: 1.2,
                  ),
                ),
                Text(
                  roWords[i],
                  style: TextStyle(
                    color: jpColors[i] ?? Colors.white,
                    fontSize: 24 * scale,
                    fontWeight: dynamicWeight,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          );
        }

        jpRoSection = Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 14.0 * scale,
          runSpacing: 6.0 * scale,
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
                fontSize: 20 * scale,
                fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
                fontFamily: 'NotoSansJP',
                height: 1.2,
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
                fontSize: 28 * scale,
                fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
                height: 1.2,
              ),
            ),
          );
        }

        jpRoSection = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              textAlign: TextAlign.left,
              text: TextSpan(children: jpSpans),
            ),
            const SizedBox(height: 2),
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
              fontSize: 22 * scale,
              fontWeight: isKeyWord ? FontWeight.bold : FontWeight.normal,
              height: 1.2,
            ),
          ),
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: isContextMode
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          jpRoSection,
          SizedBox(height: 20 * scale),
          RichText(
            textAlign: TextAlign.left,
            text: TextSpan(children: enSpans),
          ),
        ],
      );
    }

    // If displayed in the Wordlist context, return content directly at
    // standard size (wraps naturally, no shrinking needed).
    if (isContextMode) {
      return buildContent(1.0);
    }

    // If displayed in the Karaoke Player: always wrap at the full
    // available width, and only shrink the font scale (never a visual
    // transform) if the wrapped text doesn't fit vertically. This keeps
    // every line using the full width instead of shrinking in from the
    // right whenever a line has a lot of words.
    return LayoutBuilder(
      builder: (context, constraints) {
        return _ShrinkToFitLyrics(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          measureKey: '${subtitle!.startTimeMs}_${subtitle!.jp}',
          maxScale: 1.4,
          minScale: 0.3,
          builder: buildContent,
        );
      },
    );
  }
}

// Finds the largest font scale (between [minScale] and [maxScale]) at which
// [builder]'s output, wrapped at [maxWidth], fits within [maxHeight] --
// by re-measuring and re-wrapping at each candidate scale rather than
// visually scaling the whole block. This is what keeps text using the
// full width even when it has to shrink to fit vertically.
class _ShrinkToFitLyrics extends StatefulWidget {
  final double maxWidth;
  final double maxHeight;
  final double maxScale;
  final double minScale;
  final Widget Function(double scale) builder;
  final Object measureKey;

  const _ShrinkToFitLyrics({
    required this.maxWidth,
    required this.maxHeight,
    required this.builder,
    required this.measureKey,
    this.maxScale = 1.4,
    this.minScale = 0.7,
  });

  @override
  State<_ShrinkToFitLyrics> createState() => _ShrinkToFitLyricsState();
}

class _ShrinkToFitLyricsState extends State<_ShrinkToFitLyrics> {
  final GlobalKey _measureKey = GlobalKey();
  double _scale = 0;
  double _low = 0;
  double _high = 0;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _startMeasuring();
  }

  @override
  void didUpdateWidget(covariant _ShrinkToFitLyrics old) {
    super.didUpdateWidget(old);
    if (old.measureKey != widget.measureKey ||
        old.maxWidth != widget.maxWidth ||
        old.maxHeight != widget.maxHeight) {
      _startMeasuring();
    }
  }

  void _startMeasuring() {
    _low = widget.minScale;
    _high = widget.maxScale;
    _settled = false;
    _scale = widget.maxScale;
    WidgetsBinding.instance.addPostFrameCallback((_) => _step());
  }

  void _step() {
    if (!mounted) return;
    final box = _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final fits = box.size.height <= widget.maxHeight;

    if ((_high - _low).abs() < 0.03) {
      setState(() {
        _scale = fits ? _scale : _low;
        _settled = true;
      });
      return;
    }

    if (fits) {
      _low = _scale;
    } else {
      _high = _scale;
    }

    setState(() => _scale = (_low + _high) / 2);
    WidgetsBinding.instance.addPostFrameCallback((_) => _step());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.maxWidth,
      height: widget.maxHeight,
      child: AnimatedOpacity(
        opacity: _settled ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 150),
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: widget.maxWidth,
          minHeight: 0,
          // Unbounded on purpose: this lets the child report its TRUE
          // natural height so _step() can tell whether it actually fits,
          // instead of having that height silently clamped to
          // widget.maxHeight by the SizedBox above (which was the bug —
          // it made `fits` always true and disabled shrinking entirely).
          maxHeight: double.infinity,
          child: KeyedSubtree(key: _measureKey, child: widget.builder(_scale)),
        ),
      ),
    );
  }
}
