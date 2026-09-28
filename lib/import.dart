export 'screens/login.dart';
export 'screens/main_menu.dart';
export 'screens/search.dart';
export 'screens/playlist.dart';
export 'screens/study.dart';
export 'screens/pre_flight.dart';
export 'screens/pre_test.dart';
export 'screens/wordlist.dart';
export 'screens/karaoke.dart';
export 'screens/immediate_post_test.dart';
export 'screens/discover.dart';
export 'screens/maintenance.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';

const String appTitle = "Koe.ru";

String currentUsername = "";

const String g1 = "aoi";
const String g2 = "aka";
const String g3 = "midori";

final errorMessages = {
  'ERR_DEFAULT': 'An unexpected issue occurred. Please contact the developers.',
  // 'ERR_YT_NOT_FOUND': 'We couldn\'t locate this song on YouTube. Please contact the developers.',
  // 'EXPT_YT_NO_LYRICS': 'No lyrics are available for this track...',
  // 'EXPT_YT_NOT_SYNCED': 'Lyrics were found, but they are not time-synced...',
  'ERR_YT_API_GENERIC_CRASH':
      'The YouTube service encountered a critical error. Please contact the developers.',
  'EXPT_YT_BAD_LYRICS':
      'Lyrics coundn\'t be found for this track, or they are not time-synced...',
  'EXPT_TRANS_NOT_FOUND':
      'We couldn\'t find a suitable translation for these lyrics...',
  'ERR_MERGE_FAILED':
      'Failed to sync the translations with the original lyrics. Please contact the developers.',
  'ERR_CLEANING_FAILED':
      'An error occurred while cleaning and formatting the text. Please contact the developers.',
  'ERR_ALIGNMENT_FAILED':
      'Failed to align vocabulary matches between Japanese and English. Please contact the developers.',
  'ERR_POS_FILTERING_FAILED':
      'Vocabulary verification failed at Step 1. Please contact the developers.',
  'ERR_LABSE_FILTERING_FAILED':
      'Vocabulary verification failed at Step 2. Please contact the developers.',
  'ERR_LLM_FILTERING_FAILED':
      'Vocabulary verification failed at Step 3. Please contact the developers.',
  'ERR_VOCAB_FILTERING_FAILED':
      'Fetching dictionary definitions failed. Please contact the developers.',
  'ERR_DB_ERROR_UPDATE_CRASH':
      'A critical error occurred while saving the error status. Please contact the developers.',
  'ERR_DB_SAVING_CRASH':
      'Saving the song data to the database failed. Please contact the developers.',
  'ERR_UNKNOWN_CRASH':
      'An unknown critical error has occurred. Please contact the developers.',
  'EXPT_NOT_ENOUGH_VOCAB':
      'The song didn\'t have enough vocabulary to learn from...',
};

const Map<String, String> _kanaToRomajiMap = {
  'きゃ': 'kya',
  'きゅ': 'kyu',
  'きょ': 'kyo',
  'しゃ': 'sha',
  'しゅ': 'shu',
  'しょ': 'sho',
  'ちゃ': 'cha',
  'ちゅ': 'chu',
  'ちょ': 'cho',
  'にゃ': 'nya',
  'にゅ': 'nyu',
  'にょ': 'nyo',
  'ひゃ': 'hya',
  'ひゅ': 'hyu',
  'ひょ': 'hyo',
  'みゃ': 'mya',
  'みゅ': 'myu',
  'みょ': 'myo',
  'りゃ': 'rya',
  'りゅ': 'ryu',
  'りょ': 'ryo',
  'ぎゃ': 'gya',
  'ぎゅ': 'gyu',
  'ぎょ': 'gyo',
  'じゃ': 'ja',
  'じゅ': 'ju',
  'じょ': 'jo',
  'びゃ': 'bya',
  'びゅ': 'byu',
  'びょ': 'byo',
  'ぴゃ': 'pya',
  'ぴゅ': 'pyu',
  'ぴょ': 'pyo',
  'あ': 'a',
  'い': 'i',
  'う': 'u',
  'え': 'e',
  'お': 'o',
  'か': 'ka',
  'き': 'ki',
  'く': 'ku',
  'け': 'ke',
  'こ': 'ko',
  'さ': 'sa',
  'し': 'shi',
  'す': 'su',
  'せ': 'se',
  'そ': 'so',
  'た': 'ta',
  'ち': 'chi',
  'つ': 'tsu',
  'て': 'te',
  'と': 'to',
  'な': 'na',
  'に': 'ni',
  'ぬ': 'nu',
  'ね': 'ne',
  'の': 'no',
  'は': 'ha',
  'ひ': 'hi',
  'ふ': 'fu',
  'へ': 'he',
  'ほ': 'ho',
  'ま': 'ma',
  'み': 'mi',
  'む': 'mu',
  'め': 'me',
  'も': 'mo',
  'や': 'ya',
  'ゆ': 'yu',
  'よ': 'yo',
  'ら': 'ra',
  'り': 'ri',
  'る': 'ru',
  'れ': 're',
  'ろ': 'ro',
  'わ': 'wa',
  'を': 'wo',
  'ん': 'n',
  'が': 'ga',
  'ぎ': 'gi',
  'ぐ': 'gu',
  'げ': 'ge',
  'ご': 'go',
  'ざ': 'za',
  'じ': 'ji',
  'ず': 'zu',
  'ぜ': 'ze',
  'ぞ': 'zo',
  'だ': 'da',
  'ぢ': 'ji',
  'づ': 'zu',
  'で': 'de',
  'ど': 'do',
  'ば': 'ba',
  'び': 'bi',
  'ぶ': 'bu',
  'べ': 'be',
  'ぼ': 'bo',
  'ぱ': 'pa',
  'ぴ': 'pi',
  'ぷ': 'pu',
  'ぺ': 'pe',
  'ぽ': 'po',
};

const bool debugNotification = false;

String kanaToRomaji(String kana) {
  if (kana.isEmpty) return "";

  String normalizedKana = katakanaToHiragana(kana);

  String result = "";
  int i = 0;

  while (i < normalizedKana.length) {
    if (i + 1 < normalizedKana.length &&
        _kanaToRomajiMap.containsKey(normalizedKana.substring(i, i + 2))) {
      result += _kanaToRomajiMap[normalizedKana.substring(i, i + 2)]!;
      i += 2;
    } else if (normalizedKana[i] == 'っ' || normalizedKana[i] == 'ッ') {
      if (i + 1 < normalizedKana.length) {
        String nextChar = _kanaToRomajiMap[normalizedKana[i + 1]] ?? "";
        if (nextChar.isNotEmpty) {
          result += nextChar[0];
        }
      }
      i++;
    } else if (_kanaToRomajiMap.containsKey(normalizedKana[i])) {
      result += _kanaToRomajiMap[normalizedKana[i]]!;
      i++;
    } else {
      result += normalizedKana[i];
      i++;
    }
  }
  return result;
}

String katakanaToHiragana(String input) {
  StringBuffer buffer = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    int charCode = input.codeUnitAt(i);
    if (charCode >= 0x30A1 && charCode <= 0x30F6) {
      buffer.writeCharCode(charCode - 0x0060);
    } else {
      buffer.writeCharCode(charCode);
    }
  }
  return buffer.toString();
}

List<String> simplifyPOS(List<String> rawPos) {
  Set<String> simplified = {};

  for (String pos in rawPos) {
    String p = pos.toLowerCase();

    if (p.contains('verb') || p == 'vi' || p == 'vt') {
      simplified.add('Verb');
    } else if (p.contains('adjective') || p.startsWith('adj')) {
      simplified.add('Adjective');
    } else if (p.contains('adverb')) {
      simplified.add('Adverb');
    } else if (p.contains('noun') &&
        !p.contains('adverbial') &&
        !p.contains('adjectival')) {
      simplified.add('Noun');
    } else if (p.contains('particle') || p == 'prt') {
      simplified.add('Particle');
    } else if (p.contains('conjunction') || p == 'conj') {
      simplified.add('Conjunction');
    } else if (p.contains('expression') || p == 'exp') {
      simplified.add('Expression');
    } else if (p.contains('interjection') || p == 'int') {
      simplified.add('Interjection');
    } else if (p.contains('pronoun') || p == 'pn') {
      simplified.add('Pronoun');
    } else if (p.contains('numeral') || p == 'num') {
      simplified.add('Numeral');
    } else if (p.contains('counter') || p == 'ctr') {
      simplified.add('Counter');
    } else if (p.contains('prefix') ||
        p.contains('suffix') ||
        p == 'pref' ||
        p == 'suf') {
      simplified.add('Affix');
    } else if (p.contains('copula') || p.startsWith('cop')) {
      simplified.add('Copula');
    } else if (p.contains('auxiliary')) {
      simplified.add('Auxiliary');
    } else if (p != 'unclass' && p.isNotEmpty) {
      simplified.add(pos.toUpperCase() + pos.substring(1));
    }
  }

  return simplified.toList();
}

void _returnToOrigin(BuildContext context, bool fromPlaylist) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (context) =>
          fromPlaylist ? const PlaylistScreen() : const StudyScreen(),
    ),
    (route) => route.isFirst,
  );
}

Future<void> checkAndNavigatePostTest(
  BuildContext context,
  String videoId,
  String sessionId,
  List<Map<String, dynamic>> unseenWords,
  bool fromPlaylist,
) async {
  if (unseenWords.isEmpty) {
    if (!context.mounted) return;
    _returnToOrigin(context, fromPlaylist);
  }

  try {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUsername)
        .get();
    final userData = userDoc.data() ?? {};
    final weeklyPostTests = List<dynamic>.from(
      userData['weekly_post_test'] ?? [],
    );

    bool needsPostTest = false;
    final now = DateTime.now();

    for (var test in weeklyPostTests) {
      final startDate = (test['start_date'] as Timestamp).toDate();
      final endDate = (test['end_date'] as Timestamp).toDate();
      final telemetryId = test['telemetry_id'] as String? ?? "";

      if (now.isAfter(startDate) &&
          now.isBefore(endDate) &&
          telemetryId.isEmpty) {
        needsPostTest = true;
        break;
      }
    }

    if (!context.mounted) return;

    if (needsPostTest) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ImmediatePostTestScreen(
            videoId: videoId,
            sessionId: sessionId,
            unseenWords: unseenWords,
            fromPlaylist: fromPlaylist,
          ),
        ),
      );
    } else {
      _returnToOrigin(context, fromPlaylist);
    }
  } catch (e) {
    if (!context.mounted) return;

    _returnToOrigin(context, fromPlaylist);
  }
}
