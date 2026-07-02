.PHONY: help run test

help:
	@printf 'Open Music Player backend targets:\n'
	@printf '  make run   - start the Go backend; startup runs the idempotent schema in internal/db/db.go\n'
	@printf '  make test  - run backend Go tests\n'

run:
	go run ./cmd/server

test:
	go test ./...
