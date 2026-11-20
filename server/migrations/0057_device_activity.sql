CREATE TABLE device_activity (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    platform TEXT NOT NULL,
    device_name TEXT,
    user_agent TEXT,
    browser_ips TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX idx_sessions_live_device
    ON sessions(user_id, device_id, refresh_expires_at)
    WHERE revoked_at IS NULL;
