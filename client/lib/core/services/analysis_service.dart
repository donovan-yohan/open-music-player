import '../../models/track_analysis.dart';
import 'api_client.dart';

/// Read-only client for `GET /tracks/{id}/analysis`.
///
/// Wraps the parser-based [ApiClient] and maps the backend envelope
/// (`{status, summary, ...}`) into a [TrackAnalysis]. The endpoint can legitimately
/// answer with a 404 (analysis not found / track not in library) or a 503
/// (analyzer disabled); those surface as [ApiException]s so callers can render a
/// clear "Analysis unavailable" state instead of crashing.
class AnalysisService {
  final ApiClient _apiClient;

  AnalysisService(this._apiClient);

  /// Fetches the current analysis for [trackId].
  ///
  /// Returns a [TrackAnalysis] whose [TrackAnalysis.status] may be pending /
  /// analyzing / stale / failed / unsupported and whose summary may be null. Throws
  /// [ApiException] when the server has no analysis to give (404) or the
  /// analyzer is disabled (503).
  Future<TrackAnalysis> getTrackAnalysis(int trackId) {
    return _apiClient.get<TrackAnalysis>(
      '/tracks/$trackId/analysis',
      parser: (json) => TrackAnalysis.fromJson(
        status: json['status'],
        summary: json['summary'],
      ),
    );
  }
}
