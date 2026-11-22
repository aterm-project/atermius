//! PostgreSQL counterpart of `sync_policy`: the administrator-selected
//! per-record revision history limit and the pruning that enforces it.
//!
//! Pruning runs under the Vault row lock that push and permanent purge take,
//! applies the same exclusions as the SQLite adapter, and releases attachment
//! references through the delayed collection rule shared with purge.

use std::collections::BTreeSet;

use axum::{
    Json,
    extract::{State, rejection::JsonRejection},
    http::HeaderMap,
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::Value;
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{
    ApiError, AppState,
    auth::AuthUser,
    sync_policy::{
        MAX_PRUNED_REVISIONS_PER_RECORD, MAX_RECORD_HISTORY_LIMIT, MIN_RECORD_HISTORY_LIMIT,
        SyncPolicySnapshot, SyncPolicyUpdateRequest, conflict_envelope_names_revision,
        invalid_policy_request, policy_conflict, policy_json, validate_policy_request,
    },
};

type PgTx<'a> = Transaction<'a, Postgres>;

// Transaction-scoped advisory lock serializing sync policy updates. The
// namespace is distinct from the Relay policy locks.
const LOCK_NAMESPACE: i32 = 0x5359_4e43;
const LOCK_SYNC_POLICY: i32 = 1;

const MAINTENANCE_RECORDS_PER_PAGE: i64 = 200;
const MAINTENANCE_MAX_CANDIDATES_PER_PASS: usize = 5_000;
const MAINTENANCE_MAX_PRUNED_RECORDS_PER_PASS: usize = 500;

const READ_POLICY_SQL: &str =
    "SELECT record_history_limit,revision,updated_at FROM instance_sync_policy WHERE policy_id=1";

fn pool(state: &AppState) -> Result<&PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL sync policy repository is unavailable"))
}

fn snapshot_from_row(
    row: Option<(i32, i64, DateTime<Utc>)>,
    default_limit: i64,
) -> Result<SyncPolicySnapshot, ApiError> {
    let Some((record_history_limit, revision, updated_at)) = row else {
        return Ok(SyncPolicySnapshot {
            record_history_limit: default_limit,
            revision: 0,
            updated_at: None,
        });
    };
    let record_history_limit = i64::from(record_history_limit);
    if revision <= 0
        || !(MIN_RECORD_HISTORY_LIMIT..=MAX_RECORD_HISTORY_LIMIT).contains(&record_history_limit)
    {
        return Err(ApiError::internal("stored sync policy is invalid"));
    }
    Ok(SyncPolicySnapshot {
        record_history_limit,
        revision,
        updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
    })
}

async fn read_policy_tx(
    tx: &mut PgTx<'_>,
    default_limit: i64,
) -> Result<SyncPolicySnapshot, ApiError> {
    let row = sqlx::query_as::<_, (i32, i64, DateTime<Utc>)>(READ_POLICY_SQL)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    snapshot_from_row(row, default_limit)
}

pub(crate) async fn effective_record_history_limit(
    pool: &PgPool,
    default_limit: i64,
) -> Result<i64, ApiError> {
    let row = sqlx::query_as::<_, (i32, i64, DateTime<Utc>)>(READ_POLICY_SQL)
        .fetch_optional(pool)
        .await
        .map_err(ApiError::internal)?;
    Ok(snapshot_from_row(row, default_limit)?.record_history_limit)
}

/// Reads the per-record history limit inside the caller's transaction: the
/// administrator's selection, or `default_limit` without a policy row.
///
/// The push commit runs at READ COMMITTED and calls this after it holds the
/// Vault counter lock, immediately before it prunes, so the statement sees
/// every policy update committed up to that moment.
pub(crate) async fn effective_record_history_limit_tx(
    tx: &mut PgTx<'_>,
    default_limit: i64,
) -> Result<i64, ApiError> {
    Ok(read_policy_tx(tx, default_limit)
        .await?
        .record_history_limit)
}

async fn admin_tx<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
) -> Result<(AuthUser, PgTx<'a>), ApiError> {
    let actor = crate::current_user(state, headers).await?;
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(
        &mut tx,
        state,
        &actor,
        &state.config.admin_usernames,
    )
    .await?;
    Ok((actor, tx))
}

pub(crate) async fn get_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    let snapshot = read_policy_tx(&mut tx, state.config.record_history_limit).await?;
    let response = policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn update_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<SyncPolicyUpdateRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(request) = request.map_err(|_| invalid_policy_request())?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    validate_policy_request(&request)?;
    sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
        .bind(LOCK_NAMESPACE)
        .bind(LOCK_SYNC_POLICY)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let current = read_policy_tx(&mut tx, state.config.record_history_limit).await?;
    if request.expected_revision != current.revision {
        return Err(policy_conflict());
    }
    let snapshot = if request.record_history_limit != current.record_history_limit {
        let revision = current
            .revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("sync policy revision overflowed"))?;
        let updated_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
             VALUES(1,$1,$2,$3) ON CONFLICT(policy_id) DO UPDATE SET \
             record_history_limit=EXCLUDED.record_history_limit,revision=EXCLUDED.revision,\
             updated_at=EXCLUDED.updated_at",
        )
        .bind(request.record_history_limit as i32)
        .bind(revision)
        .bind(updated_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        crate::audit::record_instance_admin_event_pg_tx(
            &mut tx,
            &state,
            &actor,
            "admin.sync_policy_updated",
            "sync_policy",
            None,
        )
        .await?;
        SyncPolicySnapshot {
            record_history_limit: request.record_history_limit,
            revision,
            updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
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
/// removed. The caller must hold the Vault row lock.
pub(crate) async fn prune_record_history_tx(
    tx: &mut PgTx<'_>,
    vault_id: &str,
    record_id: &str,
    limit: i64,
    object_gc_grace_seconds: i64,
) -> Result<u64, ApiError> {
    let limit = limit.clamp(MIN_RECORD_HISTORY_LIMIT, MAX_RECORD_HISTORY_LIMIT);
    // Rank every row of the record so the exclusions below never widen the
    // retained window: an excluded row is kept in addition to the newest
    // `limit` rows.
    let revision_ids: Vec<String> = sqlx::query_scalar(
        "SELECT ranked.revision_id FROM (\
           SELECT v.revision_id,\
                  ROW_NUMBER() OVER (ORDER BY v.commit_seq DESC,v.revision_id DESC) AS row_rank \
           FROM record_versions v WHERE v.vault_id=$1 AND v.record_id=$2\
         ) ranked \
         WHERE ranked.row_rank>$3 \
           AND NOT EXISTS(SELECT 1 FROM record_redactions rr \
                          WHERE rr.vault_id=$1 AND rr.record_id=$2) \
           AND NOT EXISTS(SELECT 1 FROM record_heads h \
                          WHERE h.vault_id=$1 AND h.record_id=$2 \
                            AND h.revision_id=ranked.revision_id) \
           AND NOT EXISTS(SELECT 1 FROM conflicts c \
                          WHERE c.vault_id=$1 AND c.resolved_revision_id IS NULL \
                            AND c.base_revision_id=ranked.revision_id) \
         ORDER BY ranked.row_rank DESC LIMIT $4",
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

    let deleted = sqlx::query(
        "DELETE FROM record_versions WHERE vault_id=$1 AND record_id=$2 \
         AND revision_id=ANY($3::text[])",
    )
    .bind(vault_id)
    .bind(record_id)
    .bind(&revision_ids)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    if deleted != revision_ids.len() as u64 {
        return Err(ApiError::internal("record history prune count changed"));
    }

    // object_references is keyed by Vault and revision ID without a record
    // owner. Legacy data may reuse one revision ID in another record, and a
    // conflict branch stores its references under its attempted revision ID.
    // Keep the rows whenever another holder shares the key.
    let referenced: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT r.revision_id FROM object_references r \
         WHERE r.vault_id=$1 AND r.revision_id=ANY($2::text[]) \
           AND NOT EXISTS(SELECT 1 FROM record_versions v \
                          WHERE v.vault_id=r.vault_id AND v.revision_id=r.revision_id) \
         ORDER BY r.revision_id",
    )
    .bind(vault_id)
    .bind(&revision_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut releasable = Vec::new();
    for revision_id in referenced {
        let conflict_envelopes: Vec<String> = sqlx::query_scalar(
            "SELECT envelope FROM conflicts WHERE vault_id=$1 AND position($2 in envelope)>0",
        )
        .bind(vault_id)
        .bind(&revision_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if !conflict_envelopes
            .iter()
            .any(|envelope| conflict_envelope_names_revision(envelope, &revision_id))
        {
            releasable.push(revision_id);
        }
    }
    if releasable.is_empty() {
        return Ok(deleted);
    }
    let released_objects: BTreeSet<String> = sqlx::query_scalar(
        "DELETE FROM object_references WHERE vault_id=$1 AND revision_id=ANY($2::text[]) \
         RETURNING object_id",
    )
    .bind(vault_id)
    .bind(&releasable)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .into_iter()
    .collect();
    let released_objects: Vec<String> = released_objects.into_iter().collect();
    crate::pg_record_purge::schedule_unreferenced_objects_gc_tx(
        tx,
        vault_id,
        &released_objects,
        object_gc_grace_seconds,
    )
    .await?;
    Ok(deleted)
}

/// Bounded Maintenance catch-up for records that exceed the limit in force
/// (the administrator's selection, or `default_limit` without a policy row):
/// history written before pruning existed, or kept under a larger limit. Safe
/// to run on several nodes; a Vault locked by another writer is left for a
/// later pass. Returns the number of revisions removed in this pass.
pub(crate) async fn prune_excess_record_history(
    pool: &PgPool,
    default_limit: i64,
    object_gc_grace_seconds: i64,
) -> Result<u64, ApiError> {
    let mut after = (String::new(), String::new());
    let mut examined = 0_usize;
    let mut pruned_records = 0_usize;
    let mut pruned_revisions = 0_u64;
    while examined < MAINTENANCE_MAX_CANDIDATES_PER_PASS
        && pruned_records < MAINTENANCE_MAX_PRUNED_RECORDS_PER_PASS
    {
        let limit = effective_record_history_limit(pool, default_limit).await?;
        let candidates = sqlx::query(
            "SELECT v.vault_id,v.record_id FROM record_versions v \
             WHERE (v.vault_id,v.record_id)>($1,$2) \
               AND NOT EXISTS(SELECT 1 FROM record_redactions rr \
                              WHERE rr.vault_id=v.vault_id AND rr.record_id=v.record_id) \
             GROUP BY v.vault_id,v.record_id HAVING COUNT(*)>$3 \
             ORDER BY v.vault_id,v.record_id LIMIT $4",
        )
        .bind(&after.0)
        .bind(&after.1)
        .bind(limit)
        .bind(MAINTENANCE_RECORDS_PER_PAGE)
        .fetch_all(pool)
        .await
        .map_err(ApiError::internal)?;
        if candidates.is_empty() {
            break;
        }
        for row in &candidates {
            let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
            let record_id: String = row.try_get("record_id").map_err(ApiError::internal)?;
            after = (vault_id.clone(), record_id.clone());
            examined += 1;

            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            let locked: Option<String> = sqlx::query_scalar(
                "SELECT vault_id FROM vaults WHERE vault_id=$1 FOR UPDATE SKIP LOCKED",
            )
            .bind(&vault_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if locked.is_none() {
                continue;
            }
            // Read again under the Vault lock: an administrator may have
            // changed the limit since the candidate page was selected.
            let limit = effective_record_history_limit_tx(&mut tx, default_limit).await?;
            let deleted = prune_record_history_tx(
                &mut tx,
                &vault_id,
                &record_id,
                limit,
                object_gc_grace_seconds,
            )
            .await?;
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
    use std::{fs, str::FromStr, sync::Arc};

    use axum::{
        body::{Body, to_bytes},
        http::{Request, StatusCode, header::AUTHORIZATION, header::CONTENT_TYPE},
    };
    use ed25519_dalek::SigningKey;
    use serde_json::{Value, json};
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgPoolOptions},
    };
    use tower::ServiceExt;
    use uuid::Uuid;

    use crate::{
        auth::AuthUser,
        pg_record_redaction::PgRedactionProofSigner,
        pg_sync_commit::PgSyncCommitRepository,
        pg_sync_history_read::{PgSyncHistoryReadRepository, SyncHistoryReadRepository},
        sync::{Envelope, VerifiedOperation},
        sync_repository::{PushCommit, ReadRecordRevisionsCommand, SyncCommitRepository},
    };

    const GC_GRACE_SECONDS: i64 = 7 * 24 * 60 * 60;
    const ADMIN_USERNAME: &str = "pg-sync-policy-admin@example.test";

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
    }

    impl TestDatabase {
        /// Applies every PostgreSQL migration into an isolated schema of an
        /// explicitly disposable loopback database.
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL sync policy tests require ATERMIUS_TEST_PG_URL");
            let parsed = url::Url::parse(&url).expect("valid PostgreSQL test URL");
            assert!(
                matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "::1")),
                "refusing non-loopback PostgreSQL test host"
            );
            assert!(
                parsed
                    .path()
                    .trim_start_matches('/')
                    .starts_with("atermius_test"),
                "refusing database outside the disposable atermius_test* namespace"
            );
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let admin_pool = PgPoolOptions::new()
                .max_connections(2)
                .connect_with(options.clone())
                .await
                .expect("connect to disposable PostgreSQL database");
            let schema = format!("atermius_pg_sync_policy_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated sync policy test schema");
            let pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
                .expect("connect to isolated sync policy test schema");
            let migration_dir =
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
            let mut migrations = fs::read_dir(&migration_dir)
                .expect("read PostgreSQL migrations")
                .map(|entry| entry.expect("read migration entry").path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "sql"))
                .collect::<Vec<_>>();
            migrations.sort();
            for migration in migrations {
                let sql = fs::read_to_string(&migration).expect("read PostgreSQL migration");
                sqlx::raw_sql(&sql)
                    .execute(&pool)
                    .await
                    .unwrap_or_else(|error| {
                        panic!(
                            "apply PostgreSQL migration {}: {error}",
                            migration.display()
                        )
                    });
            }
            Self {
                pool,
                admin_pool,
                schema,
            }
        }

        async fn cleanup(self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated sync policy test schema");
            self.admin_pool.close().await;
        }
    }

    struct Account {
        user: AuthUser,
        access_token: String,
    }

    async fn seed_account(pool: &PgPool, username: &str) -> Account {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access_token = format!("pg-sync-policy-access-{}", Uuid::new_v4());
        let access_hash = crate::sha256_hex(access_token.as_bytes());
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(&user_id)
            .bind(username)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) VALUES($1,$2,'test','active')",
        )
        .bind(&device_id)
        .bind(&user_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO sessions(\
                session_id,user_id,device_id,family_id,access_hash,refresh_hash,\
                access_expires_at,refresh_expires_at\
             ) VALUES($1,$2,$3,$4,$5,$6,CURRENT_TIMESTAMP+INTERVAL '1 hour',\
                      CURRENT_TIMESTAMP+INTERVAL '1 day')",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(&access_hash)
        .bind(Uuid::new_v4().to_string())
        .execute(pool)
        .await
        .unwrap();
        Account {
            user: AuthUser {
                user_id,
                device_id,
                session_id,
                access_hash,
                declares_record_schema2: false,
                declares_sync_redaction_v1: true,
            },
            access_token,
        }
    }

    async fn seed_owned_vault(pool: &PgPool, owner: &AuthUser) -> String {
        let vault_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) VALUES($1,$2,'active',1,1)")
            .bind(&vault_id)
            .bind(&owner.user_id)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
        )
        .bind(&vault_id)
        .bind(&owner.user_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES($1,0)")
            .bind(&vault_id)
            .execute(pool)
            .await
            .unwrap();
        vault_id
    }

    struct Writer<'a> {
        repository: PgSyncCommitRepository,
        user: &'a AuthUser,
        vault_id: &'a str,
        device_seq: u64,
    }

    impl<'a> Writer<'a> {
        fn new(pool: &PgPool, user: &'a AuthUser, vault_id: &'a str) -> Self {
            Self {
                repository: PgSyncCommitRepository::new(pool.clone()),
                user,
                vault_id,
                device_seq: 0,
            }
        }

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
                    nonce: "AA".to_owned(),
                    ciphertext: format!("ciphertext-{}", self.device_seq),
                    signature: "test-only-verified-envelope".to_owned(),
                },
            };
            let batch_id = Uuid::new_v4().to_string();
            self.repository
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

    async fn retained(pool: &PgPool, vault_id: &str, record_id: &str) -> Vec<String> {
        sqlx::query_scalar(
            "SELECT revision_id FROM record_versions WHERE vault_id=$1 AND record_id=$2 \
             ORDER BY commit_seq",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(pool)
        .await
        .unwrap()
    }

    async fn head(pool: &PgPool, vault_id: &str, record_id: &str) -> String {
        sqlx::query_scalar(
            "SELECT revision_id FROM record_heads WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(pool)
        .await
        .unwrap()
    }

    async fn insert_conflict(
        pool: &PgPool,
        vault_id: &str,
        record_id: &str,
        base_revision_id: Option<&str>,
        attempted_revision_id: &str,
        conflict_seq: i64,
    ) -> String {
        let conflict_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES($1,$2,$3,$4,$5,'digest','device',CURRENT_TIMESTAMP,$6,$7)")
            .bind(&conflict_id)
            .bind(vault_id)
            .bind(record_id)
            .bind(base_revision_id)
            .bind(json!({"header":{"revision_id":attempted_revision_id}}).to_string())
            .bind(conflict_seq)
            .bind(Uuid::new_v4().to_string())
            .execute(pool)
            .await
            .unwrap();
        conflict_id
    }

    async fn insert_object(pool: &PgPool, vault_id: &str) -> String {
        let object_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,size,sha256,gc_after) \
             VALUES($1,$2,1,repeat('a',64),NULL)",
        )
        .bind(vault_id)
        .bind(&object_id)
        .execute(pool)
        .await
        .unwrap();
        object_id
    }

    async fn object_gc_after(pool: &PgPool, vault_id: &str, object_id: &str) -> Option<i64> {
        sqlx::query_scalar("SELECT gc_after FROM blob_objects WHERE vault_id=$1 AND object_id=$2")
            .bind(vault_id)
            .bind(object_id)
            .fetch_one(pool)
            .await
            .unwrap()
    }

    async fn reference_count(pool: &PgPool, vault_id: &str, revision_id: &str) -> i64 {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=$1 AND revision_id=$2",
        )
        .bind(vault_id)
        .bind(revision_id)
        .fetch_one(pool)
        .await
        .unwrap()
    }

    async fn insert_redaction(
        pool: &PgPool,
        vault_id: &str,
        record_id: &str,
        deleted_revision_id: &str,
    ) {
        let deleted_seq: i64 = sqlx::query_scalar(
            "SELECT deleted_seq FROM record_graveyard WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,$5,$6)")
            .bind(Uuid::new_v4().to_string())
            .bind(vault_id)
            .bind(record_id)
            .bind(deleted_revision_id)
            .bind(deleted_seq)
            .bind(deleted_seq + 1_000_000)
            .execute(pool)
            .await
            .unwrap();
    }

    fn history_reader(pool: &PgPool) -> PgSyncHistoryReadRepository {
        let signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let instance = crate::InstanceInfo {
            instance_id: Uuid::new_v4().to_string(),
            server_space_id: Uuid::new_v4().to_string(),
            generation: Uuid::new_v4().to_string(),
            signing_public_key: base64::Engine::encode(
                &base64::engine::general_purpose::URL_SAFE_NO_PAD,
                signing_key.verifying_key().as_bytes(),
            ),
            signing_key_transitions: Vec::new(),
        };
        PgSyncHistoryReadRepository::with_signer(
            pool.clone(),
            PgRedactionProofSigner::new(instance, Arc::new(signing_key)),
        )
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL record history acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_keeps_the_newest_twenty_revisions_and_serves_them_newest_first() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let account = seed_account(pool, "pg-writer@example.test").await;
        let outsider = seed_account(pool, "pg-outsider@example.test").await;
        let vault_id = seed_owned_vault(pool, &account.user).await;
        let record_id = Uuid::new_v4().to_string();
        let mut writer = Writer::new(pool, &account.user, &vault_id);

        let revisions = writer.history(&record_id, 25, 20).await;
        assert_eq!(
            retained(pool, &vault_id, &record_id).await,
            revisions[6..].to_vec()
        );
        assert_eq!(head(pool, &vault_id, &record_id).await, revisions[25]);
        let events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(events, 26, "the ordered pull stream is not pruned");

        let tombstone = writer
            .commit(&record_id, Some(&revisions[25]), "delete", &[], 2)
            .await;
        assert_eq!(
            retained(pool, &vault_id, &record_id).await,
            vec![revisions[25].clone(), tombstone.clone()],
            "the minimum limit keeps the tombstone and the revision before it"
        );

        let reader = history_reader(pool);
        let response = reader
            .read_record_revisions(ReadRecordRevisionsCommand {
                user: account.user.clone(),
                vault_id: vault_id.clone(),
                record_id: record_id.clone(),
                default_record_history_limit: 20,
            })
            .await
            .unwrap();
        assert_eq!(response["vault_id"], vault_id);
        assert_eq!(response["record_id"], record_id);
        assert_eq!(response["record_history_limit"], 20);
        let rows = response["revisions"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["revision_id"], tombstone);
        assert_eq!(rows[0]["operation"], "delete");
        assert_eq!(rows[0]["deleted"], true);
        assert_eq!(rows[0]["commit_seq"], "27");
        assert_eq!(rows[0]["base_revision_id"], revisions[25]);
        assert_eq!(rows[0]["device_id"], account.user.device_id);
        assert!(rows[0]["restore_until"].as_str().is_some());
        assert!(rows[0]["created_at"].as_str().unwrap().ends_with('Z'));
        assert_eq!(rows[0]["envelope"]["header"]["revision_id"], tombstone);
        assert_eq!(rows[1]["revision_id"], revisions[25]);
        assert_eq!(rows[1]["deleted"], false);
        assert_eq!(rows[1]["restore_until"], Value::Null);
        let mut keys: Vec<&str> = rows[1]
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

        let capped = reader
            .read_record_revisions(ReadRecordRevisionsCommand {
                user: account.user.clone(),
                vault_id: vault_id.clone(),
                record_id: record_id.clone(),
                default_record_history_limit: 1,
            })
            .await
            .unwrap();
        assert_eq!(capped["revisions"].as_array().unwrap().len(), 1);
        assert_eq!(capped["revisions"][0]["revision_id"], tombstone);

        for (user, record) in [
            (account.user.clone(), Uuid::new_v4().to_string()),
            (outsider.user.clone(), record_id.clone()),
        ] {
            let error = reader
                .read_record_revisions(ReadRecordRevisionsCommand {
                    user,
                    vault_id: vault_id.clone(),
                    record_id: record,
                    default_record_history_limit: 20,
                })
                .await
                .unwrap_err();
            assert_eq!(error.status, StatusCode::NOT_FOUND);
            assert_eq!(error.body.code, "NOT_FOUND");
        }

        insert_redaction(pool, &vault_id, &record_id, &tombstone).await;
        let error = reader
            .read_record_revisions(ReadRecordRevisionsCommand {
                user: account.user.clone(),
                vault_id: vault_id.clone(),
                record_id: record_id.clone(),
                default_record_history_limit: 20,
            })
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::GONE);
        assert_eq!(error.body.code, "RECORD_REDACTED");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL record history acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_pruning_keeps_conflict_bases_and_releases_only_unshared_references() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let account = seed_account(pool, "pg-writer@example.test").await;
        let vault_id = seed_owned_vault(pool, &account.user).await;
        let mut writer = Writer::new(pool, &account.user, &vault_id);

        // An unresolved conflict pins its base beyond the newest two rows.
        let pinned_record = Uuid::new_v4().to_string();
        let mut revisions = writer.history(&pinned_record, 1, 2).await;
        let conflict_id = insert_conflict(
            pool,
            &vault_id,
            &pinned_record,
            Some(&revisions[0]),
            &Uuid::new_v4().to_string(),
            1,
        )
        .await;
        for _ in 0..3 {
            let base = revisions.last().unwrap().clone();
            revisions.push(
                writer
                    .commit(&pinned_record, Some(&base), "update", &[], 2)
                    .await,
            );
        }
        assert_eq!(
            retained(pool, &vault_id, &pinned_record).await,
            vec![
                revisions[0].clone(),
                revisions[3].clone(),
                revisions[4].clone()
            ]
        );
        assert_eq!(
            super::prune_excess_record_history(pool, 2, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            0
        );
        sqlx::query(
            "UPDATE conflicts SET resolved_revision_id=$1,resolution_seq=2,\
                    resolution_at=CURRENT_TIMESTAMP WHERE conflict_id=$2",
        )
        .bind(&revisions[4])
        .bind(&conflict_id)
        .execute(pool)
        .await
        .unwrap();
        assert_eq!(
            super::prune_excess_record_history(pool, 2, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            retained(pool, &vault_id, &pinned_record).await,
            revisions[3..].to_vec()
        );

        // Attachment references follow the pruned revision.
        let record_id = Uuid::new_v4().to_string();
        let only_first = insert_object(pool, &vault_id).await;
        let kept_by_later = insert_object(pool, &vault_id).await;
        let shared_with_conflict = insert_object(pool, &vault_id).await;
        sqlx::query(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,\
                 expected_sha256,chunk_size,state,expires_at,storage_backend,storage_store_id,\
                 storage_key) \
             VALUES($1,$2,$3,$4,1,repeat('a',64),1048576,'completed',\
                    CURRENT_TIMESTAMP+INTERVAL '1 hour','filesystem','store','key')",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&vault_id)
        .bind(&account.user.user_id)
        .bind(&only_first)
        .execute(pool)
        .await
        .unwrap();
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
        insert_conflict(pool, &vault_id, &record_id, None, &second, 3).await;
        let before: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(pool)
                .await
                .unwrap();
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
            retained(pool, &vault_id, &record_id).await,
            vec![second.clone(), third.clone()]
        );
        assert_eq!(reference_count(pool, &vault_id, &first).await, 0);
        let scheduled = object_gc_after(pool, &vault_id, &only_first)
            .await
            .expect("the object only the pruned revision referenced is scheduled");
        assert!((before + GC_GRACE_SECONDS..=before + GC_GRACE_SECONDS + 60).contains(&scheduled));
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE vault_id=$1 AND object_id=$2")
                .bind(&vault_id)
                .bind(&only_first)
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(upload_state, "collected");
        assert_eq!(object_gc_after(pool, &vault_id, &kept_by_later).await, None);

        let fourth = writer
            .commit(&record_id, Some(&third), "update", &[], 2)
            .await;
        assert_eq!(
            retained(pool, &vault_id, &record_id).await,
            vec![third, fourth]
        );
        assert_eq!(
            reference_count(pool, &vault_id, &second).await,
            2,
            "references shared with a conflict branch are kept"
        );
        assert_eq!(
            object_gc_after(pool, &vault_id, &shared_with_conflict).await,
            None
        );
        assert_eq!(object_gc_after(pool, &vault_id, &kept_by_later).await, None);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL record history acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_a_changed_limit_applies_to_the_next_push_without_lag() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let account = seed_account(pool, "pg-writer@example.test").await;
        let vault_id = seed_owned_vault(pool, &account.user).await;
        let record_id = Uuid::new_v4().to_string();
        let mut writer = Writer::new(pool, &account.user, &vault_id);
        // Ten revisions under the deployment default; nothing is pruned.
        let mut revisions = writer.history(&record_id, 9, 20).await;
        assert_eq!(retained(pool, &vault_id, &record_id).await, revisions);

        // The administrator lowers the limit (the row the admin route writes).
        sqlx::query(
            "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
             VALUES(1,3,1,CURRENT_TIMESTAMP)",
        )
        .execute(pool)
        .await
        .unwrap();
        assert_eq!(retained(pool, &vault_id, &record_id).await, revisions);

        // The very next push prunes to the new limit although the caller
        // still passes the deployment default of 20: the commit transaction
        // reads the policy row itself.
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
            retained(pool, &vault_id, &record_id).await,
            revisions[8..].to_vec(),
            "one push after the policy change keeps exactly the new limit"
        );

        // The history read reports the same policy row.
        let reader = history_reader(pool);
        let response = reader
            .read_record_revisions(ReadRecordRevisionsCommand {
                user: account.user.clone(),
                vault_id: vault_id.clone(),
                record_id: record_id.clone(),
                default_record_history_limit: 20,
            })
            .await
            .unwrap();
        assert_eq!(response["record_history_limit"], 3);
        assert_eq!(response["revisions"].as_array().unwrap().len(), 3);
        assert_eq!(
            super::effective_record_history_limit(pool, 20)
                .await
                .unwrap(),
            3
        );

        // Lowering it again also applies to the next push.
        sqlx::query(
            "UPDATE instance_sync_policy SET record_history_limit=2,revision=2 WHERE policy_id=1",
        )
        .execute(pool)
        .await
        .unwrap();
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
            retained(pool, &vault_id, &record_id).await,
            revisions[10..].to_vec()
        );

        // Without a policy row the deployment default passed by the caller
        // is the fallback.
        sqlx::query("DELETE FROM instance_sync_policy")
            .execute(pool)
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
            retained(pool, &vault_id, &record_id).await,
            revisions[revisions.len() - 4..].to_vec()
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL record history acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_maintenance_prunes_to_a_lowered_limit_and_skips_redacted_and_locked_vaults() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let account = seed_account(pool, "pg-writer@example.test").await;
        let vault_id = seed_owned_vault(pool, &account.user).await;
        let live_record = Uuid::new_v4().to_string();
        let redacted_record = Uuid::new_v4().to_string();
        let mut writer = Writer::new(pool, &account.user, &vault_id);
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
        insert_redaction(pool, &vault_id, &redacted_record, &tombstone).await;

        assert_eq!(
            super::prune_excess_record_history(pool, 20, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            0
        );

        // A Vault locked by another writer is left for a later pass.
        let mut blocker = pool.begin().await.unwrap();
        sqlx::query("SELECT vault_id FROM vaults WHERE vault_id=$1 FOR UPDATE")
            .bind(&vault_id)
            .fetch_one(&mut *blocker)
            .await
            .unwrap();
        assert_eq!(
            super::prune_excess_record_history(pool, 3, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            0
        );
        blocker.rollback().await.unwrap();
        assert_eq!(retained(pool, &vault_id, &live_record).await, live);

        assert_eq!(
            super::prune_excess_record_history(pool, 3, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            7
        );
        assert_eq!(
            retained(pool, &vault_id, &live_record).await,
            live[7..].to_vec()
        );
        assert_eq!(head(pool, &vault_id, &live_record).await, live[9]);
        assert_eq!(
            retained(pool, &vault_id, &redacted_record).await,
            redacted,
            "every row of a redacted record is left alone"
        );
        assert_eq!(
            super::prune_excess_record_history(pool, 3, GC_GRACE_SECONDS)
                .await
                .unwrap(),
            0
        );
        database.cleanup().await;
    }

    fn test_config(data_dir: std::path::PathBuf) -> crate::Config {
        crate::Config {
            data_dir,
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            database_key_file: None,
            backup_retention_count: None,
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

    async fn call(
        app: &axum::Router,
        method: &str,
        bearer: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri("/api/v1/admin/sync-policy");
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
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync policy acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_admin_route_enforces_auth_range_and_revision_and_audits_changes() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let admin = seed_account(pool, ADMIN_USERNAME).await;
        let member = seed_account(pool, "pg-member@example.test").await;
        let data_dir =
            std::env::temp_dir().join(format!("atermius-pg-sync-policy-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let mut state = crate::open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        state.pg_sync_only = true;
        state.pg_sync_auth = Some(crate::pg_sync_auth::PgSyncAuthRepository::new(pool.clone()));
        state.pg_sync_pool = Some(pool.clone());
        let app = crate::router(state.clone()).await;
        let valid = json!({"expected_revision":0,"record_history_limit":50});

        let (status, _) = call(&app, "GET", None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        for (method, body) in [("GET", None), ("PUT", Some(valid.clone()))] {
            let (status, body) = call(&app, method, Some(&member.access_token), body).await;
            assert_eq!(status, StatusCode::FORBIDDEN);
            assert_eq!(body["error"]["code"], "INSTANCE_ADMIN_REQUIRED");
        }

        let (status, initial) = call(&app, "GET", Some(&admin.access_token), None).await;
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
        for limit in [1, 1001] {
            let (status, body) = call(
                &app,
                "PUT",
                Some(&admin.access_token),
                Some(json!({"expected_revision":0,"record_history_limit":limit})),
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert_eq!(body["error"]["code"], "RECORD_HISTORY_LIMIT_OUT_OF_RANGE");
        }
        let (status, body) = call(
            &app,
            "PUT",
            Some(&admin.access_token),
            Some(json!({"expected_revision":0,"record_history_limit":50,"extra":true})),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "INVALID_SYNC_POLICY_REQUEST");

        let (status, changed) = call(&app, "PUT", Some(&admin.access_token), Some(valid)).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(changed["record_history_limit"], 50);
        assert_eq!(changed["revision"], 1);
        assert!(changed["updated_at"].as_str().is_some());
        assert_eq!(
            crate::sync_policy::effective_record_history_limit(&state)
                .await
                .unwrap(),
            50
        );

        let (status, stale) = call(
            &app,
            "PUT",
            Some(&admin.access_token),
            Some(json!({"expected_revision":0,"record_history_limit":60})),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(stale["error"]["code"], "SYNC_POLICY_CONFLICT");
        let (status, unchanged) = call(
            &app,
            "PUT",
            Some(&admin.access_token),
            Some(json!({"expected_revision":1,"record_history_limit":50})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(unchanged, changed);
        let (status, read_back) = call(&app, "GET", Some(&admin.access_token), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(read_back, changed);

        let audit: (i64, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT COUNT(*),MAX(actor_user_id),MAX(actor_device_id) FROM audit_events \
             WHERE action='admin.sync_policy_updated' AND scope_type='instance' \
               AND resource_type='sync_policy'",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(
            audit,
            (
                1,
                Some(admin.user.user_id.clone()),
                Some(admin.user.device_id.clone())
            )
        );

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
        database.cleanup().await;
    }
}
