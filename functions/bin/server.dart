import 'dart:convert';
import 'package:firebase_functions/firebase_functions.dart';
import 'package:dart_ytmusic_api/yt_music.dart';

// Extracting the logic into a separate top-level function 
// prevents the build_runner AST parser from failing.
Future<Response> searchSongsHandler(Request request) async {
  final query = request.url.queryParameters['q'];
  
  if (query == null || query.isEmpty) {
    return Response(
      400, 
      body: jsonEncode({'error': 'Missing query parameter "q"'}),
    );
  }

  try {
    final ytMusic = YTMusic();
    await ytMusic.initialize();
    final results = await ytMusic.searchSongs(query);
    
    final jsonResults = results.take(10).map((r) => {
      'videoId': r.videoId,
      'title': r.name,
      'artist': r.artist.name,
      'duration': r.duration,
    }).toList();

    return Response(
      200, 
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'data': jsonResults}),
    );
  } catch (e) {
    return Response(
      500, 
      body: jsonEncode({'error': e.toString()}),
    );
  }
}

void main() {
  runFunctions((firebase) {
    firebase.https.onRequest(
      name: 'searchSongs',
      options: const HttpsOptions(
        cors: Cors(['*']), // CORS handled automatically[cite: 2]
        maxInstances: Instances(10), // Controls costs[cite: 2]
      ),
      searchSongsHandler, // Simply pass the reference here
    );
  });
}