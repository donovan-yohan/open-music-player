import '../api/api_client.dart';
import 'native_playback_backend.dart';

NativePlaybackBackend createNativePlaybackBackend(
        {required String libraryPath,
        required PreparedStemManifestLoader loadManifest,
        required VerifiedPreparedAssetLoader loadPreparedAsset}) =>
    throw UnsupportedError('Native prepared stems are not supported on web.');

NativePlaybackBackendFactory? applicationNativePlaybackFactory(ApiClient api,
        {required Future<String?> Function() accountIdProvider}) =>
    null;
