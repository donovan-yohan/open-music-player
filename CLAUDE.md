# Open Music Player - AI Assistant Guidelines

This document provides context and guidelines for AI assistants working on the Open Music Player codebase.

## Project Overview

Open Music Player is a self-hosted music library management system with four main components:

| Component | Language | Location | Purpose |
|-----------|----------|----------|---------|
| Backend | Go | `backend/` | REST API server |
| Client | Flutter/Dart | `client/` | Cross-platform mobile/desktop/web app |
| Extension | TypeScript | `extension/` | Browser extension for Chrome/Firefox |
| Tools | Rust | `src/` | Database migrations and MusicBrainz API client |

## Development Commands

### Backend (Go)
```bash
cd backend
go run ./cmd/server          # Start server
go test ./...                # Run tests
make migrate-up              # Run migrations
```

### Client (Flutter)
```bash
cd client
flutter pub get              # Install dependencies
flutter run                  # Run on connected device
flutter test                 # Run tests
```

### Extension (TypeScript)
```bash
cd extension
npm install                  # Install dependencies
npm run dev                  # Development build with watch
npm run build                # Production build
```

### Rust Tools
```bash
cargo run                    # Run migrations
cargo test                   # Run tests (requires DATABASE_URL)
```

### Infrastructure
```bash
docker compose up -d         # Start PostgreSQL, Redis, MinIO
docker compose down          # Stop services
```

## Architecture Notes

### Authentication
- JWT-based authentication
- Tokens issued by backend, stored client-side
- Refresh token rotation enabled

### Audio Pipeline
1. User submits URL via extension or client
2. Backend queues download job in Redis
3. Worker uses yt-dlp to download audio
4. Audio stored in MinIO (S3-compatible)
5. Metadata matched via MusicBrainz API
6. Track added to user's library

### Database Schema
Key tables: `users`, `tracks`, `user_library`, `playlists`, `playlist_tracks`, `download_jobs`

Migrations are in `migrations/` directory using sqlx.

## Code Conventions

### Go (Backend)
- Standard Go project layout
- Handlers in `internal/api/`
- Business logic in respective `internal/` packages
- Use `context.Context` for cancellation
- Errors wrapped with `fmt.Errorf("...: %w", err)`

### Flutter (Client)
- Provider pattern for state management
- Widgets in `lib/widgets/`
- Services in `lib/services/`
- Models in `lib/models/`

### TypeScript (Extension)
- Manifest V3 for Chrome extension
- Webpack for bundling
- Content scripts inject into YouTube/SoundCloud pages

### Rust (Tools)
- Async with Tokio runtime
- sqlx for database access with compile-time query checking
- MusicBrainz client respects 1 req/sec rate limit
- Error handling with `thiserror` and `anyhow`

## Testing

### Running Tests
```bash
# Backend (requires PostgreSQL and Redis)
cd backend && go test -v ./...

# Client
cd client && flutter test

# Extension
cd extension && npm run type-check

# Rust (requires DATABASE_URL)
cargo test
```

### Test Database
Tests use a separate database. Set `DATABASE_URL` environment variable for test runs.

## Environment Variables

Key variables (see `.env.example` for full list):

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `JWT_SECRET` | Secret for JWT signing |
| `MINIO_*` | MinIO/S3 configuration |

## Common Tasks

### Adding a new API endpoint
1. Add route in `backend/internal/api/router.go`
2. Create handler in appropriate `internal/api/` file
3. Add service method if business logic needed
4. Add repository method if database access needed
5. Write tests

### Adding a new Flutter screen
1. Create widget in `client/lib/screens/`
2. Add route in navigation
3. Create provider if state management needed
4. Write widget tests

### Adding a database migration
```bash
cd backend
make migrate-create
# Enter migration name when prompted
# Edit the generated up/down SQL files
make migrate-up
```

## CI/CD

GitHub Actions workflow runs on push to main and PRs:
- Backend: lint, test, build
- Client: analyze, test
- Extension: type-check, build

## Gas Town Integration

This repo is managed by Gas Town, a multi-agent workspace manager. Key files:
- `.beads/` - Issue tracking
- `docs/MERGE_QUEUE_CI_VERIFICATION.md` - CI verification process

Polecats (worker agents) submit work via `gt done` to the merge queue.
