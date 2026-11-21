-- The row is created lazily when an administrator first changes the policy.
-- With no row, revision 0 is the deployment default
-- (ATERMIUS_RECORD_HISTORY_LIMIT, 20 when unset).
CREATE TABLE instance_sync_policy (
    policy_id SMALLINT PRIMARY KEY,
    record_history_limit INTEGER NOT NULL,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT instance_sync_policy_singleton_check CHECK (policy_id = 1),
    CONSTRAINT instance_sync_policy_limit_check CHECK (record_history_limit BETWEEN 2 AND 1000),
    CONSTRAINT instance_sync_policy_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807)
);

INSERT INTO atermius_instance_schema(singleton,schema_version)
VALUES (1,42)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);
