# Operate Discover previews

Preview is off by default. To enable it, set `DISCOVERY_PREVIEW_DIR` on the Go
server to an absolute, clean path to an operator-controlled **read-only local
mount**. Keep that mount and its parents under operator control. The server
loads `manifest.json` from that directory at startup; leave the variable unset
or use an empty array to disable previews. A malformed manifest disables the
entire allowlist and logs a safe reason without printing its contents or path.
No DB, storage, import or provider configuration is needed for the route.

Use one manifest row per exact source key. `GET /api/v1/discovery/search`
may include `previewSourceUrl` on a `results[]` row. Send that string verbatim
as `{"url":"…"}` to `POST /api/v1/discovery/preview`. Keep the original
`sourceUrl` and candidate ID for import and selection. The preview key is not
stored in the selection snapshot and does not indicate clip availability.

Search preserves an exact canonical key, including the YouTube Music host.
It can also derive a key from a YouTube `youtu.be` share link, or remove known
tracking parameters (`si`, `utm_source`, `utm_medium`, `utm_campaign`,
`utm_term`, `utm_content`, `utm_id`) from that link, an exact YouTube watch path,
or a direct SoundCloud track permalink. SoundCloud API keys must be exact numeric
track URLs. Search omits the hint for ambiguous or unsupported URLs and never
follows redirects. Neither the manifest nor the preview POST accepts aliases.

All manifest fields are required, once each. The manifest is a JSON array
(max 256 rows / 256 KiB):

| Field | Value |
| --- | --- |
| `url` | Exact canonical provider source: `https://www.youtube.com/watch?v=…`, `https://music.youtube.com/watch?v=…`, `https://soundcloud.com/artist/track`, or `https://api.soundcloud.com/tracks/123`. Aliases, extra query parameters and fragments do not match. These are identities, not media URLs. |
| `file` | Flat `.mp3` basename of 1–80 ASCII letters/digits/`_`/`-` before the suffix, starting with a letter or digit. No symlinks or other special files. |
| `length`, `sha256` | Exact encoded length in bytes (1–2,097,152) and 64-digit hexadecimal SHA-256 of the final file. |
| `sampleRate`, `frames` | 44100 or 48000 Hz and the exact positive decoded **gapless** sample-frame count at that rate (one frame includes all channels). Max 30 seconds. |
| `excerptStartFrames` | Nonnegative start offset in the source, expressed at the clip's sample rate. |
| `rightsRef`, `attribution` | Nonblank operator records (up to 512 UTF-8 bytes each): versioned evidence of explicit standalone in-app streaming permission for this exact recording/excerpt, and its credit. The route does not display attribution; do not enable clips whose display or other obligations are not met. |
| `expiresAt` | RFC 3339 clearance end, or an operator review date no later than the clearance end. An expired row is unavailable. |

Prepare and audition each approved clip offline. Use MPEG-1 Layer III (mono or
stereo, no CRC, fixed sample rate/channel count), with no external ID3 tags and
with a leading Xing/Info tag containing byte and packet counts and LAME/Lavc
trim data. For example, starting from a cleared local PCM excerpt:

```sh
ffmpeg -nostdin -i cleared-excerpt.wav -map 0:a:0 -map_metadata -1 \
  -ar 48000 -ac 2 -t 30 -c:a libmp3lame -b:a 128k \
  -id3v2_version 0 -write_xing 1 approved.mp3
ffprobe -v error -show_entries stream=sample_rate,channels -of compact approved.mp3
# Divide decoded byte count by (2 * channels) to obtain native frames.
# Require a successful complete decode, then audition those same file bytes.
ffmpeg -nostdin -v error -xerror -i approved.mp3 -f s16le approved-check.pcm
wc -c approved.mp3 approved-check.pcm
shasum -a 256 approved.mp3
```

Before each 200, the server verifies the file's length, SHA-256, packet layout,
sample rate, and gapless extent, then sends a flushed prefix and the remaining
verified bytes. This is not full audio decoding; the offline check is required.
The route never writes a clip or a Library entry. The bundled Nginx `/api/`
location buffers by default. Before enabling previews behind it, disable
response buffering for `/api/v1/discovery/preview`. Every receiving proxy must
also avoid compression and caching on that path. In a controlled test with the
tail held, confirm the client receives the prefix before releasing the tail;
leave the mount unset until that check passes. Missing, expired or invalid
clips return 404. To revoke, remove the mounted clip for subsequent requests and
restart with the row removed (or restart with the variable unset). Manifest
edits are not hot-reloaded; already-admitted transfers can finish from memory.
Provider metadata, a provider account, or a playable provider URL does not grant
permission to mount a clip.
