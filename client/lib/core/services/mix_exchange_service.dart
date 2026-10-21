import 'dart:convert';

import '../../models/mix_plan.dart';
import '../api/api_client.dart';

/// Portable performance metadata. Audio access remains recipient-owned.
class MixExchangeService {
  MixExchangeService(this._api);
  final ApiClient _api;

  Future<MixPlan> importMix(String text) => _api.withServerError(
        'Could not import mix.',
        () async {
          if (text.trim().isEmpty || utf8.encode(text).length > 256 * 1024) {
            throw const FormatException(
                'Mix metadata must be 256 KiB or smaller.');
          }
          // Forward the original bytes. Decoding/re-encoding here would hide
          // duplicate keys from the server's strict authoring boundary.
          final response = await _api.post<Map<String, dynamic>>(
              '/mix-plans/import',
              data: text,
              headers: {'Content-Type': 'application/json'});
          final created = response.data;
          final id = created?['id'];
          if (created == null || id is! String || id.isEmpty) {
            throw const FormatException(
                'Import returned no saved mix identity.');
          }
          final verified = await _api.get<Map<String, dynamic>>(
              '/mix-plans/${Uri.encodeComponent(id)}');
          // Compare raw authoring data before permissive display DTOs can
          // clamp gains/ramps, round timings or drop unknown clip fields.
          if (!_sameJson(created, verified.data)) {
            throw const FormatException(
                'Imported mix readback changed. Reload saved mixes before retrying.');
          }
          return MixPlan.fromAuthoringJson(verified.data!);
        },
      );

  Future<String> exportMix(String planId) => _api.withServerError(
        'Could not export mix.',
        () async {
          final response = await _api.get<Map<String, dynamic>>(
              '/mix-plans/${Uri.encodeComponent(planId)}/export');
          return jsonEncode(response.data);
        },
      );
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}
