import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';

class PreFlightScreen extends StatefulWidget {
  final String videoId;
  final bool fromPlaylist;

  const PreFlightScreen({super.key, required this.videoId, required this.fromPlaylist});

  @override
  State<PreFlightScreen> createState() => _PreFlightScreenState();
}

class _PreFlightScreenState extends State<PreFlightScreen> {
  String _loadingText = "Analyzing song vocabulary...";

  @override
  void initState() {
    super.initState();
    _prepareSession();
  }

  Future<void> _prepareSession() async {
    final db = FirebaseFirestore.instance;

    try {
      final songDoc = await db.collection("songs").doc(widget.videoId).get();
      if (!songDoc.exists) throw Exception("Song data not found!");

      List<String> allSongVocab = List<String>.from(
        songDoc.data()?['vocab_list'] ?? [],
      );
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUsername)
          .get();
      final userData = userDoc.data() ?? {};

      // 1. Safely extract the timestamp
      final Timestamp? cutoffTimestamp = userData['cutoff_date'] as Timestamp?;

      final now = DateTime.now();

      // Check if it exists AND if the current time is past the cutoff
      if (cutoffTimestamp != null && now.isAfter(cutoffTimestamp.toDate())) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "The study period has ended, and access to this feature is no longer available. If you believe this is an error, please contact the developers.",
            ),
            duration: Duration(seconds: 4),
          ),
        );

        Navigator.pop(context);
        return;
      }

      if (allSongVocab.length < 5) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "For some reason, this song has too little vocabulary for study. Please contact the developers.",
            ),
            duration: Duration(seconds: 4),
          ),
        );

        Navigator.pop(context);
        return;
      }

      setState(() => _loadingText = "Fetching definitions...");

      final vocabQuery = await db
          .collection("vocabulary")
          .where(FieldPath.documentId, whereIn: allSongVocab)
          .get();

      final userHistoryQuery = await db
          .collection("users")
          .doc(currentUsername)
          .collection("wordlist")
          .where(FieldPath.documentId, whereIn: allSongVocab)
          .get();

      Set<String> seenUids = userHistoryQuery.docs.map((doc) => doc.id).toSet();

      List<Map<String, dynamic>> allWords = [];
      List<Map<String, dynamic>> unseenWords = [];

      for (var doc in vocabQuery.docs) {
        Map<String, dynamic> wordData = doc.data();
        wordData['uid'] = doc.id;

        allWords.add(wordData);

        if (!seenUids.contains(doc.id)) {
          unseenWords.add(wordData);
        }
      }

      if (!mounted) return;

      if (unseenWords.isNotEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PreTestScreen(
              videoId: widget.videoId,
              unseenWords: unseenWords,
              allWords: allWords,
              fromPlaylist: widget.fromPlaylist
            ),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => WordlistScreen(
              videoId: widget.videoId,
              allWords: allWords,
              unseenWords: const [],
              fromPlaylist: widget.fromPlaylist
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _loadingText = "Error preparing session: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _loadingText,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
