CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- health_samples, workouts and workout_route_points are hypertables
-- (20260409000005 onwards), so the extension has to exist before those run.
-- It must also be in shared_preload_libraries on the server.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
