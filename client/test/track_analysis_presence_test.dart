import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart' as dio_api;
import 'package:open_music_player/core/services/analysis_service.dart';
import 'package:open_music_player/core/services/api_client.dart' as service_api;
import 'package:open_music_player/models/track_analysis.dart';

import 'support/mock_dio_client.dart';

class _AnalysisApiClient extends service_api.ApiClient {
  _AnalysisApiClient(this.body);

  final Map<String, dynamic> body;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    return parser!(body);
  }
}

void main() {
  group('TrackAnalysis override presence', () {
    test('distinguishes an absent override field from an explicit clear', () {
      final absent = TrackAnalysis.fromJson(status: 'analyzed');
      final cleared = TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: const <String, dynamic>{},
      );

      expect(absent.overridesPresent, isFalse);
      expect(absent.overrides, isNull);
      expect(absent.toJson(), isNot(contains('overrides')));

      expect(cleared.overridesPresent, isTrue);
      expect(cleared.overrides, isNull);
      expect(cleared.toJson()['overrides'], isEmpty);
    });

    test('track payload parsing preserves explicit empty overrides', () {
      final absent = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
      });
      final cleared = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
        'analysis_overrides': <String, dynamic>{},
      });
      final nestedClear = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
        'analysis_summary': {
          'overrides': <String, dynamic>{},
        },
      });

      expect(absent?.overridesPresent, isFalse);
      expect(cleared?.overridesPresent, isTrue);
      expect(cleared?.toJson()['overrides'], isEmpty);
      expect(nestedClear?.overridesPresent, isTrue);
    });

    test('analysis service parser preserves response field presence', () async {
      final absent = await AnalysisService(
        _AnalysisApiClient({'status': 'analyzed'}),
      ).getTrackAnalysis(1);
      final cleared = await AnalysisService(
        _AnalysisApiClient({
          'status': 'analyzed',
          'overrides': <String, dynamic>{},
        }),
      ).getTrackAnalysis(1);

      expect(absent.overridesPresent, isFalse);
      expect(cleared.overridesPresent, isTrue);
      expect(cleared.toJson()['overrides'], isEmpty);
    });

    test('Dio API parser preserves an explicit clear', () async {
      final dio_api.ApiClient api = mockQueueApiClient((request) async {
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'overrides': <String, dynamic>{},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final analysis = await api.getTrackAnalysis(1);

      expect(analysis.overridesPresent, isTrue);
      expect(analysis.overrides, isNull);
      expect(analysis.toJson()['overrides'], isEmpty);
    });
  });
}
