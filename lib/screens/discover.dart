import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  bool _isLoading = true;
  List<SongResult> _discoverResults = [];

  @override
  void initState() {
    super.initState();
    _fetchCommunitySongs();
  }

  Future<void> _fetchCommunitySongs() async {
    try {
      final db = FirebaseFirestore.instance;

      // 1. Get the user's current playlist to filter out songs they already have
      final playlistSnap = await db
          .collection('users')
          .doc(currentUsername)
          .collection('playlist')
          .get();

      Set<String> userSongIds = playlistSnap.docs.map((doc) => doc.id).toSet();

      final globalSnap = await db
          .collection('songs')
          .where('status', isEqualTo: 'completed')
          .get();

      final candidates =
          globalSnap.docs.where((doc) => !userSongIds.contains(doc.id)).toList()
            ..shuffle();

      final results = candidates.take(50).map((doc) {
        final data = doc.data();
        return SongResult(
          id: doc.id,
          title: data['title'] ?? 'Unknown Title',
          artist: data['artist'] ?? 'Unknown Artist',
          duration: '',
          thumbnailUrl: "https://img.youtube.com/vi/${doc.id}/mqdefault.jpg",
          status: SongStatus.readyToAdd,
        );
      }).toList();

      if (mounted) {
        setState(() {
          _discoverResults = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error loading songs: $e")));
      }
    }
  }

  void _handleSongAction(SongResult song) async {
    if (song.status == SongStatus.readyToAdd) {
      final userPlaylistRef = FirebaseFirestore.instance
          .collection('users')
          .doc(currentUsername)
          .collection('playlist')
          .doc(song.id);

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
    } else if (song.status == SongStatus.added) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("\"${song.title}\" is already in your playlist!"),
        ),
      );
    }
  }

  Widget _buildStatusIcon(SongStatus status) {
    if (status == SongStatus.added) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    return const Icon(Icons.add_circle_outline, color: Colors.blueAccent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Discover")),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _discoverResults.isEmpty
          ? const Center(child: Text("No new songs to discover yet!"))
          : ListView.builder(
              itemCount: _discoverResults.length,
              itemBuilder: (context, index) {
                final song = _discoverResults[index];
                return _buildResultTile(song);
              },
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
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 68,
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Center(child: _buildStatusIcon(song.status)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
