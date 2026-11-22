//! Instance sync policy for the SQLite runtime: the administrator-selected
//! per-record revision history limit and the pruning that enforces it.
//!
//! Pruning deletes the oldest `record_versions` rows of one record so that at
//! most the configured number remain, ordered by commit sequence. It never
//! deletes the current head, any row of a redacted record, or a revision that
//! an unresolved conflict branch names as its base. Attachment references of
//! deleted revisions are released through the same delayed collection rule as
//! permanent purge. The ordered `change_events` stream is not touched.

use std::collections::BTreeSet;

use axum::{
    Json,
    extract::{State, rejection::JsonRejection},
    http::HeaderMap,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction};

use crate::{ApiError, AppState, now_rfc3339};

/// Restoring a tombstone reads the revision before the delete, so two rows is
/// the smallest history that keeps the recycle bin working.
pub(crate) const MIN_RECORD_HISTORY_LIMIT: i64 = 2;
pub(crate) const MAX_RECORD_HISTORY_LIMIT: i64 = 1000;
pub(crate) const DEFAULT_RECORD_HISTORY_LIMIT: i64 = 20;

/// Upper bound on revisions removed from one record by one commit or one
/// Maintenance visit. A longer legacy history shrinks over several visits.
pub(crate) const MAX_PRUNED_REVISIONS_PER_RECORD: i64 = 256;
const MAINTENANCE_RECORDS_PER_PAGE: i64 = 200;
const MAINTENANCE_MAX_CANDIDATES_PER_PASS: usize = 5_000;
const MAINTENANCE_MAX_PRUNED_RECORDS_PER_PASS: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SyncPolicySnapshot {
    pub(crate) record_history_limit: i64,
    pub(crate) revision: i64,
    pub(crate) updated_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SyncPolicyUpdateRequest {
    pub(crate) expected_revision: i64,
    pub(crate) record_history_limit: i64,
}

pub(crate) fn policy_json(state: &AppState, snapshot: SyncPolicySnapshot) -> Value {
    json!({
        "record_history_limit": snapshot.record_history_limit,
        "default_record_history_limit": state.config.record_history_limit,
        "min_record_history_limit": MIN_RECORD_HISTORY_LIMIT,
        "max_record_history_limit": MAX_RECORD_HISTORY_LIMIT,
        "revision": snapshot.revision,
        "updated_at": snapshot.updated_at,
    })
}

pub(crate) fn invalid_policy_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_SYNC_POLICY_REQUEST",
        "body must contain only a nonnegative expected_revision and record_history_limit",
    )
}

pub(crate) fn validate_policy_request(request: &SyncPolicyUpdateRequest) -> Result<(), ApiError> {
    if request.expected_revision < 0 {
        return Err(invalid_policy_request());
    }
    if !(MIN_RECORD_HISTORY_LIMIT..=MAX_RECORD_HISTORY_LIMIT)
        .contains(&request.record_history_limit)
    {
        return Err(ApiError::bad_request(
            "RECORD_HISTORY_LIMIT_OUT_OF_RANGE",
            "record_history_limit must be between 2 and 1000",
        )
        .with_details(json!({
            "min_record_history_limit": MIN_RECORD_HISTORY_LIMIT,
            "max_record_history_limit": MAX_RECORD_HISTORY_LIMIT,
        })));
    }
    Ok(())
}

pub(crate) fn policy_conflict() -> ApiError {
    ApiError::conflict(
        "SYNC_POLICY_CONFLICT",
        "sync policy changed since it was read",
    )
}

/// Decides whether a stored conflict branch was written under `revision_id`.
/// Branch attachment references share the `(vault, revision)` key with
/// committed revisions, so an unreadable envelope is treated as a match and
/// keeps the references.
pub(crate) fn conflict_envelope_names_revision(envelope: &str, revision_id: &str) -> bool {
    match serde_json::from_str::<Value>(envelope) {
        Ok(value) => {
            value
                .get("header")
                .and_then(|header| header.get("revision_id"))
                .and_then(Value::as_str)
                == Some(revision_id)
        }
        Err(_) => true,
    }
}

fn snapshot_from_row(
    row: Option<(i64, i64, String)>,
    default_limit: i64,
) -> Result<SyncPolicySnapshot, ApiError> {
    let Some((record_history_limit, revision, updated_at)) = row else {
        return Ok(SyncPolicySnapshot {
            record_history_limit: default_limit,
            revision: 0,
            updated_at: None,
        });
    };
    if revision <= 0
        || !(MIN_RECORD_HISTORY_LIMIT..=MAX_RECORD_HISTORY_LIMIT).contains(&record_history_limit)
    {
        return Err(ApiError::internal("stored sync policy is invalid"));
    }
    Ok(SyncPolicySnapshot {
        record_history_limit,
        revision,
        updated_at: Some(updated_at),
    })
}

const READ_POLICY_SQL: &str =
    "SELECT record_history_limit,revision,updated_at FROM instance_sync_policy WHERE policy_id=1";

async fn read_policy_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
) -> Result<SyncPolicySnapshot, ApiError> {
    let row = sqlx::query_as::<_, (i64, i64, String)>(READ_POLICY_SQL)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    snapshot_from_row(row, state.config.record_history_limit)
}

/// Reads the per-record history limit inside the caller's SQLite transaction:
/// the administrator's selection, or `default_limit` without a policy row.
///
/// The push commit calls this after it holds SQLite's writer reservation, so
/// a policy update that committed before the push became the writer is the
/// one the push enforces.
pub(crate) async fn effective_record_history_limit_tx(
    tx: &mut Transaction<'_, Sqlite>,
    default_limit: i64,
) -> Result<i64, ApiError> {
    let row = sqlx::query_as::<_, (i64, i64, String)>(READ_POLICY_SQL)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(snapshot_from_row(row, default_limit)?.record_history_limit)
}

/// Returns the per-record history limit currently in force on either backend:
/// the administrator's selection, or the deployment default without one.
pub(crate) async fn effective_record_history_limit(state: &AppState) -> Result<i64, ApiError> {
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        return crate::pg_sync_policy::effective_record_history_limit(
            pool,
            state.config.record_history_limit,
        )
        .await;
    }
    let row = sqlx::query_as::<_, (i64, i64, String)>(READ_POLICY_SQL)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(snapshot_from_row(row, state.config.record_history_limit)?.record_history_limit)
}

pub async fn get_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let snapshot = read_policy_tx(&mut tx, &state).await?;
    let response = policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn update_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<SyncPolicyUpdateRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| invalid_policy_request())?;

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    validate_policy_request(&request)?;
    let current = read_policy_tx(&mut tx, &state).await?;
    if request.expected_revision != current.revision {
        return Err(policy_conflict());
    }

    let snapshot = if request.record_history_limit != current.record_history_limit {
        let revision = current
            .revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("sync policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        if current.revision == 0 {
            sqlx::query(
                "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
                 VALUES(1,?,?,?)",
            )
            .bind(request.record_history_limit)
            .bind(revision)
            .bind(&updated_at)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        } else {
            sqlx::query(
                "UPDATE instance_sync_policy SET record_history_limit=?,revision=?,updated_at=? \
                 WHERE policy_id=1 AND revision=?",
            )
            .bind(request.record_history_limit)
            .bind(revision)
            .bind(&updated_at)
            .bind(current.revision)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        crate::audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "admin.sync_policy_updated",
            "sync_policy",
            None,
            chrono::Utc::now().timestamp(),
        )
        .await?;
        SyncPolicySnapshot {
            record_history_limit: request.record_history_limit,
            revision,
            updated_at: Some(updated_at),
        }
    } else {
        current
    };
    let response = policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

/// Deletes the oldest revisions of one record beyond `limit`, at most
/// `MAX_PRUNED_REVISIONS_PER_RECORD` per call, and returns how many rows were
/// removed. The caller must already hold SQLite's writer reservation.
pub(crate) async fn prune_record_history_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    record_id: &str,
    limit: i64,
    gc_after: i64,
) -> Result<u64, ApiError> {
    let limit = limit.clamp(MIN_RECORD_HISTORY_LIMIT, MAX_RECORD_HISTORY_LIMIT);
    // Rank every row of the record so the exclusions below never widen the
    // retained window: an excluded row is kept in addition to the newest
    // `limit` rows.
    let revision_ids: Vec<String> = sqlx::query_scalar(
        "SELECT ranked.revision_id FROM (\
           SELECT v.revision_id,\
                  ROW_NUMBER() OVER (ORDER BY v.commit_seq DESC,v.revision_id DESC) AS row_rank \
           FROM record_versions v WHERE v.vault_id=?1 AND v.record_id=?2\
         ) ranked \
         WHERE ranked.row_rank>?3 \
           AND NOT EXISTS(SELECT 1 FROM record_redactions rr \
                          WHERE rr.vault_id=?1 AND rr.record_id=?2) \
           AND NOT EXISTS(SELECT 1 FROM record_heads h \
                          WHERE h.vault_id=?1 AND h.record_id=?2 \
                            AND h.revision_id=ranked.revision_id) \
           AND NOT EXISTS(SELECT 1 FROM conflicts c \
                          WHERE c.vault_id=?1 AND c.resolved_revision_id IS NULL \
                            AND c.base_revision_id=ranked.revision_id) \
         ORDER BY ranked.row_rank DESC LIMIT ?4",
    )
    .bind(vault_id)
    .bind(record_id)
    .bind(limit)
    .bind(MAX_PRUNED_REVISIONS_PER_RECORD)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if revision_ids.is_empty() {
        return Ok(0);
    }

    let mut deleted = 0_u64;
    for revision_id in &revision_ids {
        deleted += sqlx::query(
            "DELETE FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(revision_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();
    }
    if deleted != revision_ids.len() as u64 {
        return Err(ApiError::internal("record history prune count changed"));
    }

    let mut released_objects = BTreeSet::new();
    for revision_id in &revision_ids {
        let object_ids: Vec<String> = sqlx::query_scalar(
            "SELECT object_id FROM object_references WHERE vault_id=? AND revision_id=? \
             ORDER BY object_id",
        )
        .bind(vault_id)
        .bind(revision_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if object_ids.is_empty() {
            continue;
        }
        // object_references is keyed by Vault and revision ID without a record
        // owner. Legacy data may reuse one revision ID in another record, and
        // a conflict branch stores its references under its attempted revision
        // ID. Keep the rows whenever another holder shares the key.
        let shared_with_revision: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_versions WHERE vault_id=? AND revision_id=?)",
        )
        .bind(vault_id)
        .bind(revision_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if shared_with_revision {
            continue;
        }
        let conflict_envelopes: Vec<String> = sqlx::query_scalar(
            "SELECT envelope FROM conflicts WHERE vault_id=? AND instr(envelope,?)>0",
        )
        .bind(vault_id)
        .bind(revision_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if conflict_envelopes
            .iter()
            .any(|envelope| conflict_envelope_names_revision(envelope, revision_id))
        {
            continue;
        }
        sqlx::query("DELETE FROM object_references WHERE vault_id=? AND revision_id=?")
            .bind(vault_id)
            .bind(revision_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
        released_objects.extend(object_ids);
    }
    if !released_objects.is_empty() {
        let released_objects: Vec<String> = released_objects.into_iter().collect();
        crate::record_purge::schedule_unreferenced_objects_gc_tx(
            tx,
            vault_id,
            &released_objects,
            gc_after,
        )
        .await?;
    }
    Ok(deleted)
}

/// Bounded Maintenance catch-up for records that exceed the current limit:
/// history written before pruning existed, or kept under a larger limit.
/// Returns the number of revisions removed in this pass.
pub(crate) async fn prune_excess_record_history(state: &AppState) -> Result<u64, ApiError> {
    let mut after: Option<(String, String)> = None;
    let mut examined = 0_usize;
    let mut pruned_records = 0_usize;
    let mut pruned_revisions = 0_u64;
    while examined < MAINTENANCE_MAX_CANDIDATES_PER_PASS
        && pruned_records < MAINTENANCE_MAX_PRUNED_RECORDS_PER_PASS
    {
        let limit = effective_record_history_limit(state).await?;
        let (after_vault, after_record) = after.clone().unwrap_or_default();
        let candidates = sqlx::query(
            "SELECT v.vault_id,v.record_id FROM record_versions v \
             WHERE (v.vault_id,v.record_id)>(?,?) \
               AND NOT EXISTS(SELECT 1 FROM record_redactions rr \
                              WHERE rr.vault_id=v.vault_id AND rr.record_id=v.record_id) \
             GROUP BY v.vault_id,v.record_id HAVING COUNT(*)>? \
             ORDER BY v.vault_id,v.record_id LIMIT ?",
        )
        .bind(&after_vault)
        .bind(&after_record)
        .bind(limit)
        .bind(MAINTENANCE_RECORDS_PER_PAGE)
        .fetch_all(&state.db)
        .await
        .map_err(ApiError::internal)?;
        if candidates.is_empty() {
            break;
        }
        for row in &candidates {
            let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
            let record_id: String = row.try_get("record_id").map_err(ApiError::internal)?;
            after = Some((vault_id.clone(), record_id.clone()));
            examined += 1;

            let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
            // Reserve SQLite's writer first, as push and purge do, so the
            // head, conflict, and redaction checks see one committed order.
            let fence = sqlx::query(
                "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
            )
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if fence.rows_affected() != 1 {
                continue;
            }
            let limit = read_policy_tx(&mut tx, state).await?.record_history_limit;
            let gc_after = chrono::Utc::now()
                .timestamp()
                .saturating_add(state.config.object_gc_grace_seconds);
            let deleted =
                prune_record_history_tx(&mut tx, &vault_id, &record_id, limit, gc_after).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            if deleted > 0 {
                pruned_records += 1;
                pruned_revisions += deleted;
            }
            if examined >= MAINTENANCE_MAX_CANDIDATES_PER_PASS
                || pruned_records >= MAINTENANCE_MAX_PRUNED_RECORDS_PER_PASS
            {
                break;
            }
        }
    }
    Ok(pruned_revisions)
}

#[cfg(test)]
mod tests {
    use axum::{
        body::Body,
        http::{
            Request, StatusCode,
            header::{AUTHORIZATION, CONTENT_TYPE},
        },
    };
    use serde_json::{Value, json};
    use tower::ServiceExt;
    use uuid::Uuid;

    use crate::{
        AppState, Config, auth::AuthUser, now_rfc3339, open_state, sha256_hex, sync::Envelope,
        sync::VerifiedOperation, sync_repository::PushCommit,
    };

    const ADMIN_USERNAME: &str = "sync-policy-admin@example.test";
    const GC_GRACE_SECONDS: i64 = 7 * 24 * 60 * 60;

    fn test_config(data_dir: std::path::PathBuf) -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            database_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: None,
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: GC_GRACE_SECONDS,
            record_history_limit: 20,
            admin_usernames: vec![ADMIN_USERNAME.to_owned()],
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn test_state(label: &str) -> AppState {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-sync-policy-{label}-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        open_state(&database_url, test_config(data_dir))
            .await
            .unwrap()
    }

    async fn close_state(state: AppState) {
        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    /// Seeds an account with one active device and bearer session.
    async fn seed_session(state: &AppState, username: &str) -> (AuthUser, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("sync-policy-access-{}", Uuid::new_v4());
        let now = chrono::Utc::now();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(username)
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'sync-policy-test','sign','enc',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(sha256_hex(access.as_bytes()))
            .bind(sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((now + chrono::Duration::hours(1)).to_rfc3339())
            .bind((now + chrono::Duration::days(30)).to_rfc3339())
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        (
            AuthUser {
                user_id,
                device_id,
                session_id,
                access_hash: sha256_hex(access.as_bytes()),
                declares_record_schema2: false,
                declares_sync_redaction_v1: true,
            },
            access,
        )
    }

    async fn seed_owned_vault(state: &AppState, owner: &AuthUser) -> String {
        let vault_id = Uuid::new_v4().to_string();
        let created = now_rfc3339();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(&owner.user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) \
             VALUES(?,?,'owner','active',?)",
        )
        .bind(&vault_id)
        .bind(&owner.user_id)
        .bind(&created)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id) VALUES(?)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        vault_id
    }

    /// Commits one operation through the repository with an explicit limit
    /// and returns the new revision ID.
    struct Writer<'a> {
        state: &'a AppState,
        user: &'a AuthUser,
        vault_id: &'a str,
        device_seq: u64,
    }

    impl Writer<'_> {
        async fn commit(
            &mut self,
            record_id: &str,
            base: Option<&str>,
            operation: &str,
            object_refs: &[String],
            record_history_limit: i64,
        ) -> String {
            self.device_seq += 1;
            let revision_id = Uuid::new_v4().to_string();
            let mut object_refs = object_refs.to_vec();
            object_refs.sort();
            let operation = VerifiedOperation {
                record_id: record_id.to_owned(),
                revision_id: revision_id.clone(),
                op_id: Uuid::new_v4().to_string(),
                record_schema: 1,
                device_seq: self.device_seq.to_string(),
                key_epoch: 1,
                membership_version: 1,
                operation: operation.to_owned(),
                base: base.map(str::to_owned),
                object_refs,
                env: Envelope {
                    header: json!({"record_schema":1,"revision_id":revision_id}),
                    nonce: "n".to_owned(),
                    ciphertext: format!("ciphertext-{}", self.device_seq),
                    signature: "signature".to_owned(),
                },
            };
            let batch_id = Uuid::new_v4().to_string();
            self.state
                .sync_repository
                .commit_batch(PushCommit {
                    user: self.user.clone(),
                    vault_id: self.vault_id.to_owned(),
                    device_id: self.user.device_id.clone(),
                    request_digest: format!("request-{batch_id}"),
                    batch_id,
                    operations: vec![operation],
                    restore_retention_days: 30,
                    default_record_history_limit: record_history_limit,
                    object_gc_grace_seconds: GC_GRACE_SECONDS,
                })
                .await
                .unwrap();
            revision_id
        }

        /// Creates a record and applies `updates` updates; returns every
        /// revision ID oldest first.
        async fn history(
            &mut self,
            record_id: &str,
            updates: usize,
            record_history_limit: i64,
        ) -> Vec<String> {
            let mut revisions = vec![
                self.commit(record_id, None, "create", &[], record_history_limit)
                    .await,
            ];
            for _ in 0..updates {
                let base = revisions.last().unwrap().clone();
                revisions.push(
                    self.commit(record_id, Some(&base), "update", &[], record_history_limit)
                        .await,
                );
            }
            revisions
        }
    }

    async fn retained(state: &AppState, vault_id: &str, record_id: &str) -> Vec<String> {
        sqlx::query_scalar(
            "SELECT revision_id FROM record_versions WHERE vault_id=? AND record_id=? \
             ORDER BY commit_seq",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(&state.db)
        .await
        .unwrap()
    }

    async fn head(state: &AppState, vault_id: &str, record_id: &str) -> String {
        sqlx::query_scalar("SELECT revision_id FROM record_heads WHERE vault_id=? AND record_id=?")
            .bind(vault_id)
            .bind(record_id)
            .fetch_one(&state.db)
            .await
            .unwrap()
    }

    async fn insert_conflict(
        state: &AppState,
        vault_id: &str,
        record_id: &str,
        base_revision_id: Option<&str>,
        attempted_revision_id: &str,
        conflict_seq: i64,
    ) -> String {
        let conflict_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES(?,?,?,?,?,'digest','device',?,?,?)")
            .bind(&conflict_id)
            .bind(vault_id)
            .bind(record_id)
            .bind(base_revision_id)
            .bind(json!({"header":{"revision_id":attempted_revision_id}}).to_string())
            .bind(now_rfc3339())
            .bind(conflict_seq)
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();
        conflict_id
    }

    async fn insert_object(state: &AppState, vault_id: &str) -> String {
        let object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'01',1,'hash',?,NULL)")
            .bind(vault_id)
            .bind(&object_id)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        object_id
    }

    async fn object_gc_after(state: &AppState, vault_id: &str, object_id: &str) -> Option<i64> {
        sqlx::query_scalar("SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?")
            .bind(vault_id)
            .bind(object_id)
            .fetch_one(&state.db)
            .await
            .unwrap()
    }

    async fn reference_count(state: &AppState, vault_id: &str, revision_id: &str) -> i64 {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=?",
        )
        .bind(vault_id)
        .bind(revision_id)
        .fetch_one(&state.db)
        .await
        .unwrap()
    }

    /// Marks an already tombstoned record as redacted without running purge.
    async fn insert_redaction(
        state: &AppState,
        vault_id: &str,
        record_id: &str,
        deleted_revision_id: &str,
    ) {
        let deleted_seq: i64 = sqlx::query_scalar(
            "SELECT deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,?,?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(vault_id)
            .bind(record_id)
            .bind(deleted_revision_id)
            .bind(deleted_seq)
            .bind(deleted_seq + 1_000_000)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
    }

    async fn call(
        state: &AppState,
        method: &str,
        uri: &str,
        bearer: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("x-atermius-redaction-marker", "v1");
        if let Some(token) = bearer {
            builder = builder.header(AUTHORIZATION, format!("Bearer {token}"));
        }
        let request = match body {
            Some(body) => builder
                .header(CONTENT_TYPE, "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
                .unwrap(),
            None => builder.body(Body::empty()).unwrap(),
        };
        let response = crate::router(state.clone())
            .await
            .oneshot(request)
            .await
            .unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn commit_keeps_the_newest_twenty_revisions_and_the_head() {
        let state = test_state("commit").await;
        let (user, _) = seed_session(&state, "writer@example.test").await;
        let vault_id = seed_owned_vault(&state, &user).await;
        let record_id = Uuid::new_v4().to_string();
        let limit = super::effective_record_history_limit(&state).await.unwrap();
        assert_eq!(limit, 20);
        let mut writer = Writer {
            state: &state,
            user: &user,
            vault_id: &vault_id,
            device_seq: 0,
        };

        // One create plus 25 updates: 26 revisions were committed.
        let revisions = writer.history(&record_id, 25, limit).await;
        assert_eq!(revisions.len(), 26);
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            revisions[6..].to_vec(),
            "exactly the newest 20 revisions remain, in commit order"
        );
        assert_eq!(head(&state, &vault_id, &record_id).await, revisions[25]);

        // The ordered pull stream has its own retention and is not pruned.
        let events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(events, 26);

        // A pruned revision is gone; the retained window is still readable,
        // and the oldest retained row keeps a base that names a pruned row.
        let oldest_base: Option<String> = sqlx::query_scalar(
            "SELECT base_revision_id FROM record_versions WHERE vault_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&revisions[6])
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(oldest_base.as_deref(), Some(revisions[5].as_str()));

        // A further update against the head still passes compare-and-set.
        let next = writer
            .commit(&record_id, Some(&revisions[25]), "update", &[], limit)
            .await;
        let now = retained(&state, &vault_id, &record_id).await;
        assert_eq!(now.len(), 20);
        assert_eq!(now.first(), Some(&revisions[7]));
        assert_eq!(now.last(), Some(&next));

        let (status, instance) = call(&state, "GET", "/api/v1/instance", None, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(instance["limits"]["record_history_limit"], 20);
        close_state(state).await;
    }

    #[tokio::test]
    async fn tombstone_keeps_its_previous_revision_at_the_minimum_limit() {
        let state = test_state("tombstone").await;
        let (user, _) = seed_session(&state, "writer@example.test").await;
        let vault_id = seed_owned_vault(&state, &user).await;
        let record_id = Uuid::new_v4().to_string();
        let mut writer = Writer {
            state: &state,
            user: &user,
            vault_id: &vault_id,
            device_seq: 0,
        };
        let revisions = writer.history(&record_id, 3, 2).await;
        let tombstone = writer
            .commit(&record_id, Some(&revisions[3]), "delete", &[], 2)
            .await;
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            vec![revisions[3].clone(), tombstone.clone()]
        );
        // The restore compare-and-set and deadline read use the tombstone.
        let restored = writer
            .commit(&record_id, Some(&tombstone), "restore", &[], 2)
            .await;
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            vec![tombstone, restored]
        );
        close_state(state).await;
    }

    #[tokio::test]
    async fn a_changed_limit_applies_to_the_next_push_without_lag() {
        let state = test_state("immediate").await;
        let (admin, admin_access) = seed_session(&state, ADMIN_USERNAME).await;
        let vault_id = seed_owned_vault(&state, &admin).await;
        let record_id = Uuid::new_v4().to_string();
        let uri = format!("/api/v1/vaults/{vault_id}/records/{record_id}/revisions");
        let mut writer = Writer {
            state: &state,
            user: &admin,
            vault_id: &vault_id,
            device_seq: 0,
        };
        // Ten revisions under the deployment default; nothing is pruned.
        let mut revisions = writer.history(&record_id, 9, 20).await;
        assert_eq!(retained(&state, &vault_id, &record_id).await, revisions);

        let (status, updated) = call(
            &state,
            "PUT",
            "/api/v1/admin/sync-policy",
            Some(&admin_access),
            Some(json!({"expected_revision":0,"record_history_limit":3})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(updated["record_history_limit"], 3);
        assert_eq!(retained(&state, &vault_id, &record_id).await, revisions);

        // The very next push prunes to the new limit. The writer still passes
        // the deployment default of 20: the commit transaction reads the
        // policy row itself, so no earlier read can be stale.
        let next = writer
            .commit(
                &record_id,
                revisions.last().map(String::as_str),
                "update",
                &[],
                20,
            )
            .await;
        revisions.push(next);
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            revisions[8..].to_vec(),
            "one push after the policy change keeps exactly the new limit"
        );

        // The history route and the public instance document report the same
        // policy row.
        let (status, history) = call(&state, "GET", &uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(history["record_history_limit"], 3);
        assert_eq!(history["revisions"].as_array().unwrap().len(), 3);
        let (_, instance) = call(&state, "GET", "/api/v1/instance", None, None).await;
        assert_eq!(instance["limits"]["record_history_limit"], 3);

        // Lowering it again also applies to the next push.
        let (status, _) = call(
            &state,
            "PUT",
            "/api/v1/admin/sync-policy",
            Some(&admin_access),
            Some(json!({"expected_revision":1,"record_history_limit":2})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let next = writer
            .commit(
                &record_id,
                revisions.last().map(String::as_str),
                "update",
                &[],
                20,
            )
            .await;
        revisions.push(next);
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            revisions[10..].to_vec()
        );
        let (_, history) = call(&state, "GET", &uri, Some(&admin_access), None).await;
        assert_eq!(history["record_history_limit"], 2);
        assert_eq!(history["revisions"].as_array().unwrap().len(), 2);

        // Without a policy row the deployment default passed by the caller
        // is the fallback.
        sqlx::query("DELETE FROM instance_sync_policy")
            .execute(&state.db)
            .await
            .unwrap();
        for _ in 0..3 {
            let next = writer
                .commit(
                    &record_id,
                    revisions.last().map(String::as_str),
                    "update",
                    &[],
                    4,
                )
                .await;
            revisions.push(next);
        }
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            revisions[revisions.len() - 4..].to_vec()
        );
        close_state(state).await;
    }

    #[tokio::test]
    async fn lowering_the_limit_prunes_at_maintenance_and_skips_redacted_records() {
        let state = test_state("maintenance").await;
        let (admin, admin_access) = seed_session(&state, ADMIN_USERNAME).await;
        let vault_id = seed_owned_vault(&state, &admin).await;
        let live_record = Uuid::new_v4().to_string();
        let redacted_record = Uuid::new_v4().to_string();
        let mut writer = Writer {
            state: &state,
            user: &admin,
            vault_id: &vault_id,
            device_seq: 0,
        };
        let live = writer.history(&live_record, 9, 20).await;
        let mut redacted = writer.history(&redacted_record, 5, 20).await;
        let tombstone = writer
            .commit(
                &redacted_record,
                redacted.last().map(String::as_str),
                "delete",
                &[],
                20,
            )
            .await;
        redacted.push(tombstone.clone());
        insert_redaction(&state, &vault_id, &redacted_record, &tombstone).await;

        // Nothing exceeds the default limit, so Maintenance removes nothing.
        assert_eq!(super::prune_excess_record_history(&state).await.unwrap(), 0);
        assert_eq!(retained(&state, &vault_id, &live_record).await, live);

        let (status, updated) = call(
            &state,
            "PUT",
            "/api/v1/admin/sync-policy",
            Some(&admin_access),
            Some(json!({"expected_revision":0,"record_history_limit":3})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(updated["record_history_limit"], 3);
        // Lowering the limit does not prune by itself.
        assert_eq!(retained(&state, &vault_id, &live_record).await, live);

        crate::run_maintenance(&state).await.unwrap();
        assert_eq!(
            retained(&state, &vault_id, &live_record).await,
            live[7..].to_vec()
        );
        assert_eq!(head(&state, &vault_id, &live_record).await, live[9]);
        assert_eq!(
            retained(&state, &vault_id, &redacted_record).await,
            redacted,
            "every row of a redacted record is left alone"
        );

        // A second pass is a no-op.
        assert_eq!(super::prune_excess_record_history(&state).await.unwrap(), 0);
        close_state(state).await;
    }

    #[tokio::test]
    async fn unresolved_conflict_base_survives_until_the_conflict_is_resolved() {
        let state = test_state("conflict-base").await;
        let (user, _) = seed_session(&state, "writer@example.test").await;
        let vault_id = seed_owned_vault(&state, &user).await;
        let record_id = Uuid::new_v4().to_string();
        let mut writer = Writer {
            state: &state,
            user: &user,
            vault_id: &vault_id,
            device_seq: 0,
        };
        let mut revisions = writer.history(&record_id, 1, 2).await;
        let conflict_id = insert_conflict(
            &state,
            &vault_id,
            &record_id,
            Some(&revisions[0]),
            &Uuid::new_v4().to_string(),
            1,
        )
        .await;
        for _ in 0..3 {
            let base = revisions.last().unwrap().clone();
            revisions.push(
                writer
                    .commit(&record_id, Some(&base), "update", &[], 2)
                    .await,
            );
        }
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            vec![
                revisions[0].clone(),
                revisions[3].clone(),
                revisions[4].clone()
            ],
            "the conflict base is kept in addition to the newest two revisions"
        );
        // The policy row drives Maintenance; store the limit used above.
        sqlx::query(
            "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
             VALUES(1,2,1,?)",
        )
        .bind(now_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
        assert_eq!(super::prune_excess_record_history(&state).await.unwrap(), 0);

        sqlx::query(
            "UPDATE conflicts SET resolved_revision_id=?,resolution_seq=2,resolution_at=? \
             WHERE conflict_id=?",
        )
        .bind(&revisions[4])
        .bind(now_rfc3339())
        .bind(&conflict_id)
        .execute(&state.db)
        .await
        .unwrap();
        assert_eq!(super::prune_excess_record_history(&state).await.unwrap(), 1);
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            revisions[3..].to_vec()
        );
        close_state(state).await;
    }

    #[tokio::test]
    async fn pruned_revisions_release_only_unshared_object_references() {
        let state = test_state("objects").await;
        let (user, _) = seed_session(&state, "writer@example.test").await;
        let vault_id = seed_owned_vault(&state, &user).await;
        let record_id = Uuid::new_v4().to_string();
        let only_first = insert_object(&state, &vault_id).await;
        let kept_by_later = insert_object(&state, &vault_id).await;
        let shared_with_conflict = insert_object(&state, &vault_id).await;
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,1,'hash',1048576,'completed',?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(&user.user_id)
            .bind(&only_first)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let mut writer = Writer {
            state: &state,
            user: &user,
            vault_id: &vault_id,
            device_seq: 0,
        };

        let first = writer
            .commit(
                &record_id,
                None,
                "create",
                &[only_first.clone(), kept_by_later.clone()],
                2,
            )
            .await;
        let second = writer
            .commit(
                &record_id,
                Some(&first),
                "update",
                &[kept_by_later.clone(), shared_with_conflict.clone()],
                2,
            )
            .await;
        // A conflict branch stored under the same revision ID shares the
        // (vault, revision) reference key with the second revision.
        insert_conflict(&state, &vault_id, &record_id, None, &second, 1).await;
        assert_eq!(reference_count(&state, &vault_id, &first).await, 2);

        let before = chrono::Utc::now().timestamp();
        let third = writer
            .commit(
                &record_id,
                Some(&second),
                "update",
                std::slice::from_ref(&kept_by_later),
                2,
            )
            .await;
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            vec![second.clone(), third.clone()]
        );
        assert_eq!(reference_count(&state, &vault_id, &first).await, 0);
        let scheduled = object_gc_after(&state, &vault_id, &only_first)
            .await
            .expect("the object only the pruned revision referenced is scheduled");
        assert!(
            (before + GC_GRACE_SECONDS..=before + GC_GRACE_SECONDS + 60).contains(&scheduled),
            "pruning uses the normal object grace period"
        );
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE vault_id=? AND object_id=?")
                .bind(&vault_id)
                .bind(&only_first)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(upload_state, "collected");
        assert_eq!(
            object_gc_after(&state, &vault_id, &kept_by_later).await,
            None,
            "an object a retained revision still references is not scheduled"
        );

        let fourth = writer
            .commit(&record_id, Some(&third), "update", &[], 2)
            .await;
        assert_eq!(
            retained(&state, &vault_id, &record_id).await,
            vec![third, fourth]
        );
        assert_eq!(
            reference_count(&state, &vault_id, &second).await,
            2,
            "references shared with a conflict branch are kept"
        );
        assert_eq!(
            object_gc_after(&state, &vault_id, &shared_with_conflict).await,
            None
        );
        assert_eq!(
            object_gc_after(&state, &vault_id, &kept_by_later).await,
            None
        );
        close_state(state).await;
    }

    #[tokio::test]
    async fn admin_route_enforces_auth_range_and_revision_and_audits_changes() {
        let state = test_state("admin").await;
        let (admin, admin_access) = seed_session(&state, ADMIN_USERNAME).await;
        let (_, member_access) = seed_session(&state, "member@example.test").await;
        let uri = "/api/v1/admin/sync-policy";
        let valid = json!({"expected_revision":0,"record_history_limit":50});

        let (status, _) = call(&state, "GET", uri, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        for (method, body) in [("GET", None), ("PUT", Some(valid.clone()))] {
            let (status, body) = call(&state, method, uri, Some(&member_access), body).await;
            assert_eq!(status, StatusCode::FORBIDDEN);
            assert_eq!(body["error"]["code"], "INSTANCE_ADMIN_REQUIRED");
        }

        let (status, initial) = call(&state, "GET", uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            initial,
            json!({
                "record_history_limit": 20,
                "default_record_history_limit": 20,
                "min_record_history_limit": 2,
                "max_record_history_limit": 1000,
                "revision": 0,
                "updated_at": null,
            })
        );

        for limit in [1, 1001, 0, -5] {
            let (status, body) = call(
                &state,
                "PUT",
                uri,
                Some(&admin_access),
                Some(json!({"expected_revision":0,"record_history_limit":limit})),
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert_eq!(body["error"]["code"], "RECORD_HISTORY_LIMIT_OUT_OF_RANGE");
            assert_eq!(body["error"]["details"]["min_record_history_limit"], 2);
            assert_eq!(body["error"]["details"]["max_record_history_limit"], 1000);
        }
        for malformed in [
            json!({"record_history_limit":50}),
            json!({"expected_revision":0}),
            json!({"expected_revision":"0","record_history_limit":50}),
            json!({"expected_revision":-1,"record_history_limit":50}),
            json!({"expected_revision":0,"record_history_limit":50,"extra":true}),
        ] {
            let (status, body) =
                call(&state, "PUT", uri, Some(&admin_access), Some(malformed)).await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert_eq!(body["error"]["code"], "INVALID_SYNC_POLICY_REQUEST");
        }
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_sync_policy")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(rows, 0, "rejected requests store nothing");

        let (status, changed) = call(&state, "PUT", uri, Some(&admin_access), Some(valid)).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(changed["record_history_limit"], 50);
        assert_eq!(changed["default_record_history_limit"], 20);
        assert_eq!(changed["revision"], 1);
        assert!(changed["updated_at"].as_str().is_some());
        assert_eq!(
            super::effective_record_history_limit(&state).await.unwrap(),
            50
        );

        let (status, stale) = call(
            &state,
            "PUT",
            uri,
            Some(&admin_access),
            Some(json!({"expected_revision":0,"record_history_limit":60})),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(stale["error"]["code"], "SYNC_POLICY_CONFLICT");

        let (status, unchanged) = call(
            &state,
            "PUT",
            uri,
            Some(&admin_access),
            Some(json!({"expected_revision":1,"record_history_limit":50})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(unchanged, changed, "an unchanged value is idempotent");

        let audit: (i64, Option<String>, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT COUNT(*),MAX(actor_user_id),MAX(actor_device_id),MAX(resource_type) \
             FROM audit_events WHERE action='admin.sync_policy_updated'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            audit,
            (
                1,
                Some(admin.user_id.clone()),
                Some(admin.device_id.clone()),
                Some("sync_policy".to_owned())
            )
        );

        let (status, read_back) = call(&state, "GET", uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(read_back, changed);
        let (_, instance) = call(&state, "GET", "/api/v1/instance", None, None).await;
        assert_eq!(instance["limits"]["record_history_limit"], 50);
        close_state(state).await;
    }

    #[tokio::test]
    async fn record_history_route_returns_newest_first_with_read_authorization() {
        let state = test_state("history-route").await;
        let (admin, admin_access) = seed_session(&state, ADMIN_USERNAME).await;
        let (_, outsider_access) = seed_session(&state, "outsider@example.test").await;
        let vault_id = seed_owned_vault(&state, &admin).await;
        let record_id = Uuid::new_v4().to_string();
        let mut writer = Writer {
            state: &state,
            user: &admin,
            vault_id: &vault_id,
            device_seq: 0,
        };
        let created = writer.commit(&record_id, None, "create", &[], 20).await;
        let updated = writer
            .commit(&record_id, Some(&created), "update", &[], 20)
            .await;
        let deleted = writer
            .commit(&record_id, Some(&updated), "delete", &[], 20)
            .await;
        let uri = format!("/api/v1/vaults/{vault_id}/records/{record_id}/revisions");

        let (status, body) = call(&state, "GET", &uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::OK);
        let mut top_level: Vec<&str> = body
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        top_level.sort_unstable();
        assert_eq!(
            top_level,
            ["record_history_limit", "record_id", "revisions", "vault_id"]
        );
        assert_eq!(body["vault_id"], vault_id);
        assert_eq!(body["record_id"], record_id);
        assert_eq!(body["record_history_limit"], 20);
        let revisions = body["revisions"].as_array().unwrap();
        assert_eq!(
            revisions
                .iter()
                .map(|revision| revision["revision_id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            [deleted.as_str(), updated.as_str(), created.as_str()]
        );
        for revision in revisions {
            let mut keys: Vec<&str> = revision
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            keys.sort_unstable();
            assert_eq!(
                keys,
                [
                    "base_revision_id",
                    "commit_seq",
                    "created_at",
                    "deleted",
                    "device_id",
                    "envelope",
                    "operation",
                    "restore_until",
                    "revision_id"
                ]
            );
            assert_eq!(revision["device_id"], admin.device_id);
            assert_eq!(
                revision["envelope"]["header"]["revision_id"],
                revision["revision_id"]
            );
        }
        assert_eq!(revisions[0]["commit_seq"], "3");
        assert_eq!(revisions[0]["operation"], "delete");
        assert_eq!(revisions[0]["deleted"], true);
        assert_eq!(revisions[0]["base_revision_id"], updated);
        assert!(revisions[0]["restore_until"].as_str().is_some());
        assert_eq!(revisions[1]["commit_seq"], "2");
        assert_eq!(revisions[1]["deleted"], false);
        assert_eq!(revisions[1]["restore_until"], Value::Null);
        assert_eq!(revisions[2]["commit_seq"], "1");
        assert_eq!(revisions[2]["operation"], "create");
        assert_eq!(revisions[2]["base_revision_id"], Value::Null);

        let (status, _) = call(&state, "GET", &uri, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, body) = call(&state, "GET", &uri, Some(&outsider_access), None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body["error"]["code"], "NOT_FOUND");
        let unknown = format!(
            "/api/v1/vaults/{vault_id}/records/{}/revisions",
            Uuid::new_v4()
        );
        let (status, body) = call(&state, "GET", &unknown, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body["error"]["code"], "NOT_FOUND");

        // The effective limit also caps rows that Maintenance has not pruned.
        let (status, _) = call(
            &state,
            "PUT",
            "/api/v1/admin/sync-policy",
            Some(&admin_access),
            Some(json!({"expected_revision":0,"record_history_limit":2})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, body) = call(&state, "GET", &uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["record_history_limit"], 2);
        assert_eq!(
            body["revisions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|revision| revision["revision_id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            [deleted.as_str(), updated.as_str()]
        );

        insert_redaction(&state, &vault_id, &record_id, &deleted).await;
        let (status, body) = call(&state, "GET", &uri, Some(&admin_access), None).await;
        assert_eq!(status, StatusCode::GONE);
        assert_eq!(body["error"]["code"], "RECORD_REDACTED");
        assert_eq!(
            body["error"]["details"]["redaction"]["record_id"],
            record_id
        );
        close_state(state).await;
    }

    #[test]
    fn conflict_reference_ownership_matches_only_the_attempted_revision() {
        let revision = "11111111-1111-4111-8111-111111111111";
        let envelope = json!({"header":{"revision_id":revision,"base_revision_id":"other"}});
        assert!(super::conflict_envelope_names_revision(
            &envelope.to_string(),
            revision
        ));
        let based_on = json!({"header":{"revision_id":"other","base_revision_id":revision}});
        assert!(!super::conflict_envelope_names_revision(
            &based_on.to_string(),
            revision
        ));
        assert!(!super::conflict_envelope_names_revision("{}", revision));
        assert!(super::conflict_envelope_names_revision(
            "not json", revision
        ));
    }
}
