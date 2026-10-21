import '../audio/playback_state.dart';
import 'jam_host_controller.dart';
import 'jam_models.dart';
import 'jam_service.dart';

/// Bind the existing canonical owner, never a second queue or source resolver.
/// Controller supplies a never-reviving auth/Jam/proof/session/approval fence.
JamAdmission canonicalJamAdmission(
        {required PlaybackState playback, required JamService service}) =>
    (jamId, request, expectedSessionId, stillCurrent) async {
      final scope = service.api.captureAuthSession();
      bool current() => stillCurrent() && service.api.acceptsAuthSession(scope);
      if (!current() || request.trackId == null) {
        throw StateError('Approval changed');
      }
      // Resolve the private numeric mapping through the CURRENT owner's library.
      // No acquisition/global catalog fallback and no guest-supplied source URL.
      final track = await service.ownedTrack(scope, request.trackId!, '');
      if (!current()) throw StateError('Approval changed');
      final occurrence = await service.api.inAuthSession(
          scope,
          () => playback.admitJamRequest(
              jamId: jamId,
              requestId: request.requestId,
              track: track.toPlaybackJson(),
              expectedSessionId: expectedSessionId,
              stillCurrent: current));
      if (!current()) throw StateError('Approval changed');
      return JamAdmissionReceipt(
          requestId: request.requestId,
          sessionId: expectedSessionId,
          occurrenceId: occurrence);
    };
