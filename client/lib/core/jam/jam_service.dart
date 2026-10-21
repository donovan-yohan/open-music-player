import 'package:dio/dio.dart';
import '../../shared/models/track.dart';
import '../api/api_client.dart';
import '../connect/device_presence_service.dart';
import '../services/library_service.dart';
import '../storage/secure_storage.dart';
import 'jam_models.dart';

/// Host-only authenticated adapter. Guest capability traffic never uses this.
class JamService {
  JamService(this.api) : _library = LibraryService(api);
  final ApiClient api;
  final LibraryService _library;
  Future<({List<Track> tracks, int total})> libraryPage(AuthSessionScope scope,
      {int offset = 0, String? query}) async {
    _current(scope);
    final page = await api.inAuthSession(
        scope,
        () => _library.getLibraryPage(
                limit: 50,
                offset: offset,
                sort: 'title',
                order: 'asc',
                query: query,
                fields: const [
                  'id',
                  'title',
                  'artist',
                  'duration_ms',
                  'added_at'
                ]));
    _current(scope);
    return page;
  }

  /// Resolve only from the CURRENT caller's library, never global catalog or
  /// the guest-supplied metadata. Search narrows results; exact numeric ID wins.
  Future<Track> ownedTrack(AuthSessionScope scope, int id, String title) async {
    for (var offset = 0;; offset += 50) {
      final page = await libraryPage(scope, offset: offset, query: title);
      for (final track in page.tracks) {
        if (track.id == id) return track;
      }
      if (page.tracks.isEmpty || offset + page.tracks.length >= page.total) {
        break;
      }
    }
    throw StateError('Track is no longer in your library');
  }

  Future<JamSnapshot> create(JamHostProof proof, String id, List<int> tracks,
      {CancelToken? cancel}) async {
    jamUuid(id);
    if (tracks.isEmpty ||
        tracks.length > 20 ||
        tracks.any((i) => i <= 0) ||
        tracks.toSet().length != tracks.length) {
      throw const FormatException('Choose 1–20 library tracks');
    }
    final r = await proof.request('/jams',
        method: 'POST',
        data: {'jamId': id, 'trackIds': List<int>.of(tracks)},
        cancelToken: cancel);
    _check(proof.scope, r, 201);
    return _snapshot(r, id);
  }

  Future<JamSnapshot> read(AuthSessionScope scope, String id,
      {CancelToken? cancel}) async {
    jamUuid(id);
    final r = await api.sessionRequest(scope, '/jams/$id',
        method: 'GET', cancelToken: cancel);
    _check(scope, r, 200);
    return _snapshot(r, id, host: true);
  }

  Future<JamInvite> invite(JamHostProof proof, String id,
      {CancelToken? cancel}) async {
    jamUuid(id);
    final r = await proof.request('/jams/$id/invites',
        method: 'POST', cancelToken: cancel);
    _check(proof.scope, r, 201);
    return JamInvite.fromJson(jamObject(r.data));
  }

  Future<JamSnapshot> heartbeat(
      JamHostProof proof, String id, int sequence, JamNowPlaying? playback,
      {CancelToken? cancel}) async {
    jamUuid(id);
    jamInt(sequence, min: 1);
    final r = await proof.request('/jams/$id/host',
        method: 'PUT',
        data: {'hostSequence': sequence, 'nowPlaying': playback?.toJson()},
        cancelToken: cancel);
    _check(proof.scope, r, 200);
    return _snapshot(r, id);
  }

  Future<JamRequest> decide(JamHostProof proof, String id, String requestId,
      {required int version,
      required String status,
      JamAdmissionReceipt? receipt,
      CancelToken? cancel}) async {
    jamUuid(id);
    jamUuid(requestId);
    jamInt(version, min: 1);
    if (!{'queued', 'declined', 'uncertain'}.contains(status) ||
        (status == 'queued') != (receipt != null)) {
      throw const FormatException('Invalid Jam decision');
    }
    if (receipt != null) {
      JamAdmissionReceipt.fromJson(Map<String, dynamic>.from(receipt.toJson()));
      if (receipt.requestId != requestId) {
        throw const FormatException('Mismatched receipt');
      }
    }
    final r = await proof.request('/jams/$id/requests/$requestId',
        method: 'PUT',
        data: {
          'expectedVersion': version,
          'status': status,
          if (receipt != null) 'receipt': receipt.toJson()
        },
        cancelToken: cancel);
    _check(proof.scope, r, 200);
    final result = JamRequest.fromJson(jamObject(r.data));
    if (result.requestId != requestId || result.status != status) {
      throw const FormatException('Mismatched Jam decision');
    }
    return result;
  }

  Future<void> close(AuthSessionScope scope, String id,
      {CancelToken? cancel}) async {
    jamUuid(id);
    final r = await api.sessionRequest(scope, '/jams/$id',
        method: 'DELETE', cancelToken: cancel);
    _check(scope, r, 204);
  }

  JamSnapshot _snapshot(Response<dynamic> r, String id, {bool host = false}) {
    final s = JamSnapshot.fromJson(jamObject(r.data), host: host);
    if (s.jamId != id) throw const FormatException('Mismatched Jam');
    return s;
  }

  void _current(AuthSessionScope scope) {
    if (!api.acceptsAuthSession(scope)) throw StateError('Account changed');
  }

  void _check(AuthSessionScope scope, Response<dynamic> r, int status) {
    _current(scope);
    if (r.statusCode != status) {
      throw const FormatException('Unexpected Jam status');
    }
  }
}
