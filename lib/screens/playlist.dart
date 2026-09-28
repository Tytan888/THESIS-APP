import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';

class _PlaylistSongTile extends StatelessWidget {
  final String videoId;

  const _PlaylistSongTile({required this.videoId});

  Widget _buildStatusIcon(String status, int stage) {
    switch (status) {
      case 'completed':
        return const Icon(Icons.check_circle, color: Colors.green, size: 30);
      case 'processing':
        double? progressValue = stage > 0 ? stage / 12.0 : null;
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: progressValue,
          ),
        );
      case 'error':
        return const Icon(
          Icons.error_outline,
          color: Colors.redAccent,
          size: 30,
        );
      default:
        return const Icon(Icons.hourglass_empty, color: Colors.grey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection("songs")
          .doc(videoId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ListTile(
            leading: SizedBox(
              width: 120,
              height: 68,
              child: Center(child: CircularProgressIndicator()),
            ),
            title: Text("Loading..."),
          );
        }

        final videoId = snapshot.data!.id;
        final songData = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final status = songData['status'] ?? '';
        final title = songData['title'] ?? 'Deleted Song';
        final artist = songData['artist'] ?? '???';
        final thumbnailUrl =
            "https://img.youtube.com/vi/$videoId/mqdefault.jpg";

        // IF PROCESSING: Nest a stream to listen to the subcollection progress document
        if (status == 'processing') {
          return StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection("songs")
                .doc(videoId)
                .collection("progress")
                .doc("status")
                .snapshots(),
            builder: (context, progressSnapshot) {
              int stage = 0;
              String msg = "Processing...";

              if (progressSnapshot.hasData && progressSnapshot.data!.exists) {
                final progressData =
                    progressSnapshot.data!.data() as Map<String, dynamic>? ??
                    {};
                stage = progressData['processing_stage'] ?? 0;
                msg = progressData['processing_msg'] ?? msg;
              }

              return _buildTileLayout(
                context,
                title,
                artist,
                thumbnailUrl,
                status,
                stage,
                msg,
              );
            },
          );
        }

        final msg = status == 'error'
            ? (errorMessages[songData['error_code'] ?? 'ERR_DEFAULT'] ??
                  'An unexpected issue occurred. Please contact the developers.')
            : '';
        return _buildTileLayout(
          context,
          title,
          artist,
          thumbnailUrl,
          status,
          0,
          msg,
        );
      },
    );
  }

  // Extracted the UI layout into a helper method to keep code clean and avoid duplication
  Widget _buildTileLayout(
    BuildContext context,
    String title,
    String artist,
    String thumbnailUrl,
    String status,
    int stage,
    String msg,
  ) {
    return ListTile(
      leading: thumbnailUrl.isNotEmpty
          ? Image.network(
              thumbnailUrl,
              width: 100,
              height: 68,
              fit: BoxFit.cover,
            )
          : const SizedBox(
              width: 120,
              height: 68,
              child: Icon(Icons.music_note),
            ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),

      // 1. Always show the artist, remove the dynamic color/bold styling
      subtitle: Text(
        artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.grey,
          fontWeight: FontWeight.normal,
        ),
      ),
      trailing: _buildStatusIcon(status, stage),

      onTap: () async {
        if (status == 'processing') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                msg.isNotEmpty ? msg : "Song is still processing. Hang tight!",
              ),
              duration: const Duration(milliseconds: 1500),
            ),
          );
        } else if (status == 'error') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                msg.isNotEmpty
                    ? msg
                    : "Processing for \"$title\" encountered an issue...",
              ),
              duration: const Duration(milliseconds: 1500),
            ),
          );
        } else if (status == 'completed') {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text("Start Study Session?"),
              content: Text(
                "Start a study session with \"$title\"?",
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text("Start"),
                ),
              ],
            ),
          );

          if (confirmed != true || !context.mounted) return;

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  PreFlightScreen(videoId: videoId, fromPlaylist: true),
            ),
          );
        }
      },
    );
  }
}

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Your Playlist")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(currentUsername)
            .collection('playlist')
            .orderBy('date_added', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text("Your playlist is empty. Go add some songs!"),
            );
          }

          final playlistDocs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: playlistDocs.length,
            itemBuilder: (context, index) {
              final videoId = playlistDocs[index].id;
              return _PlaylistSongTile(videoId: videoId);
            },
          );
        },
      ),
    );
  }
}
