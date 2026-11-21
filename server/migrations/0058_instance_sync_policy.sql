-- The row is created lazily when an administrator first changes the policy.
-- With no row, revision 0 is the deployment default
-- (ATERMIUS_RECORD_HISTORY_LIMIT, 20 when unset).
CREATE TABLE instance_sync_policy (
    policy_id INTEGER PRIMARY KEY CHECK (policy_id = 1),
    record_history_limit INTEGER NOT NULL CHECK (record_history_limit BETWEEN 2 AND 1000),
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);
