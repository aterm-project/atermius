CREATE TABLE account_vault_key_wraps (
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    key_epoch BIGINT NOT NULL CHECK (key_epoch > 0),
    envelope TEXT NOT NULL,
    PRIMARY KEY (user_id, vault_id, key_epoch)
);
