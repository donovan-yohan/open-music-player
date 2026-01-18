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

### Production Environment Variables

For production, set these additional environment variables:

```bash
# Security
JWT_SECRET=your-secure-random-secret-here

# Database (use your production database)
DB_HOST=your-postgres-host
DB_PORT=5432
DB_USER=openmusicplayer
DB_PASSWORD=secure-password
DB_NAME=openmusicplayer

# Redis
REDIS_URL=redis://your-redis-host:6379

# MinIO/S3 Storage
MINIO_ENDPOINT=https://your-s3-endpoint
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=audio-files
MINIO_USE_SSL=true

# Server
SERVER_ADDR=:8080
WORKER_COUNT=5
```

### Docker Deployment

Build and run the backend:

```bash
# Build the backend image
docker build -t openmusicplayer-backend ./backend

# Run with environment file
docker run -d \
  --name omp-backend \
  --env-file .env.production \
  -p 8080:8080 \
  openmusicplayer-backend
```

### Kubernetes/Cloud Deployment

For production deployments:

1. Deploy PostgreSQL (use managed service like AWS RDS, Cloud SQL, etc.)
2. Deploy Redis (use managed service like ElastiCache, Memorystore, etc.)
3. Configure S3 or MinIO for object storage
4. Deploy the backend as a container with horizontal scaling
5. Set up a reverse proxy (nginx, Traefik) with TLS termination
6. Configure CORS for your frontend domains

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
