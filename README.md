# Open Music Player

A self-hosted music library management system that allows you to save, organize, and stream audio from YouTube and SoundCloud.

## Architecture

Open Music Player has a Go backend, native Android product, supported Flutter
web/desktop client and browser extension. The diagram below shows the shared
backend/infrastructure; native Android also consumes this Go API.

```
┌─────────────────┐     ┌─────────────────┐
│  Chrome/Firefox │     │  Flutter Client │
│   Extension     │     │  (Mobile/Web)   │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     │
                     ▼
        ┌────────────────────────┐
        │    Go Backend API      │
        │    (Port 8080)         │
        └────────────┬───────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
┌────────────┐ ┌────────────┐ ┌────────────┐
│ PostgreSQL │ │   Redis    │ │   MinIO    │
│ Port 5434  │ │ Port 6380  │ │ Port 9000  │
└────────────┘ └────────────┘ └────────────┘
```

**Components:**

- **Backend (Go)**: REST API server handling authentication, track management, playlists, downloads, and signed audio URL issuance
- **Android (Kotlin/Compose)**: Supported Android product in `android/`. See
  [native setup/checks](android/README.md) and [PR/nightly artifacts and recovery](docs/ANDROID_PR_ARTIFACTS.md).
- **Client (Flutter)**: Supported web/desktop/shared code. Flutter Android is
  deprecated, retained for explicit recovery without removing installed apps/data.
- **Extension (TypeScript)**: Browser extension for Chrome/Firefox to save tracks from YouTube and SoundCloud

**Infrastructure:**

- **PostgreSQL**: Primary database for users, tracks, playlists, and library data
- **Redis**: Caching layer and job queue for download processing
- **MinIO**: S3-compatible object storage for audio files

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Go 1.25+](https://golang.org/dl/)
- [Flutter 3.0+](https://docs.flutter.dev/get-started/install) (for client development)
- [Node.js 20+](https://nodejs.org/) (for extension development)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (required on the server for downloading)

## Local Development Setup

### Low-memory backend + Flutter Web mode

For backend control-plane development and Flutter Web mobile/responsive QA, prefer the low-memory stack instead of the full queue/download pipeline. Turn on the downloads profile only for the #44 discovery-to-playback smoke:

```bash
scripts/local-low-memory.sh start
scripts/local-low-memory.sh smoke
scripts/local-low-memory.sh playback-smoke

# Heavier e2e gate: enables Redis and one download worker, then verifies
# discovery -> queue -> worker -> MinIO -> signed playback URL.
scripts/local-low-memory.sh e2e-smoke

cd client
flutter run -d chrome --dart-define=OMP_API_BASE_URL=http://localhost:8080/api/v1
```

When another Open Music Player stack already owns the default host ports, use
the isolated wrappers instead:

```bash
scripts/dev isolated
scripts/dev test-infra
scripts/smoke isolated
```

Default `start` mode runs only the backend, PostgreSQL, and MinIO. Redis is disabled by default (`REDIS_ENABLED=false`) and download workers are disabled (`WORKER_COUNT=0`), so Redis-backed queue/download endpoints return `503 SERVICE_DISABLED` until you intentionally enable the downloads profile. `e2e-smoke` starts that profile with `WORKER_COUNT=1` and writes compact evidence under `/tmp`. Use `scripts/local-low-memory.sh clean` when you need to reap the low-memory containers, network, and volumes. See [`docs/LOW_MEMORY_LOCAL_DEV.md`](docs/LOW_MEMORY_LOCAL_DEV.md) for smoke checks, Redis/worker guidance, and the no-Android/no-Gradle workflow.

Audio analysis is optional and disabled unless an analyzer service is configured. See [`docs/AUDIO_ANALYZER_SERVICE.md`](docs/AUDIO_ANALYZER_SERVICE.md) for local service configuration, request/response shape, and failure behavior.

### 1. Clone and Configure Environment

```bash
# Clone the repository
git clone https://github.com/openmusicplayer/openmusicplayer.git
cd openmusicplayer

# Copy environment template
cp .env.example .env
```

The default `.env` values work for local development. Key configuration options:

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PORT` | `5434` | PostgreSQL port (non-standard to avoid conflicts) |
| `REDIS_PORT` | `6380` | Redis port (non-standard to avoid conflicts) |
| `MINIO_PORT` | `9000` | MinIO API port |
| `MINIO_CONSOLE_PORT` | `9001` | MinIO web console port |
| `DATABASE_URL` | `postgresql://omp:omp_dev_password@localhost:5434/openmusicplayer` | Full database connection string |

### 2. Start Infrastructure Services

```bash
# Start PostgreSQL, Redis, and MinIO
docker compose up -d

# Verify services are running
docker compose ps

# View logs if needed
docker compose logs -f
```

Services will be available at:
- PostgreSQL: `localhost:5434`
- Redis: `localhost:6380`
- MinIO API: `localhost:9000`
- MinIO Console: `localhost:9001` (login: minioadmin/minioadmin)

### 3. Start the Backend

```bash
cd backend

# Install dependencies (Go modules are auto-downloaded)
go mod download

# Run the server (migrations run automatically on startup)
make run

# Server starts on http://localhost:8080
```

The backend will automatically:
- Run database migrations
- Connect to Redis for caching and job queues
- Initialize the MinIO bucket for audio storage

### 4. Build the Browser Extension

```bash
cd extension

# Install dependencies
npm install

# Development build with watch
npm run dev

# Production build
npm run build
```

Load the extension in Chrome:
1. Navigate to `chrome://extensions/`
2. Enable "Developer mode"
3. Click "Load unpacked"
4. Select the `extension/dist` directory

### 5. Run the Flutter Client

```bash
cd client

# Get dependencies
flutter pub get

# Run on your platform
flutter run -d macos    # macOS
flutter run -d windows  # Windows
flutter run -d linux    # Linux
flutter run -d chrome   # Web

# Android uses android/ and scripts/android-product instead of Flutter.
```

Flutter web and desktop clients select their API endpoint at build time. The local
default is `http://localhost:8080/api/v1`; Settings displays the compiled value and
does not change it. To select another backend, supply its complete API base,
including `/api/v1`, when running or building:

```bash
flutter run -d chrome --dart-define=OMP_API_BASE_URL=https://api.example.test/api/v1
```

Rebuild the client after changing the destination. For a custom extension build,
set all three independent inputs, `OMP_API_BASE_URL`, `OMP_HEALTH_URL` and
`OMP_WEB_LOGIN_URL`, before `npm run build`, then reload the extension and review
its generated host permissions. Do not derive health or login paths from the API
base. Optional `OMP_WS_URL` configures a full WebSocket URL but does not enable
the currently unconnected progress client.

See [endpoint configuration and migration boundaries](docs/PRIVATE_VM_MIGRATION.md#configuration-contracts)
for validation, session compatibility and private deployment prerequisites.

## API Endpoints

The backend exposes the following API groups:

| Endpoint Group | Description |
|----------------|-------------|
| `POST /api/v1/auth/register` | User registration |
| `POST /api/v1/auth/login` | User login |
| `POST /api/v1/auth/refresh` | Refresh access token |
| `GET /api/v1/search/recordings` | Search local tracks |
| `GET /api/v1/library` | Get user's library |
| `POST /api/v1/playlists` | Create playlist |
| `POST /api/v1/playback/urls` | Issue signed audio URL descriptors for playback/download |
| `GET /api/v1/discovery/search` | Search external source providers |
| `POST /api/v1/queue/items` | Queue a playable track or downloadable source candidate |
| `GET /api/v1/queue` | Read the Redis-backed playback queue |
| `POST /api/v1/downloads` | Queue a direct supported source URL for background library import |
| `GET /api/v1/downloads/{job_id}` | Inspect a background library-import download job |
| `GET /api/v1/musicbrainz/search/tracks` | Search MusicBrainz for metadata |
| `GET /api/v1/ws/progress` | WebSocket for real-time progress updates |

## Database Migrations

The Go backend owns schema creation and repair through the idempotent startup path in `backend/internal/db/db.go`. Starting `backend/cmd/server`, running `make -C backend run`, or starting the Docker Compose backend brings a fresh local database to the current dogfood schema.

There is no supported root Rust/sqlx migration crate in this repository. Root-level `migrations/` and `src/db/models.rs` are intentionally absent; do not reintroduce them as a second schema authority. The SQL files under `backend/internal/db/migrations/` are backend-owned reference notes for schema slices, not a standalone migration runner.

When changing schema, update `backend/internal/db/db.go` first, then repository models/helpers and tests that exercise the affected tables. Add or update SQL reference files only when they match the Go startup schema.

## Project Structure

```
openmusicplayer/
├── backend/                 # Go API server
│   ├── cmd/server/         # Server entrypoint
│   ├── internal/
│   │   ├── api/            # HTTP handlers and routing
│   │   ├── auth/           # Authentication (JWT)
│   │   ├── cache/          # Redis caching
│   │   ├── config/         # Configuration loading
│   │   ├── db/             # Database repositories
│   │   ├── download/       # yt-dlp download service
│   │   ├── matcher/        # Track metadata matching
│   │   ├── musicbrainz/    # MusicBrainz API client
│   │   ├── processor/      # Download job processing
│   │   ├── queue/          # Redis job queue
│   │   ├── search/         # Track search
│   │   ├── storage/        # MinIO/S3 storage and signed reads
│   │   ├── validators/     # Input validation
│   │   └── websocket/      # WebSocket handlers
├── client/                  # Flutter cross-platform client
│   ├── lib/                # Dart source code
│   └── pubspec.yaml        # Flutter dependencies
├── extension/              # Browser extension
│   ├── src/                # TypeScript source
│   ├── manifest.json       # Extension manifest (MV3)
│   └── webpack.config.js   # Build configuration
├── docker-compose.yml      # Full local infrastructure stack
├── docker-compose.local-low-memory.yml # Low-memory dogfood stack and e2e smoke
├── .env.example            # Environment template
└── README.md               # This file
```

## Deployment

### Quick Start (Single VPS with Docker Compose)

The easiest way to deploy the full stack is using Docker Compose:

```bash
# 1. Clone and configure
git clone https://github.com/openmusicplayer/openmusicplayer.git
cd openmusicplayer
cp .env.example .env

# 2. Edit .env with production values (see below)
nano .env

# 3. Start the full stack
docker compose up -d

# 4. Verify all services are healthy
docker compose ps

# 5. View logs
docker compose logs -f backend
```

This starts:
- **Backend API** on port 8080 with yt-dlp for downloads
- **PostgreSQL** for data persistence
- **Redis** for caching and job queues
- **MinIO** for audio file storage

### Production Environment Variables

Create a `.env` file with these production values:

```bash
# Security - REQUIRED: Generate with `openssl rand -hex 32`
JWT_SECRET=your-64-character-hex-secret-here

# Database - REQUIRED: Use strong passwords
POSTGRES_USER=omp
POSTGRES_PASSWORD=your-strong-database-password
POSTGRES_DB=openmusicplayer

# MinIO/S3 Storage - REQUIRED: Use strong passwords
MINIO_ROOT_USER=your-minio-admin-user
MINIO_ROOT_PASSWORD=your-strong-minio-password
MINIO_ACCESS_KEY=your-minio-admin-user
MINIO_SECRET_KEY=your-strong-minio-password
MINIO_BUCKET=audio-files

# Server
SERVER_PORT=8080
WORKER_COUNT=5
```

### Production with Nginx (HTTPS)

For production deployments with SSL/TLS:

```bash
# 1. Generate SSL certificates (using Let's Encrypt)
certbot certonly --standalone -d your-domain.com

# 2. Copy certificates to nginx/certs/
cp /etc/letsencrypt/live/your-domain.com/fullchain.pem nginx/certs/
cp /etc/letsencrypt/live/your-domain.com/privkey.pem nginx/certs/

# 3. Edit nginx/nginx.conf to enable HTTPS (uncomment the HTTPS server block)

# 4. Start with production profile (includes nginx)
docker compose --profile production up -d
```

### Health Checks

The backend exposes health check endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Basic liveness check |
| `GET /health?deep=true` | Full readiness check (checks DB, Redis, Storage) |
| `GET /healthz` | Kubernetes liveness probe |
| `GET /readyz` | Kubernetes readiness probe |

### Database Backup Strategy

**Automated backups with pg_dump:**

```bash
# Create a backup
docker exec omp-postgres pg_dump -U omp openmusicplayer > backup_$(date +%Y%m%d_%H%M%S).sql

# Restore from backup
docker exec -i omp-postgres psql -U omp openmusicplayer < backup_20240115_120000.sql
```

**Recommended backup schedule:**
- Daily full backups retained for 7 days
- Weekly backups retained for 4 weeks
- Monthly backups retained for 12 months

**MinIO/S3 backup:**
```bash
# Sync audio files to external backup
mc mirror omp-minio/audio-files /backup/audio-files/
```

### yt-dlp Updates

yt-dlp requires regular updates to keep working with YouTube/SoundCloud changes:

```bash
# Update yt-dlp in the running container
docker exec omp-backend pip3 install --upgrade yt-dlp

# Or rebuild the container to get latest version
docker compose build --no-cache backend
docker compose up -d backend
```

**Recommended:** Set up a weekly cron job to update yt-dlp.

### Scaling Considerations

For high-traffic deployments:

1. **Horizontal scaling**: Run multiple backend containers behind a load balancer
2. **Database**: Use managed PostgreSQL (AWS RDS, Cloud SQL) with read replicas
3. **Redis**: Use managed Redis (ElastiCache, Memorystore) with clustering
4. **Storage**: Use AWS S3 or managed MinIO cluster for object storage
5. **CDN**: Place audio file serving behind a CDN for reduced latency

### Kubernetes Deployment (Future)

A Helm chart is planned for Kubernetes deployments. For now, use the Docker Compose setup or adapt the configuration manually.

### Extension Distribution

For production extension distribution:

1. Build the extension: `cd extension && npm run build`
2. Create a ZIP of the `dist` directory
3. Submit to Chrome Web Store and Firefox Add-ons

### Tailnet Staging

For mobile/web staging on a Tailnet, use [`docs/TAILNET_STAGING.md`](docs/TAILNET_STAGING.md): it starts the low-memory backend, serves Flutter Web on `0.0.0.0`, documents health/API URLs, and links the Android PR APK smoke flow.

### Backend maintenance repair

Use [`docs/MAINTENANCE_REPAIR.md`](docs/MAINTENANCE_REPAIR.md) to safely re-run metadata matching and audio analysis backfills/retries without hand-editing database rows.

### Android PR artifacts

Native Clients CI checks and assembles the Kotlin/Compose Android product.
Flutter Android is deprecated; required Flutter shared checks remain. See
[`docs/ANDROID_PR_ARTIFACTS.md`](docs/ANDROID_PR_ARTIFACTS.md) for artifacts,
explicit private endpoint builds, compatible updates and legacy recovery.

### Client Distribution

Build release versions of the Flutter client:

```bash
cd client

# Android is native. From the repository root, follow android/README.md.
# Explicit legacy recovery only: scripts/build client-flutter-android-legacy

# iOS (requires macOS and Xcode)
flutter build ios --release

# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Web
flutter build web --release
```

## Nightly Android APK

Every push to `main` validates and assembles the native Compose Android product
through [`nightly-apk`](.github/workflows/nightly-apk.yml). Download `soundq-nightly`
from that run's **Artifacts** section (seven-day retention). Older runs expire by
retention; the workflow does not delete artifacts from other runs.

Public PR/nightly APKs use the synthetic `https://fixture.invalid/api/v1` endpoint.
They do not connect to a real account, and no repository endpoint variable is
consumed. For a private usable build, follow [native setup](android/README.md)
and explicitly supply the approved HTTPS backend, source reference and build ID.
See [artifact and recovery boundaries](docs/ANDROID_PR_ARTIFACTS.md) before any
installation. No incompatible update, automatic Flutter data migration or full
native parity is promised.

## Development Notes

- The backend uses graceful shutdown, waiting for in-progress downloads to complete
- WebSocket connections provide real-time updates for download progress
- MusicBrainz integration automatically matches track metadata
- Audio files are transcoded and stored in MinIO with unique keys
- The extension extracts video metadata directly from YouTube/SoundCloud pages

## License

MIT License - see LICENSE file for details
