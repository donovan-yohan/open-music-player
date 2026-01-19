# Open Music Player

A self-hosted music library management system that allows you to save, organize, and stream audio from YouTube and SoundCloud.

## Architecture

Open Music Player consists of four main components:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Chrome/Firefox │     │  Flutter Client │     │   Rust CLI      │
│   Extension     │     │  (Mobile/Web)   │     │   (Migrations)  │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │    Go Backend API      │
                    │    (Port 8080)         │
                    └────────────┬───────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   PostgreSQL    │     │     Redis       │     │     MinIO       │
│   (Port 5434)   │     │   (Port 6380)   │     │  (Port 9000)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**Components:**

- **Backend (Go)**: REST API server handling authentication, track management, playlists, downloads, and streaming
- **Client (Flutter)**: Cross-platform client for iOS, Android, macOS, Windows, Linux, and web
- **Extension (TypeScript)**: Browser extension for Chrome/Firefox to save tracks from YouTube and SoundCloud
- **Database Tools (Rust)**: Database migrations and utilities

**Infrastructure:**

- **PostgreSQL**: Primary database for users, tracks, playlists, and library data
- **Redis**: Caching layer and job queue for download processing
- **MinIO**: S3-compatible object storage for audio files

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Go 1.25+](https://golang.org/dl/)
- [Flutter 3.0+](https://docs.flutter.dev/get-started/install) (for client development)
- [Node.js 20+](https://nodejs.org/) (for extension development)
- [Rust](https://rustup.rs/) (optional, for database migrations CLI)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (required on the server for downloading)

## Local Development Setup

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
go run ./cmd/server

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
flutter run             # Connected mobile device
```

Configure the API endpoint in the client settings to point to your backend (default: `http://localhost:8080`).

## API Endpoints

The backend exposes the following API groups:

| Endpoint Group | Description |
|----------------|-------------|
| `POST /api/auth/register` | User registration |
| `POST /api/auth/login` | User login |
| `POST /api/auth/refresh` | Refresh access token |
| `GET /api/tracks` | List user's tracks |
| `POST /api/tracks` | Add track to library |
| `GET /api/library` | Get user's library |
| `GET /api/playlists` | List playlists |
| `POST /api/playlists` | Create playlist |
| `GET /api/stream/:id` | Stream audio file |
| `POST /api/download` | Queue track for download |
| `GET /api/search` | Search tracks |
| `GET /api/musicbrainz/search` | Search MusicBrainz for metadata |
| `WS /api/ws` | WebSocket for real-time updates |

## Database Migrations

Migrations are managed in two locations:

**Backend migrations (Go/SQL):**
```bash
cd backend

# Run migrations
make migrate-up

# Rollback
make migrate-down

# Create new migration
make migrate-create
# Enter migration name when prompted
```

**Rust migrations (used by CLI tools):**
```bash
# Run Rust migrations
cargo run
```

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
│   │   ├── storage/        # MinIO/S3 storage
│   │   ├── stream/         # Audio streaming
│   │   ├── validators/     # Input validation
│   │   └── websocket/      # WebSocket handlers
│   └── Makefile            # Migration commands
├── client/                  # Flutter cross-platform client
│   ├── lib/                # Dart source code
│   └── pubspec.yaml        # Flutter dependencies
├── extension/              # Browser extension
│   ├── src/                # TypeScript source
│   ├── manifest.json       # Extension manifest (MV3)
│   └── webpack.config.js   # Build configuration
├── migrations/             # SQL migrations (Rust tooling)
├── src/                    # Rust database utilities
├── docker-compose.yml      # Infrastructure services
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

### Client Distribution

Build release versions of the Flutter client:

```bash
cd client

# Android APK
flutter build apk --release

# iOS (requires macOS and Xcode)
flutter build ios --release

# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Web
flutter build web --release
```

## Development Notes

- The backend uses graceful shutdown, waiting for in-progress downloads to complete
- WebSocket connections provide real-time updates for download progress
- MusicBrainz integration automatically matches track metadata
- Audio files are transcoded and stored in MinIO with unique keys
- The extension extracts video metadata directly from YouTube/SoundCloud pages

## License

MIT License - see LICENSE file for details
