//! Shared PostgreSQL SSH Relay ticket and connection storage.
//!
//! Tickets and live-connection leases live in PostgreSQL so every serving
//! node observes the same one-use, connection-limit and revocation decisions.
//! Target destinations are encrypted with the shared instance key and erased
//! as soon as a ticket is consumed.

use std::net::IpAddr;

use axum::http::StatusCode;
use chrono::{DateTime, SecondsFormat, Utc};
use rand::RngCore;
use sqlx::{Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{
    ApiError, AppState,
    relay::{self, RelayTarget},
};

const LOCK_NAMESPACE: i32 = 0x4154_4552;
// Key 1 serialized the retired Relay policy and key 3 its access groups. The
// ticket-capacity key keeps its number so mixed-version nodes still agree.
const LOCK_TICKET_CAPACITY: i32 = 2;
const CONNECTION_LEASE_SECONDS: i64 = 10;
// Tickets and leases still carry the retired per-user authorization revision
// column (NOT NULL in the shared schema); it is always written as zero.
const RETIRED_AUTHORIZATION_REVISION: i64 = 0;

type PgTx<'a> = Transaction<'a, Postgres>;

fn pool(state: &AppState) -> Result<&sqlx::PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL Relay repository is unavailable"))
}

async fn lock_exclusive(tx: &mut PgTx<'_>, key: i32) -> Result<(), ApiError> {
    sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
        .bind(LOCK_NAMESPACE)
        .bind(key)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn ensure_active_device(
    state: &AppState,
    user_id: &str,
    device_id: &str,
) -> Result<(), ApiError> {
    let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND status='active')")
        .bind(device_id).bind(user_id).fetch_one(pool(state)?).await.map_err(ApiError::internal)?;
    if active {
        Ok(())
    } else {
        Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ))
    }
}

pub(crate) async fn issue_ticket(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    session_id: &str,
    access_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<(String, String), ApiError> {
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let session: Option<(DateTime<Utc>, DateTime<Utc>)> = sqlx::query_as(
        "SELECT s.access_expires_at,s.refresh_expires_at FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4 AND s.revoked_at IS NULL AND s.access_expires_at>clock_timestamp() AND s.refresh_expires_at>clock_timestamp() AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
        .bind(session_id).bind(user_id).bind(device_id).bind(access_hash).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some((access_expiry, refresh_expiry)) = session else {
        return Err(ApiError::unauthorized());
    };
    lock_exclusive(&mut tx, LOCK_TICKET_CAPACITY).await?;
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let cutoff = now - chrono::Duration::seconds(relay::TICKET_RATE_WINDOW_SECONDS);
    sqlx::query("DELETE FROM relay_tickets WHERE created_at <= $1")
        .bind(cutoff)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let (issued, oldest): (i64, Option<i64>) = sqlx::query_as("SELECT COUNT(*),floor(extract(epoch FROM MIN(created_at)))::BIGINT FROM relay_tickets WHERE user_id=$1 AND created_at>$2")
        .bind(user_id).bind(cutoff).fetch_one(&mut *tx).await.map_err(ApiError::internal)?;
    if issued >= relay::MAX_TICKETS_PER_USER_PER_WINDOW {
        let oldest = oldest;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(relay::relay_rate_limit_error(oldest, now.timestamp()));
    }
    let retained: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_tickets")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if retained >= relay::MAX_RETAINED_TICKETS {
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay ticket capacity is temporarily full",
        ));
    }
    let expires_at = (now + chrono::Duration::seconds(relay::TICKET_TTL_SECONDS))
        .min(access_expiry)
        .min(refresh_expiry);
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, raw);
    let ticket_hash = crate::sha256_hex(ticket.as_bytes());
    let target_envelope = relay::encrypt_relay_destination(state, &ticket_hash, ip, port)?;
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,session_id,session_access_expires_at,target_envelope,expires_at,consumed_at,created_at,authorization_revision) VALUES($1,$2,$3,$4,$5,$6,$7,NULL,$8,$9)")
        .bind(&ticket_hash).bind(user_id).bind(device_id).bind(session_id).bind(access_expiry).bind(target_envelope).bind(expires_at).bind(now).bind(RETIRED_AUTHORIZATION_REVISION)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    record_account_event_tx(
        &mut tx,
        state,
        user_id,
        Some(device_id),
        "relay.ticket_issued",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((
        ticket,
        expires_at.to_rfc3339_opts(SecondsFormat::Millis, true),
    ))
}

pub(crate) async fn consume_ticket(
    state: &AppState,
    token: &str,
) -> Result<Option<RelayTarget>, ApiError> {
    if !relay::is_valid_ticket(token) {
        return Ok(None);
    }
    let ticket_hash = crate::sha256_hex(token.as_bytes());
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let row = sqlx::query("UPDATE relay_tickets SET consumed_at=$1 WHERE ticket_hash=$2 AND consumed_at IS NULL AND expires_at>$1 AND session_access_expires_at>$1 AND target_envelope LIKE 'rtd1:%' AND EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=relay_tickets.session_id AND s.user_id=relay_tickets.user_id AND s.device_id=relay_tickets.device_id AND s.access_expires_at=relay_tickets.session_access_expires_at AND s.access_expires_at>$1 AND s.refresh_expires_at>$1 AND s.revoked_at IS NULL AND u.status='active' AND d.status='active') RETURNING user_id,device_id,session_id,target_envelope")
        .bind(now).bind(&ticket_hash).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let envelope: String = row.try_get("target_envelope").map_err(ApiError::internal)?;
    sqlx::query("UPDATE relay_tickets SET target_envelope='' WHERE ticket_hash=$1")
        .bind(&ticket_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
    let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
    let session_id: String = row.try_get("session_id").map_err(ApiError::internal)?;
    let destination = relay::decrypt_relay_destination(state, &ticket_hash, &envelope).ok();
    tx.commit().await.map_err(ApiError::internal)?;
    let Some((ip, port)) = destination.filter(|(ip, port)| relay::relay_target_allowed(*ip, *port))
    else {
        return Ok(None);
    };
    Ok(Some(RelayTarget {
        user_id,
        device_id,
        session_id,
        ip,
        port,
        connection_id: None,
    }))
}

pub(crate) async fn relay_session_active(state: &AppState, target: &RelayTarget) -> bool {
    let Ok(pg) = pool(state) else { return false };
    let active: Result<bool, _> = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.refresh_expires_at>clock_timestamp() AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_one(pg).await;
    match active {
        Ok(value) => value,
        Err(_) => {
            tracing::warn!(event = "relay_session_state_check_failed");
            false
        }
    }
}

pub(crate) async fn relay_connection_active(state: &AppState, target: &RelayTarget) -> bool {
    if !relay::relay_target_allowed(target.ip, target.port) {
        return false;
    }
    let Ok(pg) = pool(state) else { return false };
    let result = async {
        let mut tx = pg.begin().await.map_err(ApiError::internal)?;
        let active_session: Option<String> = sqlx::query_scalar("SELECT s.session_id FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.refresh_expires_at>clock_timestamp() AND s.revoked_at IS NULL AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
            .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
        if active_session.is_none() { tx.commit().await.map_err(ApiError::internal)?; return Ok::<bool,ApiError>(false) }
        if let Some(connection_id)=target.connection_id {
            let renewed=sqlx::query("UPDATE relay_connection_leases SET heartbeat_at=clock_timestamp(),lease_expires_at=clock_timestamp()+($2 * INTERVAL '1 second') WHERE connection_id=$1 AND user_id=$3 AND lease_expires_at>clock_timestamp()")
                .bind(connection_id).bind(CONNECTION_LEASE_SECONDS).bind(&target.user_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
            if renewed.rows_affected()!=1 { tx.commit().await.map_err(ApiError::internal)?; return Ok(false) }
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(true)
    }.await;
    match result {
        Ok(active) => active,
        Err(_) => {
            tracing::warn!(event = "relay_connection_state_check_failed");
            false
        }
    }
}

pub(crate) async fn record_connected(
    state: &AppState,
    target: &RelayTarget,
    connection_id: Uuid,
) -> Result<bool, ApiError> {
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let session: Option<String>=sqlx::query_scalar("SELECT s.session_id FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.revoked_at IS NULL AND s.refresh_expires_at>clock_timestamp() AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
        .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    if session.is_none() {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    // Serialize cluster-wide admission so simultaneous sockets cannot exceed
    // the configured per-user or fixed instance cap across serving nodes.
    lock_exclusive(&mut tx, LOCK_TICKET_CAPACITY).await?;
    sqlx::query("DELETE FROM relay_connection_leases WHERE lease_expires_at<=clock_timestamp()")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let (user_count,total_count):(i64,i64)=sqlx::query_as("SELECT (SELECT COUNT(*) FROM relay_connection_leases WHERE user_id=$1 AND lease_expires_at>clock_timestamp()),(SELECT COUNT(*) FROM relay_connection_leases WHERE lease_expires_at>clock_timestamp())")
        .bind(&target.user_id).fetch_one(&mut *tx).await.map_err(ApiError::internal)?;
    let user_limit = i64::try_from(state.config.relay_max_connections_per_user).unwrap_or(i64::MAX);
    if user_count >= user_limit || total_count >= relay::MAX_GLOBAL_RELAY_CONNECTIONS as i64 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let inserted=sqlx::query("INSERT INTO relay_connection_leases(connection_id,node_id,user_id,device_id,session_id,session_access_expires_at,authorization_revision,created_at,heartbeat_at,lease_expires_at) SELECT $1,$2,$3,$4,$5,s.access_expires_at,$6,clock_timestamp(),clock_timestamp(),clock_timestamp()+($7 * INTERVAL '1 second') FROM sessions s WHERE s.session_id=$5 AND s.user_id=$3 AND s.device_id=$4 AND s.revoked_at IS NULL AND s.refresh_expires_at>clock_timestamp()")
        .bind(connection_id).bind(state.pg_relay_node_id).bind(&target.user_id).bind(&target.device_id).bind(&target.session_id).bind(RETIRED_AUTHORIZATION_REVISION).bind(CONNECTION_LEASE_SECONDS).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if inserted.rows_affected() != 1 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    record_account_event_tx(
        &mut tx,
        state,
        &target.user_id,
        Some(&target.device_id),
        "relay.connected",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(true)
}

pub(crate) async fn release_connection_lease(state: &AppState, connection_id: Uuid) {
    if let Ok(pg) = pool(state) {
        if sqlx::query("DELETE FROM relay_connection_leases WHERE connection_id=$1 AND node_id=$2")
            .bind(connection_id)
            .bind(state.pg_relay_node_id)
            .execute(pg)
            .await
            .is_err()
        {
            tracing::warn!(event = "relay_connection_lease_release_failed");
        }
    }
}

async fn record_account_event_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    user_id: &str,
    device_id: Option<&str>,
    action: &str,
) -> Result<(), ApiError> {
    let scope = crate::audit::account_scope_id(&state.cursor_key, user_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('account',$1,$2,$3,$4,'relay',NULL,'success',$5,'api')")
        .bind(scope).bind(user_id).bind(device_id).bind(action).bind(occurred_at).execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{fs, str::FromStr};

    use axum::{
        body::{Body, to_bytes},
        http::{Request, header::AUTHORIZATION, header::CONTENT_TYPE},
    };
    use serde_json::{Value, json};
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgPoolOptions},
    };
    use tower::ServiceExt;

    use super::*;

    const ADMIN_USERNAME: &str = "pg-relay-admin@example.test";

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
                .expect("ignored PostgreSQL Relay tests require ATERMIUS_TEST_PG_URL");
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
            let schema = format!("atermius_pg_relay_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated Relay test schema");
            let pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
                .expect("connect to isolated Relay test schema");
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
            .expect("drop isolated Relay test schema");
            self.admin_pool.close().await;
        }
    }

    struct Account {
        user_id: String,
        device_id: String,
        session_id: String,
        access_token: String,
    }

    async fn seed_account(pool: &PgPool, username: &str) -> Account {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access_token = format!("pg-relay-access-{}", Uuid::new_v4());
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
        .bind(crate::sha256_hex(access_token.as_bytes()))
        .bind(Uuid::new_v4().to_string())
        .execute(pool)
        .await
        .unwrap();
        Account {
            user_id,
            device_id,
            session_id,
            access_token,
        }
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
            relay_enabled: true,
            terminal_collaboration_enabled: false,
            relay_max_connections_per_user: 4,
            public_origin: Some("https://relay.example.test".to_owned()),
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 7 * 24 * 60 * 60,
            record_history_limit: 20,
            admin_usernames: vec![ADMIN_USERNAME.to_owned()],
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn call(
        app: &axum::Router,
        method: &str,
        path: &str,
        bearer: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let builder = Request::builder()
            .method(method)
            .uri(path)
            .header(AUTHORIZATION, format!("Bearer {bearer}"));
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
    #[ignore = "real PostgreSQL Relay acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_relay_dials_any_target_outside_the_floor_and_ignores_retired_policy_rows() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let admin = seed_account(pool, ADMIN_USERNAME).await;
        let member = seed_account(pool, "pg-relay-member@example.test").await;

        // State written by the retired policy and access-group features would
        // have denied this member everything; it must no longer be consulted.
        sqlx::query(
            "INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
             VALUES(1,FALSE,'[]','[]',3,clock_timestamp())",
        )
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "WITH now AS (SELECT clock_timestamp() AS at) \
             INSERT INTO user_relay_policies(user_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
             SELECT $1,FALSE,'[]','[]',1,at FROM now",
        )
        .bind(&member.user_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO relay_user_authorization_versions(user_id,revision) VALUES($1,7)")
            .bind(&member.user_id)
            .execute(pool)
            .await
            .unwrap();

        let data_dir = std::env::temp_dir().join(format!("atermius-pg-relay-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let mut state = crate::open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        state.pg_sync_only = true;
        state.pg_sync_auth = Some(crate::pg_sync_auth::PgSyncAuthRepository::new(pool.clone()));
        state.pg_sync_pool = Some(pool.clone());
        let app = crate::router(state.clone()).await;

        let ticket_body = |host: &str, port: u16| json!({"device_id": member.device_id, "target_host": host, "target_port": port});
        let (status, issued) = call(
            &app,
            "POST",
            "/api/v1/relay/tickets",
            &member.access_token,
            Some(ticket_body("10.20.30.40", 2222)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{issued}");
        let ticket = issued["ticket"].as_str().unwrap().to_owned();
        let stored_revision: i64 = sqlx::query_scalar(
            "SELECT authorization_revision FROM relay_tickets WHERE ticket_hash=$1",
        )
        .bind(crate::sha256_hex(ticket.as_bytes()))
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(stored_revision, RETIRED_AUTHORIZATION_REVISION);

        let target = consume_ticket(&state, &ticket)
            .await
            .unwrap()
            .expect("ticket must be redeemable despite retired policy rows");
        assert_eq!(target.ip, "10.20.30.40".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 2222);
        assert_eq!(target.session_id, member.session_id);
        assert!(consume_ticket(&state, &ticket).await.unwrap().is_none());
        let envelope: String =
            sqlx::query_scalar("SELECT target_envelope FROM relay_tickets WHERE ticket_hash=$1")
                .bind(crate::sha256_hex(ticket.as_bytes()))
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(envelope, "");

        assert!(relay_connection_active(&state, &target).await);
        let connection_id = Uuid::new_v4();
        assert!(
            record_connected(&state, &target, connection_id)
                .await
                .unwrap()
        );
        let lease_revision: i64 = sqlx::query_scalar(
            "SELECT authorization_revision FROM relay_connection_leases WHERE connection_id=$1",
        )
        .bind(connection_id)
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(lease_revision, RETIRED_AUTHORIZATION_REVISION);
        let leased = RelayTarget {
            connection_id: Some(connection_id),
            ..target.clone()
        };
        assert!(relay_connection_active(&state, &leased).await);
        let forbidden = RelayTarget {
            ip: "127.0.0.1".parse().unwrap(),
            ..leased.clone()
        };
        assert!(!relay_connection_active(&state, &forbidden).await);

        for host in [
            "127.0.0.1",
            "::ffff:127.0.0.1",
            "169.254.169.254",
            "fd00:ec2::254",
            "224.0.0.1",
        ] {
            let (status, body) = call(
                &app,
                "POST",
                "/api/v1/relay/tickets",
                &member.access_token,
                Some(ticket_body(host, 22)),
            )
            .await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{host}");
            assert_eq!(body["error"]["code"], "TARGET_DENIED", "{host}");
        }
        let (status, body) = call(
            &app,
            "POST",
            "/api/v1/relay/tickets",
            &member.access_token,
            Some(ticket_body("10.20.30.40", 0)),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "INVALID_TARGET");

        let (status, overview) = call(
            &app,
            "GET",
            "/api/v1/admin/overview",
            &admin.access_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{overview}");
        assert_eq!(
            overview["relay"],
            json!({"enabled": true, "max_connections_per_user": 4})
        );
        for (method, path) in [
            ("GET", "/api/v1/admin/relay-policy".to_owned()),
            ("PUT", "/api/v1/admin/relay-policy".to_owned()),
            (
                "GET",
                format!("/api/v1/admin/relay-policy/users/{}", member.user_id),
            ),
            ("GET", "/api/v1/admin/relay-groups".to_owned()),
            ("POST", "/api/v1/admin/relay-groups".to_owned()),
            (
                "PUT",
                format!("/api/v1/admin/relay-groups/{}/members", Uuid::new_v4()),
            ),
        ] {
            let (status, body) = call(&app, method, &path, &admin.access_token, None).await;
            assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{method} {path}");
            assert_eq!(
                body["error"]["code"], "PG_SYNC_SCOPE_LIMITED",
                "{method} {path}"
            );
        }

        // Revocation still closes live connections.
        sqlx::query("UPDATE sessions SET revoked_at=clock_timestamp() WHERE session_id=$1")
            .bind(&member.session_id)
            .execute(pool)
            .await
            .unwrap();
        assert!(!relay_connection_active(&state, &leased).await);
        release_connection_lease(&state, connection_id).await;

        let untouched: (bool, i64) =
            sqlx::query_as("SELECT enabled,revision FROM instance_relay_policy WHERE policy_id=1")
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(untouched, (false, 3));

        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
        database.cleanup().await;
    }
}
