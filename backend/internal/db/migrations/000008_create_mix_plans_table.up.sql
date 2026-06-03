-- Create saved mix plans table.
-- The client owns playback/rendering; this table stores durable, versioned plan state only.
CREATE TABLE mix_plans (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    name VARCHAR(255) NOT NULL,
    payload JSONB NOT NULL,
    summary JSONB NOT NULL DEFAULT '{}'::jsonb,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_mix_plans_schema_version CHECK (schema_version >= 1),
    CONSTRAINT chk_mix_plans_version CHECK (version >= 1)
);

CREATE INDEX idx_mix_plans_user_updated ON mix_plans(user_id, updated_at DESC);
