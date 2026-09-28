import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart'; // Make sure this exports your search screen if needed!

class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  // Helper function to find exactly 5 completed songs based on the sorted playlist order
  Future<List<String>> _getTop5CompletedSongs(List<String> sortedIds) async {
    List<String> validSongs = [];

    // Firestore 'whereIn' queries only support up to 10 items at a time
    for (int i = 0; i < sortedIds.length; i += 10) {
      int end = (i + 10 < sortedIds.length) ? i + 10 : sortedIds.length;
      List<String> chunk = sortedIds.sublist(i, end);

      final snapshot = await FirebaseFirestore.instance
          .collection('songs')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      // Create a map to easily check the status of the songs we just fetched
      final chunkData = {for (var doc in snapshot.docs) doc.id: doc.data()};

      // Iterate in the original SORTED order to maintain your recommendation logic
      for (String id in chunk) {
        if (chunkData.containsKey(id) &&
            chunkData[id]!['status'] == 'completed') {
          validSongs.add(id);
          // Stop immediately once we have exactly 5!
          if (validSongs.length == 5) return validSongs;
        }
      }
    }
    return validSongs;
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.queue_music, size: 80, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              "Nothing to study yet!",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Add some songs to your playlist first to start generating vocabulary study sessions.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const SearchScreen()),
                );
              },
              icon: const Icon(Icons.search),
              label: const Text("Find Songs"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Study Hub"), centerTitle: true),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("users")
            .doc(currentUsername)
            .collection("playlist")
            .snapshots(),
        builder: (context, playlistSnapshot) {
          if (playlistSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (playlistSnapshot.hasError) {
            return Center(child: Text("Error: ${playlistSnapshot.error}"));
          }
          if (!playlistSnapshot.hasData ||
              playlistSnapshot.data!.docs.isEmpty) {
            return _buildEmptyState(context);
          }

          // 1. Sort the playlist exactly as you were doing before
          List<QueryDocumentSnapshot> playlist = playlistSnapshot.data!.docs
              .toList();
          playlist.sort((a, b) {
            final dataA = a.data() as Map<String, dynamic>;
            final dataB = b.data() as Map<String, dynamic>;

            Timestamp? lastSungA = dataA['last_sung_date'];
            Timestamp? lastSungB = dataB['last_sung_date'];

            if (lastSungA == null && lastSungB == null) {
              Timestamp addedA = dataA['date_added'] ?? Timestamp.now();
              Timestamp addedB = dataB['date_added'] ?? Timestamp.now();
              return addedA.compareTo(addedB);
            }

            if (lastSungA == null) return -1;
            if (lastSungB == null) return 1;

            return lastSungA.compareTo(lastSungB);
          });

          // Extract just the ordered IDs
          List<String> sortedIds = playlist.map((doc) => doc.id).toList();

          // 2. Pass the sorted IDs into our new Future to filter out processing/missing songs
          return FutureBuilder<List<String>>(
            future: _getTop5CompletedSongs(sortedIds),
            builder: (context, completedSongsSnapshot) {
              if (completedSongsSnapshot.connectionState ==
                  ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final validVideoIds = completedSongsSnapshot.data ?? [];

              if (validVideoIds.isEmpty) {
                return const Center(
                  child: Text(
                    "All your songs are still processing! Check back soon.",
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Recommended for Review",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "These songs haven't been practiced in a while. Select one to start your session!",
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: validVideoIds.length,
                        itemBuilder: (context, index) {
                          // Pass the guaranteed valid ID to your tile
                          return _StudySongTile(videoId: validVideoIds[index]);
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StudySongTile extends StatelessWidget {
  final String videoId;

  const _StudySongTile({required this.videoId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('songs')
          .doc(videoId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists)
          return const SizedBox();

        final data = snapshot.data!.data() as Map<String, dynamic>;

        // Only show completed songs in the study hub
        if (data['status'] != 'completed') return const SizedBox();

        final String title = data['title'] ?? 'Unknown Title';
        final String artist = data['artist'] ?? 'Unknown Artist';
        final String thumbnailUrl =
            "https://img.youtube.com/vi/$videoId/mqdefault.jpg";

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      PreFlightScreen(videoId: videoId, fromPlaylist: false),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      thumbnailUrl,
                      width: 100,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          artist,
                          maxLines: 1,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
