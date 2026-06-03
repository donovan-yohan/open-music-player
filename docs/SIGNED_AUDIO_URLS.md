# Signed audio URL API

The signed audio URL endpoint is the backend control-plane path for direct object storage/CDN playback and downloads: authenticate, authorize library ownership, stat the object, and issue short-lived bearer URLs. `/api/v1/stream/{track_id}` remains registered as the compatibility/dev fallback while clients migrate; this endpoint does not remove or replace it yet.

## Endpoint

`POST /api/v1/playback/urls`

Authentication: required bearer access token.

Request:

```json
{
  "trackIds": [42],
  "ttlSeconds": 600
}
```

- `trackIds`: required, 1-50 positive track IDs. Non-positive IDs are rejected with `400 INVALID_REQUEST`.
- `ttlSeconds`: optional. Server clamps to 1-30 minutes and defaults to 10 minutes.

Response:

```json
{
  "urls": [
    {
      "trackId": 42,
      "url": "https://object-storage/...signed...",
      "expiresAt": "2026-06-03T12:00:00Z",
      "contentType": "audio/mpeg",
      "sizeBytes": 1234567,
      "etag": "abc123",
      "storageKeyVersion": "v7"
    }
  ],
  "unavailable": [
    {
      "trackId": 43,
      "code": "audio_unavailable",
      "message": "track has no stored audio object"
    }
  ]
}
```

Signed URLs are bearer credentials. Do not log them, store them long term, or send them to analytics.

## Error behavior

- Missing/invalid auth: `401` from auth middleware.
- Missing track, nonexistent track, or track not in the authenticated user's library: `404 TRACK_NOT_FOUND`. The endpoint intentionally uses one response so callers cannot distinguish global track existence from library membership.
- Track has no storage key: returned in `unavailable` with `audio_unavailable`.
- Storage object stat fails/missing object: returned in `unavailable` with `artifact_missing`.
- Presign failure after authorization/object stat: `500 INTERNAL_ERROR` with no signed URL in the response.
- The handler does not inline a `/stream` URL or automatically proxy on unavailable items. `/api/v1/stream/{track_id}` remains a separate fallback route for clients that still use the backend proxy.

## Storage / CORS / Range notes

The backend uses the same `storage.Client` object path as the existing stream endpoint for `StatObject` and MinIO presigned GET issuance. Object storage or CDN configuration must allow the client origin to issue `GET`/`HEAD` with `Range` headers and expose at least `Accept-Ranges`, `Content-Length`, `Content-Range`, `Content-Type`, and `ETag` for browser playback and download validation.
