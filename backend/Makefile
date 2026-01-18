# Database configuration
DB_URL ?= postgres://postgres:postgres@localhost:5432/openmusicplayer?sslmode=disable
MIGRATIONS_PATH = internal/db/migrations

.PHONY: migrate-up migrate-down migrate-version migrate-force migrate-create

# Run all up migrations
migrate-up:
	migrate -path $(MIGRATIONS_PATH) -database "$(DB_URL)" up

# Rollback all migrations
migrate-down:
	migrate -path $(MIGRATIONS_PATH) -database "$(DB_URL)" down

# Rollback last migration
migrate-down-1:
	migrate -path $(MIGRATIONS_PATH) -database "$(DB_URL)" down 1

# Show current migration version
migrate-version:
	migrate -path $(MIGRATIONS_PATH) -database "$(DB_URL)" version

# Force set migration version (use with caution)
migrate-force:
	@read -p "Enter version to force: " version; \
	migrate -path $(MIGRATIONS_PATH) -database "$(DB_URL)" force $$version

# Create a new migration
migrate-create:
	@read -p "Enter migration name: " name; \
	migrate create -ext sql -dir $(MIGRATIONS_PATH) -seq $$name

# Validate SQL files exist and are non-empty
migrate-validate:
	@echo "Validating migration files..."
	@for f in $(MIGRATIONS_PATH)/*.sql; do \
		if [ ! -s "$$f" ]; then \
			echo "Error: Empty file $$f"; \
			exit 1; \
		fi; \
		echo "OK: $$f"; \
	done
	@echo "All migration files valid"
