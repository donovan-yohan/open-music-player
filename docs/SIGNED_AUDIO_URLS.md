# Signed audio URL API

Normal playback/download should use direct object storage URLs, not the Go `/api/v1/stream/{track_id}` proxy. The backend stays in the control plane: authenticate, authorize library ownership, stat the object, and issue short-lived bearer URLs.

## Endpoint

`POST /api/v1/playback/urls`

Authentication: required bearer access token.

Request:

```json
{
  "trackIds": [42],
  "ttlSeconds": 300
}
```

- `trackIds`: required, 1-50 positive track IDs.
- `ttlSeconds`: optional. Server clamps to 1-15 minutes and defaults to 5 minutes.

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
      "storageVersion": "v7"
    }
  ],
  "unavailable": [
    {
      "trackId": 43,
      "code": "AUDIO_UNAVAILABLE",
      "message": "track has no stored audio object"
    }
  ]
}
```

Signed URLs are bearer credentials. Do not log them, store them long term, or send them to analytics.

## Error behavior

- Missing/invalid auth: `401` from auth middleware.
- Track not found: `404 TRACK_NOT_FOUND`.
- Track not in the authenticated user's library: `403 FORBIDDEN`.
- Track has no storage key: returned in `unavailable` with `AUDIO_UNAVAILABLE`.
- Storage object stat fails/missing object: returned in `unavailable` with `OBJECT_UNAVAILABLE`.
- The handler does not fall back to `/stream`; unavailable means the client should not enter the backend proxy path for normal playback.

## Storage / CORS / Range notes

The backend uses the same `storage.Client` object path as the existing stream endpoint for `StatObject` and MinIO presigned GET issuance. Object storage or CDN configuration must allow the client origin to issue `GET`/`HEAD` with `Range` headers and expose at least `Accept-Ranges`, `Content-Length`, `Content-Range`, `Content-Type`, and `ETag` for browser playback and download validation.
