-- Intentionally irreversible: persisted variant assignment is execution
-- authority. Removing these columns during a rollback would reinterpret direct
-- or dark jobs on the next startup. Older binaries tolerate the additive
-- columns, constraints, and trigger, so down is a compatibility-preserving
-- no-op. A following up migration is likewise safe and leaves assignments
-- unchanged.
SELECT 1;
