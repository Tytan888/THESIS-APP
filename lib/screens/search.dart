import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Provides kIsWeb and kDebugMode
import 'package:flutter/material.dart';
import 'package:dart_ytmusic_api/yt_music.dart';
import 'package:http/http.dart' as http;

import 'package:karaoke_app/import.dart';

enum SongStatus { added, readyToAdd, needsProcessing, processing, error }

class SongResult {
  final String id;
  final String title;
  final String artist;
  final String duration;
  final String thumbnailUrl;
  SongStatus status;
  int processingStage;
  String processingMsg;
  String errorCode;

  SongResult({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.thumbnailUrl,
    required this.status,
    this.processingStage = 0,
    this.processingMsg = 'Song is still processing. Hang tight!',
    this.errorCode = 'ERR_DEFAULT',
  });
}

// Helper class to unify results between web (JSON) and native (YTMusic model)
class _RawSongItem {
  final String videoId;
  final String name;
  final String artistName;
  final int duration;

  _RawSongItem({
    required this.videoId,
    required this.name,
    required this.artistName,
    required this.duration,
  });
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  List<SongResult> _searchResults = [];

  final YTMusic _ytMusic = YTMusic();
  bool _isApiReady = false;

  final Map<String, StreamSubscription> _songSubscriptions = {};
  final Map<String, StreamSubscription> _progressSubscriptions = {};

  // Replace with your actual deployed URL
  static const String _prodFunctionUrl =
      'https://search-songs-jf3iz2l54a-uc.a.run.app/searchSongs';
  static const String _localFunctionUrl =
      'https://search-songs-jf3iz2l54a-uc.a.run.app/searchSongs';
      //'http://127.0.0.1:5001/tyra-thesis-2/us-central1/searchSongs';

  @override
  void initState() {
    super.initState();
    _setupApi();
  }

  Future<void> _setupApi() async {
    // If running on web, we do not need to initialize YTMusic locally
    if (kIsWeb) {
      setState(() => _isApiReady = true);
      return;
    }

    try {
      await _ytMusic.initialize();
      setState(() => _isApiReady = true);
    } catch (e) {
      debugPrint("Failed to initialize YT Music API: $e");
    }
  }

  @override
  void dispose() {
    for (var sub in _songSubscriptions.values) {
      sub.cancel();
    }
    for (var sub in _progressSubscriptions.values) {
      sub.cancel();
    }
    _searchController.dispose();
    super.dispose();
  }

  void _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || !_isApiReady) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _isSearching = true;
      _searchResults.clear();
    });

    try {
      List<_RawSongItem> rawResults = [];

      if (kIsWeb) {
        // --- Web workaround via Firebase Function ---
        final baseUrl = kDebugMode ? _localFunctionUrl : _prodFunctionUrl;
        final uri = Uri.parse('$baseUrl?q=${Uri.encodeComponent(query)}');

        final response = await http.get(uri);
        if (response.statusCode != 200) {
          throw Exception("Backend search failed (${response.statusCode}): ${response.body}");
        }

        final Map<String, dynamic> jsonBody = jsonDecode(response.body);
        final List<dynamic> songsJson = jsonBody['data'] ?? [];

        rawResults = songsJson.map((item) {
          return _RawSongItem(
            videoId: item['videoId'] ?? '',
            name: item['title'] ?? '',
            artistName: item['artist'] ?? '',
            duration: item['duration'] ?? 0,
          );
        }).toList();
      } else {
        // --- Native direct search ---
        final results = await _ytMusic.searchSongs(query);
        rawResults = results.take(10).map((item) {
          return _RawSongItem(
            videoId: item.videoId,
            name: item.name,
            artistName: item.artist.name,
            duration: item.duration ?? 0,
          );
        }).toList();
      }

      if (rawResults.isEmpty) {
        setState(() => _isSearching = false);
        return;
      }

      List<String> videoIds = rawResults.map((r) => r.videoId).toList();

      final globalSongsSnapshot = await FirebaseFirestore.instance
          .collection('songs')
          .where(FieldPath.documentId, whereIn: videoIds)
          .get();

      Map<String, String> globalStatusMap = {};
      Map<String, int> globalStageMap = {};
      Map<String, String> globalMsgMap = {};
      Map<String, String> globalErrorMap = {};

      for (var doc in globalSongsSnapshot.docs) {
        final data = doc.data();
        globalStatusMap[doc.id] = data['status'] ?? 'needsProcessing';
        globalStageMap[doc.id] = data['processing_stage'] ?? 0;
        globalMsgMap[doc.id] = data['processing_msg'] ?? '';
        globalErrorMap[doc.id] = data['error_code'] ?? 'ERR_DEFAULT';
      }

      final userPlaylistSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUsername)
          .collection('playlist')
          .where(FieldPath.documentId, whereIn: videoIds)
          .get();

      Set<String> userPlaylistIds = {};
      for (var doc in userPlaylistSnapshot.docs) {
        userPlaylistIds.add(doc.id);
      }

      List<SongResult> newResults = [];

      for (var item in rawResults) {
        final String videoId = item.videoId;
        final String songName = item.name;
        final String artistName = item.artistName;

        final int songDurationInt = item.duration;
        final String songDuration =
            "${songDurationInt ~/ 60}:${(songDurationInt % 60).toString().padLeft(2, '0')}";

        final String thumb = videoId.isNotEmpty
            ? "https://img.youtube.com/vi/$videoId/mqdefault.jpg"
            : "https://picsum.photos/seed/music/160/90";

        SongStatus finalStatus;
        String? gStatus = globalStatusMap[videoId];

        if (gStatus == 'processing') {
          finalStatus = SongStatus.processing;
        } else if (gStatus == 'error') {
          finalStatus = SongStatus.error;
        } else if (gStatus == 'completed') {
          if (userPlaylistIds.contains(videoId)) {
            finalStatus = SongStatus.added;
          } else {
            finalStatus = SongStatus.readyToAdd;
          }
        } else {
          finalStatus = SongStatus.needsProcessing;
        }

        newResults.add(
          SongResult(
            id: videoId,
            title: songName,
            artist: artistName,
            duration: songDuration,
            thumbnailUrl: thumb,
            status: finalStatus,
            processingStage: globalStageMap[videoId] ?? 0,
            processingMsg: globalMsgMap[videoId] ?? '',
            errorCode: globalErrorMap[videoId] ?? 'ERR_DEFAULT',
          ),
        );
      }

      if (!mounted) return;

      for (var sub in _songSubscriptions.values) {
        sub.cancel();
      }
      _songSubscriptions.clear();

      for (int i = 0; i < newResults.length; i++) {
        if (newResults[i].status == SongStatus.processing) {
          _listenToSongProgress(newResults[i].id, i);
        }
      }

      setState(() {
        _searchResults = newResults;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error searching YT Music: $e")));
    }
  }

  void _listenToSongProgress(String videoId, int index) {
    _songSubscriptions[videoId]?.cancel();

    _songSubscriptions[videoId] = FirebaseFirestore.instance
        .collection('songs')
        .doc(videoId)
        .snapshots()
        .listen((songSnapshot) async {
          if (!mounted) return;

          if (songSnapshot.exists) {
            final songData = songSnapshot.data() ?? {};
            final String statusStr = songData['status'] ?? '';

            if (statusStr == 'completed') {
              final playlistDoc = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUsername)
                  .collection('playlist')
                  .doc(videoId)
                  .get();

              if (!mounted) return;

              setState(() {
                _searchResults[index].status = playlistDoc.exists
                    ? SongStatus.added
                    : SongStatus.readyToAdd;
              });

              _progressSubscriptions[videoId]?.cancel();
              return;
            }

            SongStatus currentStatus = SongStatus.needsProcessing;
            if (statusStr == 'error') {
              currentStatus = SongStatus.error;
            }

            if (statusStr == 'processing') {
              currentStatus = SongStatus.processing;

              _progressSubscriptions[videoId]?.cancel();
              _progressSubscriptions[videoId] = FirebaseFirestore.instance
                  .collection('songs')
                  .doc(videoId)
                  .collection('progress')
                  .doc('status')
                  .snapshots()
                  .listen((progressSnapshot) {
                    if (!mounted) return;

                    if (progressSnapshot.exists) {
                      final progressData = progressSnapshot.data() ?? {};
                      setState(() {
                        _searchResults[index].processingStage =
                            progressData['processing_stage'] ?? 0;
                        _searchResults[index].processingMsg =
                            progressData['processing_msg'] ?? 'Processing...';
                      });
                    }
                  });
            } else {
              _progressSubscriptions[videoId]?.cancel();
            }

            setState(() {
              _searchResults[index].status = currentStatus;
            });

            if (statusStr == 'error') {
              setState(() {
                _searchResults[index].errorCode = songData["error_code"];
              });
            }
          }
        });
  }

  void _handleSongAction(SongResult song) async {
    if (song.status == SongStatus.added) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("\"${song.title}\" is already in your playlist!"),
        ),
      );
      return;
    }

    if (song.status == SongStatus.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            song.errorCode.isNotEmpty
                ? errorMessages[song.errorCode] ?? 'An unexpected issue occurred. Please contact the developers.'
                : 'An unexpected issue occurred. Please contact the developers.',
          ),
        ),
      );
      return;
    }

    if (song.status == SongStatus.processing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            song.processingMsg.isNotEmpty
                ? song.processingMsg
                : "Song is still processing. Hang tight!",
          ),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }

    final userPlaylistRef = FirebaseFirestore.instance
        .collection('users')
        .doc(currentUsername)
        .collection('playlist')
        .doc(song.id);

    if (song.status == SongStatus.needsProcessing) {
      final db = FirebaseFirestore.instance;

      final userRef = db.collection("users").doc(currentUsername);

      final today = DateTime.now();
      final todayKey = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      final userSnapshot = await userRef.get();
      final userData = userSnapshot.data() ?? {};

      final Map<String, dynamic> dailyRequests = Map<String, dynamic>.from(userData['daily_requests'] ?? {});
      final int requestsToday = dailyRequests[todayKey] ?? 0;

      if (requestsToday >= dailyRequestLimit) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "You have reached your daily song processing limit. Please contact the developers if you want to request more...",
            ),
          ),
        );

        return;
      }

      dailyRequests[todayKey] = requestsToday + 1;

      final batch = db.batch();

      final songRef = db.collection('songs').doc(song.id);
      final progressRef = songRef.collection('progress').doc('status');
      final userPlaylistRef = db
          .collection('users')
          .doc(currentUsername)
          .collection('playlist')
          .doc(song.id);

      batch.set(songRef, {
        'title': song.title,
        'artist': song.artist,
        'status': 'processing',
        'requested_by': FieldValue.arrayUnion([currentUsername]),
      }, SetOptions(merge: true));

      batch.set(progressRef, {
        'processing_stage': 1,
        'processing_msg': 'Just received your song...',
      }, SetOptions(merge: true));

      batch.set(userPlaylistRef, {
        'date_added': FieldValue.serverTimestamp(),
        'last_sung_date': null,
        'times_sung': 0,
      }, SetOptions(merge: true));

      batch.set(
        userRef,
        {
          'daily_requests': dailyRequests,
        },
        SetOptions(merge: true),
      );

      await batch.commit();

      setState(() => song.status = SongStatus.processing);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Added to queue! You can track its status in your Playlist.",
          ),
        ),
      );

      int songIndex = _searchResults.indexOf(song);
      if (songIndex != -1) {
        _listenToSongProgress(song.id, songIndex);
      }
    } else if (song.status == SongStatus.readyToAdd) {
      await userPlaylistRef.set({
        'date_added': FieldValue.serverTimestamp(),
        'last_sung_date': null,
        'times_sung': 0,
      });

      setState(() => song.status = SongStatus.added);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("\"${song.title}\" added to playlist!")),
      );
    }
  }

  Widget _buildStatusIcon(SongStatus status, int stage) {
    switch (status) {
      case SongStatus.added:
        return const Icon(Icons.check_circle, color: Colors.green);
      case SongStatus.readyToAdd:
        return const Icon(Icons.add_circle_outline, color: Colors.blueAccent);
      case SongStatus.needsProcessing:
        return const Icon(
          Icons.cloud_download_outlined,
          color: Colors.orangeAccent,
        );
      case SongStatus.processing:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: stage > 0 ? stage / 12.0 : null,
          ),
        );
      case SongStatus.error:
        return const Icon(Icons.error_outline, color: Colors.redAccent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Search Songs")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: "Search using song or artist name...",
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _performSearch,
                ),
              ),
              onSubmitted: (_) => _performSearch(),
            ),
          ),
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : _searchResults.isEmpty
                ? const Center(child: Text("No results yet. Try searching!"))
                : ListView.builder(
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final song = _searchResults[index];
                      return _buildResultTile(song);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(SongResult song) {
    return InkWell(
      onTap: () => _handleSongAction(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    song.thumbnailUrl,
                    width: 120,
                    height: 68,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 120,
                      height: 68,
                      color: Colors.grey,
                      child: const Icon(Icons.music_note),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      song.duration,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 68,
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Center(
                  child: _buildStatusIcon(song.status, song.processingStage),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}