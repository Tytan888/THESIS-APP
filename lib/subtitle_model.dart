import 'package:csv/csv.dart';

class SubtitleLine {
  final String jp;
  final String en;
  final String romaji;
  final String alignments;
  final int startTimeMs;
  final int endTimeMs;

  SubtitleLine({
    required this.jp,
    required this.en,
    required this.romaji,
    required this.alignments,
    required this.startTimeMs,
    required this.endTimeMs,
  });

  bool isActiveAt(int currentMillis) {
    return currentMillis >= startTimeMs && currentMillis <= endTimeMs;
  }
}

List<SubtitleLine> parseCsvToSubtitles(String rawCsvString) {
  List<List<dynamic>> rows = csv.decode(rawCsvString);

  List<SubtitleLine> subtitles = [];

  for (int i = 1; i < rows.length; i++) {
    var row = rows[i];
    
    if (row.length >= 6) {
      subtitles.add(
        SubtitleLine(
          jp: row[0].toString(),
          en: row[1].toString(),
          romaji: row[2].toString(),
          alignments: row[3].toString(),
          startTimeMs: int.tryParse(row[4].toString()) ?? 0,
          endTimeMs: int.tryParse(row[5].toString()) ?? 0,
        ),
      );
    }
  }

  return subtitles;
}