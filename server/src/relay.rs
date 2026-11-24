use crate::{ApiError, AppState, current_user, now_rfc3339, sha256_hex};
use axum::{
    Json,
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode, header::ORIGIN},
    response::IntoResponse,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use futures_util::{SinkExt, StreamExt};
use hkdf::Hkdf;
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, Sqlite};
use std::{
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs},
    pin::Pin,
    sync::{Arc, LazyLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::{Instant, Interval, timeout},
};
use zeroize::Zeroizing;

pub(crate) const MAX_GLOBAL_RELAY_CONNECTIONS: usize = 256;
const MAX_RELAY_DURATION: Duration = Duration::from_secs(60 * 60);
const RELAY_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const RELAY_IO_TIMEOUT: Duration = Duration::from_secs(30);
const RELAY_SESSION_CHECK_TIMEOUT: Duration = Duration::from_secs(5);
const RELAY_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_RELAY_BYTES: u64 = 1024 * 1024 * 1024;
const RELAY_POLL_SESSION_SECONDS: u64 = 2;
pub(crate) const TICKET_TTL_SECONDS: i64 = 30;
pub(crate) const TICKET_RATE_WINDOW_SECONDS: i64 = 60;
pub(crate) const MAX_TICKETS_PER_USER_PER_WINDOW: i64 = 20;
pub(crate) const MAX_RETAINED_TICKETS: i64 = 100_000;
const RELAY_DESTINATION_PREFIX: &str = "rtd1:";
const RELAY_DESTINATION_KDF_SALT: &[u8] = b"atermius/server-key-derivation/v1";
const RELAY_DESTINATION_KDF_INFO: &[u8] = b"atermius/relay-ticket-destination-encryption/v1";
const RELAY_DESTINATION_AAD_PREFIX: &[u8] = b"atermius/relay-ticket-destination/aad/v1\0";
const RELAY_DNS_LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_RELAY_DNS_ANSWERS: usize = 32;
const MAX_CONCURRENT_RELAY_DNS_LOOKUPS: usize = 32;
static RELAY_DNS_LOOKUP_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_CONCURRENT_RELAY_DNS_LOOKUPS)));
const EC2_IPV6_METADATA: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254);
const ALIBABA_IPV4_METADATA: Ipv4Addr = Ipv4Addr::new(100, 100, 100, 200);

struct RelayConnectionGuard {
    state: Arc<AppState>,
    user_id: String,
    _global_permit: OwnedSemaphorePermit,
}

impl Drop for RelayConnectionGuard {
    fn drop(&mut self) {
        if let Ok(mut all) = self.state.relay_connections.lock()
            && let Some(count) = all.get_mut(&self.user_id)
        {
            *count = count.saturating_sub(1);
            if *count == 0 {
                all.remove(&self.user_id);
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TicketRequest {
    pub device_id: String,
    pub target_host: String,
    pub target_port: u16,
}

#[derive(Debug, Clone)]
pub(crate) struct RelayTarget {
    pub(crate) user_id: String,
    pub(crate) device_id: String,
    pub(crate) session_id: String,
    pub(crate) ip: IpAddr,
    pub(crate) port: u16,
    pub(crate) connection_id: Option<uuid::Uuid>,
}

pub(crate) fn is_forbidden_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => {
            v.is_loopback()
                || v.is_link_local()
                || v.is_unspecified()
                || v.is_multicast()
                || v.is_broadcast()
                || v == Ipv4Addr::new(169, 254, 169, 254)
                || v == ALIBABA_IPV4_METADATA
        }
        IpAddr::V6(v) => {
            v.is_loopback()
                || v.is_unicast_link_local()
                || v.is_unspecified()
                || v.is_multicast()
                || v == EC2_IPV6_METADATA
                || v.to_ipv4_mapped()
                    .is_some_and(|x| is_forbidden_ip(IpAddr::V4(x)))
        }
    }
}

/// The only Relay destination rule. The server opens the connection the
/// user asked for; there is no administrator policy or deployment allowlist,
/// only the fixed floor of special-purpose addresses in [`is_forbidden_ip`].
pub(crate) fn relay_target_allowed(ip: IpAddr, port: u16) -> bool {
    port != 0 && !is_forbidden_ip(ip)
}

/// Relay is served when the deployment enables it and configures the public
/// browser origin that the WebSocket origin check compares against.
pub(crate) fn relay_available(state: &AppState) -> bool {
    state.config.relay_enabled
        && state
            .config
            .public_origin
            .as_deref()
            .is_some_and(|origin| !origin.trim().is_empty())
}

/// Relay summary reported by the administrator overview in both backends.
pub(crate) fn admin_overview_json(state: &AppState) -> Value {
    json!({
        "enabled": relay_available(state),
        "max_connections_per_user": state.config.relay_max_connections_per_user,
    })
}

fn relay_disabled() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "RELAY_DISABLED",
        "relay is not enabled on this server",
    )
}

fn invalid_target() -> ApiError {
    ApiError::bad_request("INVALID_TARGET", "target address or port is invalid")
}

pub(crate) fn normalize_dns_hostname(target_host: &str) -> Result<String, ApiError> {
    if target_host.is_empty() || !target_host.is_ascii() || target_host.len() > 254 {
        return Err(invalid_target());
    }
    let without_root_dot = target_host.strip_suffix('.').unwrap_or(target_host);
    if without_root_dot.is_empty() || without_root_dot.len() > 253 {
        return Err(invalid_target());
    }
    let normalized = without_root_dot.to_ascii_lowercase();
    for label in normalized.split('.') {
        if label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return Err(invalid_target());
        }
    }

    // Host::parse applies the URL crate's IDNA validation to ASCII A-labels.
    // Numeric shorthand is parsed as an IP address by WHATWG URL rules and is
    // intentionally rejected here to avoid ambiguous legacy IPv4 forms.
    match url::Host::parse(&normalized).map_err(|_| invalid_target())? {
        url::Host::Domain(domain) if domain == normalized => Ok(normalized),
        _ => Err(invalid_target()),
    }
}

type RelayResolveFuture<'a> = Pin<Box<dyn Future<Output = io::Result<Vec<IpAddr>>> + Send + 'a>>;

trait RelayResolver: Send + Sync {
    fn resolve<'a>(
        &'a self,
        hostname: &'a str,
        port: u16,
        permit: OwnedSemaphorePermit,
    ) -> RelayResolveFuture<'a>;
}

struct SystemRelayResolver;

impl RelayResolver for SystemRelayResolver {
    fn resolve<'a>(
        &'a self,
        hostname: &'a str,
        port: u16,
        permit: OwnedSemaphorePermit,
    ) -> RelayResolveFuture<'a> {
        Box::pin(async move {
            // The trailing root dot prevents resolver search-domain expansion.
            let absolute_name = format!("{hostname}.");
            tokio::task::spawn_blocking(move || {
                // getaddrinfo resolves both A and AAAA in one call. Keep the
                // owned permit in the blocking worker: timing out the async
                // caller cannot cancel an already-running getaddrinfo call.
                let _permit = permit;
                let mut answers = Vec::with_capacity(MAX_RELAY_DNS_ANSWERS + 1);
                for address in (absolute_name.as_str(), port).to_socket_addrs()? {
                    answers.push(address.ip());
                    if answers.len() > MAX_RELAY_DNS_ANSWERS {
                        break;
                    }
                }
                Ok(answers)
            })
            .await
            .map_err(|_| io::Error::other("resolver worker failed"))?
        })
    }
}

/// Bounded system lookup shared with the share gateway. Uses the same global
/// DNS concurrency gate and root-dot absolute name as Relay ticket issuance.
pub(crate) async fn lookup_host_all(
    hostname: &str,
    port: u16,
    max_answers: usize,
) -> io::Result<Vec<IpAddr>> {
    let permit = RELAY_DNS_LOOKUP_SLOTS
        .clone()
        .try_acquire_owned()
        .map_err(|_| io::Error::other("resolver busy"))?;
    let mut answers = SystemRelayResolver.resolve(hostname, port, permit).await?;
    if answers.len() > max_answers {
        answers.truncate(max_answers + 1);
    }
    Ok(answers)
}

fn target_resolution_failed() -> ApiError {
    ApiError::new(
        StatusCode::BAD_GATEWAY,
        "TARGET_RESOLUTION_FAILED",
        "relay target name could not be resolved",
    )
}

pub(crate) fn target_denied() -> ApiError {
    ApiError::forbidden("TARGET_DENIED", "target address is not allowed")
}

async fn resolve_dns_target<R: RelayResolver>(
    hostname: &str,
    port: u16,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<IpAddr, ApiError> {
    if port == 0 {
        return Err(invalid_target());
    }
    let permit = lookup_slots.clone().try_acquire_owned().map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay capacity is temporarily full",
        )
    })?;
    let answers = timeout(lookup_timeout, resolver.resolve(hostname, port, permit))
        .await
        .map_err(|_| target_resolution_failed())?
        .map_err(|_| target_resolution_failed())?;
    if answers.is_empty() || answers.len() > MAX_RELAY_DNS_ANSWERS {
        return Err(target_resolution_failed());
    }

    // Select the first answer outside the forbidden floor. The selected
    // address is what the ticket encrypts, so the socket path never performs
    // another DNS lookup.
    answers
        .into_iter()
        .find(|address| relay_target_allowed(*address, port))
        .ok_or_else(target_denied)
}

async fn resolve_ticket_target<R: RelayResolver>(
    target_host: &str,
    target_port: u16,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<IpAddr, ApiError> {
    if target_port == 0 {
        return Err(invalid_target());
    }
    if let Ok(ip) = target_host.parse::<IpAddr>() {
        if target_host.len() > 45 {
            return Err(invalid_target());
        }
        if !relay_target_allowed(ip, target_port) {
            return Err(target_denied());
        }
        return Ok(ip);
    }

    let hostname = normalize_dns_hostname(target_host)?;
    resolve_dns_target(
        &hostname,
        target_port,
        resolver,
        lookup_slots,
        lookup_timeout,
    )
    .await
}

async fn create_ticket_with_resolver<R: RelayResolver>(
    state: &AppState,
    headers: &HeaderMap,
    req: TicketRequest,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<Json<Value>, ApiError> {
    if !relay_available(state) {
        return Err(relay_disabled());
    }
    let user = current_user(state, headers).await?;
    if req.device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "requested device does not match session",
        ));
    }
    if state.pg_sync_pool.is_some() {
        crate::pg_relay::ensure_active_device(state, &user.user_id, &req.device_id).await?;
    } else {
        crate::ensure_active_device(state, &user.user_id, &req.device_id).await?;
    }
    let ip = resolve_ticket_target(
        &req.target_host,
        req.target_port,
        resolver,
        lookup_slots,
        lookup_timeout,
    )
    .await?;
    let (ticket, expires) = issue_ticket(
        state,
        &user.user_id,
        &user.device_id,
        &user.session_id,
        &user.access_hash,
        ip,
        req.target_port,
    )
    .await?;
    Ok(Json(
        json!({"ticket":ticket,"expires_at":expires,"connect_path":"/relay/v1/connect"}),
    ))
}

fn is_origin_allowed(expected: &str, headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(ORIGIN).iter();
    matches!(
        (values.next(), values.next()),
        (Some(value), None) if value.to_str().ok() == Some(expected)
    )
}

pub(crate) fn is_valid_ticket(ticket: &str) -> bool {
    if ticket.len() != 43 {
        return false;
    }
    URL_SAFE_NO_PAD
        .decode(ticket)
        .is_ok_and(|bytes| bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == ticket)
}

fn relay_destination_key(state: &AppState) -> Result<Zeroizing<[u8; 32]>, ApiError> {
    let mut key = Zeroizing::new([0_u8; 32]);
    Hkdf::<Sha256>::new(Some(RELAY_DESTINATION_KDF_SALT), &state.auth_rate_key[..])
        .expand(RELAY_DESTINATION_KDF_INFO, &mut *key)
        .map_err(ApiError::internal)?;
    Ok(key)
}

fn relay_destination_aad(ticket_hash: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(RELAY_DESTINATION_AAD_PREFIX.len() + ticket_hash.len());
    aad.extend_from_slice(RELAY_DESTINATION_AAD_PREFIX);
    aad.extend_from_slice(ticket_hash.as_bytes());
    aad
}

pub(crate) fn encrypt_relay_destination(
    state: &AppState,
    ticket_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<String, ApiError> {
    let key = relay_destination_key(state)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(ApiError::internal)?;
    let mut plaintext = Zeroizing::new(Vec::with_capacity(20));
    plaintext.push(1); // destination payload version
    match ip {
        IpAddr::V4(address) => {
            plaintext.push(4);
            plaintext.extend_from_slice(&address.octets());
        }
        IpAddr::V6(address) => {
            plaintext.push(6);
            plaintext.extend_from_slice(&address.octets());
        }
    }
    plaintext.extend_from_slice(&port.to_be_bytes());

    let mut nonce = [0_u8; 24];
    rand::thread_rng().fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &plaintext,
                aad: &relay_destination_aad(ticket_hash),
            },
        )
        .map_err(ApiError::internal)?;
    let mut envelope = Vec::with_capacity(nonce.len() + ciphertext.len());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&ciphertext);
    Ok(format!(
        "{RELAY_DESTINATION_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(envelope)
    ))
}

pub(crate) fn decrypt_relay_destination(
    state: &AppState,
    ticket_hash: &str,
    envelope: &str,
) -> Result<(IpAddr, u16), ()> {
    let encoded = envelope.strip_prefix(RELAY_DESTINATION_PREFIX).ok_or(())?;
    let packed = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| ())?;
    if !(24 + 8 + 16..=24 + 20 + 16).contains(&packed.len())
        || URL_SAFE_NO_PAD.encode(&packed) != encoded
    {
        return Err(());
    }
    let key = relay_destination_key(state).map_err(|_| ())?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(|_| ())?;
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                XNonce::from_slice(&packed[..24]),
                Payload {
                    msg: &packed[24..],
                    aad: &relay_destination_aad(ticket_hash),
                },
            )
            .map_err(|_| ())?,
    );
    if plaintext.len() < 2 {
        return Err(());
    }
    let (ip, port_offset) = match (plaintext[0], plaintext[1]) {
        (1, 4) if plaintext.len() == 1 + 1 + 4 + 2 => (
            IpAddr::V4(Ipv4Addr::new(
                plaintext[2],
                plaintext[3],
                plaintext[4],
                plaintext[5],
            )),
            6,
        ),
        (1, 6) if plaintext.len() == 1 + 1 + 16 + 2 => {
            let mut octets = [0_u8; 16];
            octets.copy_from_slice(&plaintext[2..18]);
            (IpAddr::V6(Ipv6Addr::from(octets)), 18)
        }
        _ => return Err(()),
    };
    let port = u16::from_be_bytes([plaintext[port_offset], plaintext[port_offset + 1]]);
    if port == 0 {
        return Err(());
    }
    Ok((ip, port))
}

/// Invalidates pre-encryption relay tickets before serving requests. Old
/// plaintext destinations are erased from their SQLite pages and the WAL is
/// truncated; these short-lived tickets fail closed across the upgrade.
pub(crate) async fn clear_legacy_relay_ticket_destinations(
    db: &sqlx::SqlitePool,
) -> Result<(), ApiError> {
    let mut connection = db.acquire().await.map_err(ApiError::internal)?;
    sqlx::query("PRAGMA secure_delete=ON")
        .execute(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    let now = now_rfc3339();
    sqlx::query(
        "UPDATE relay_tickets SET consumed_at=COALESCE(consumed_at,?),target_ip='',target_port=0 \
         WHERE (target_ip NOT LIKE 'rtd1:%' OR target_port!=0) \
           AND (consumed_at IS NULL OR target_ip!='' OR target_port!=0)",
    )
    .bind(now)
    .execute(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    // Checkpoint even when the latest row values were already blank: WAL may
    // still contain an earlier plaintext frame from a ticket consumed by the
    // previous server version.
    let checkpoint = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    if checkpoint.get::<i64, _>("busy") != 0 {
        return Err(ApiError::internal(
            "legacy relay ticket cleanup WAL checkpoint was busy",
        ));
    }
    Ok(())
}

pub(crate) fn relay_rate_limit_error(oldest: Option<i64>, now: i64) -> ApiError {
    let retry_after = oldest
        .map(|created| created + TICKET_RATE_WINDOW_SECONDS - now)
        .unwrap_or(1)
        .max(1) as u64;
    let mut error = ApiError::new(
        StatusCode::TOO_MANY_REQUESTS,
        "RELAY_RATE_LIMITED",
        "relay ticket issuance rate exceeded",
    );
    error.retry_after_secs = Some(retry_after);
    error
}

pub async fn create_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TicketRequest>,
) -> Result<Json<Value>, ApiError> {
    create_ticket_with_resolver(
        &state,
        &headers,
        req,
        &SystemRelayResolver,
        &RELAY_DNS_LOOKUP_SLOTS,
        RELAY_DNS_LOOKUP_TIMEOUT,
    )
    .await
}

async fn issue_ticket(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    session_id: &str,
    access_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<(String, String), ApiError> {
    if !relay_target_allowed(ip, port) {
        return Err(target_denied());
    }
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::issue_ticket(
            state,
            user_id,
            device_id,
            session_id,
            access_hash,
            ip,
            port,
        )
        .await;
    }
    let now = Utc::now();
    let now_epoch = now.timestamp();
    let cutoff = now_epoch.saturating_sub(TICKET_RATE_WINDOW_SECONDS);
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

    // Obtain SQLite writer serialization and bind the ticket to the exact
    // active session. This orders issuance against logout and account deletion.
    let session = sqlx::query("UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL RETURNING access_expires_at,refresh_expires_at")
        .bind(session_id)
        .bind(user_id)
        .bind(device_id)
        .bind(access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
    let session_access_expires_at: String = session.get("access_expires_at");
    let session_expiry = DateTime::parse_from_rfc3339(&session_access_expires_at)
        .map_err(ApiError::internal)?
        .with_timezone(&Utc);
    let session_refresh_expires_at: String = session.get("refresh_expires_at");
    let refresh_expiry = DateTime::parse_from_rfc3339(&session_refresh_expires_at)
        .map_err(ApiError::internal)?
        .with_timezone(&Utc);
    if session_expiry <= now || refresh_expiry <= now {
        return Err(ApiError::unauthorized());
    }
    crate::require_active_account_tx(&mut tx, user_id).await?;
    let active_device: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=? AND user_id=? AND status='active')",
    )
    .bind(device_id)
    .bind(user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if !active_device {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    prune_tickets_tx(&mut tx, cutoff).await?;
    let (issued, oldest): (i64, Option<i64>) = sqlx::query_as(
        "SELECT COUNT(*),MIN(created_at) FROM relay_tickets WHERE user_id=? AND created_at>?",
    )
    .bind(user_id)
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if issued >= MAX_TICKETS_PER_USER_PER_WINDOW {
        // Persist the prune even though issuance is rejected. Otherwise a
        // rate-limited request can roll cleanup back and leave the global
        // ticket cap stuck until the next scheduled maintenance run.
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(relay_rate_limit_error(oldest, now_epoch));
    }
    let retained: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_tickets")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if retained >= MAX_RETAINED_TICKETS {
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay ticket capacity is temporarily full",
        ));
    }

    let requested_expiry = now + ChronoDuration::seconds(TICKET_TTL_SECONDS);
    let expires_at = requested_expiry.min(session_expiry).min(refresh_expiry);
    let expires = expires_at.to_rfc3339();
    let mut raw = [0; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = URL_SAFE_NO_PAD.encode(raw);
    let ticket_hash = sha256_hex(ticket.as_bytes());
    let encrypted_destination = encrypt_relay_destination(state, &ticket_hash, ip, port)?;
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
        .bind(ticket_hash)
        .bind(user_id)
        .bind(device_id)
        .bind(encrypted_destination)
        .bind(0_i64)
        .bind(&expires)
        .bind(session_id)
        .bind(&session_access_expires_at)
        .bind(now_epoch)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        state,
        user_id,
        Some(device_id),
        "relay.ticket_issued",
        "relay",
        None,
        crate::audit::AuditSource::Api,
        now_epoch,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((ticket, expires))
}

pub(crate) async fn prune_tickets_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    cutoff: i64,
) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM relay_tickets WHERE created_at<=?")
        .bind(cutoff)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    if !relay_available(&state) {
        return Err(relay_disabled());
    }
    let Some(expected) = state.config.public_origin.as_deref() else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay requires a configured browser origin",
        ));
    };
    if !is_origin_allowed(expected, &headers) {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(64 * 1024)
        .max_frame_size(64 * 1024)
        .on_upgrade(move |socket| relay_socket(socket, state, false)))
}

pub async fn connect_desktop(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    if !relay_available(&state) || state.config.guacd_address.is_none() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "DESKTOP_DISABLED",
            "remote desktop gateway is not configured",
        ));
    }
    // Browsers always send Origin. Native clients authenticate with the same
    // one-use first-frame ticket and need not impersonate a browser origin.
    if headers.contains_key(ORIGIN)
        && !is_origin_allowed(
            state.config.public_origin.as_deref().unwrap_or(""),
            &headers,
        )
    {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(96 * 1024)
        .max_frame_size(96 * 1024)
        .on_upgrade(move |socket| relay_socket(socket, state, true)))
}

async fn consume_ticket(state: &AppState, token: &str) -> Result<Option<RelayTarget>, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::consume_ticket(state, token).await;
    }
    if !is_valid_ticket(token) {
        return Ok(None);
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let ticket_hash = sha256_hex(token.as_bytes());
    let row = sqlx::query("UPDATE relay_tickets SET consumed_at=? WHERE ticket_hash=? AND consumed_at IS NULL AND expires_at>? AND session_id IS NOT NULL AND session_access_expires_at IS NOT NULL AND EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=relay_tickets.session_id AND s.user_id=relay_tickets.user_id AND s.device_id=relay_tickets.device_id AND s.access_expires_at=relay_tickets.session_access_expires_at AND s.access_expires_at>? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active') RETURNING user_id,device_id,session_id,target_ip,target_port")
        .bind(&now_text)
        .bind(&ticket_hash)
        .bind(&now_text)
        .bind(&now_text)
        .bind(&now_text)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let encrypted_destination: String = row.get("target_ip");
    let target_port: i64 = row.get("target_port");
    let destination = if target_port == 0 {
        decrypt_relay_destination(state, &ticket_hash, &encrypted_destination).ok()
    } else {
        None
    };
    // Clear the bound destination as soon as the one-use ticket is consumed.
    sqlx::query("UPDATE relay_tickets SET target_ip='',target_port=0 WHERE ticket_hash=?")
        .bind(&ticket_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    let Some((ip, port)) = destination.filter(|(ip, port)| relay_target_allowed(*ip, *port)) else {
        return Ok(None);
    };
    Ok(Some(RelayTarget {
        user_id: row.get("user_id"),
        device_id: row.get("device_id"),
        session_id: row.get("session_id"),
        ip,
        port,
        connection_id: None,
    }))
}

async fn relay_session_active(state: &AppState, target: &RelayTarget) -> bool {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::relay_session_active(state, target).await;
    }
    let now_text = now_rfc3339();
    let result = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .bind(now_text)
        .fetch_one(&state.db)
        .await;
    match result {
        Ok(active) => active,
        Err(_) => {
            tracing::warn!(event = "relay_session_state_check_failed");
            false
        }
    }
}

async fn relay_connection_active(state: &AppState, target: &RelayTarget) -> bool {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::relay_connection_active(state, target).await;
    }
    relay_target_allowed(target.ip, target.port) && relay_session_active(state, target).await
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RelayIoAbort {
    Deadline,
    SessionInactive,
    IoTimeout,
}

/// Keeps the session poll and absolute connection deadline live while a
/// backpressured socket write is pending. The pending write is retained across
/// active session checks and is dropped only when the connection must close.
async fn relay_io_with_guards<F, T>(
    future: F,
    state: &AppState,
    target: &RelayTarget,
    deadline_at: Instant,
    session_check: &mut Interval,
) -> Result<T, RelayIoAbort>
where
    F: Future<Output = T>,
{
    tokio::pin!(future);
    let deadline = tokio::time::sleep_until(deadline_at);
    tokio::pin!(deadline);
    let io_timeout = tokio::time::sleep(RELAY_IO_TIMEOUT);
    tokio::pin!(io_timeout);
    loop {
        tokio::select! {
            _ = &mut deadline => return Err(RelayIoAbort::Deadline),
            _ = &mut io_timeout => return Err(RelayIoAbort::IoTimeout),
            _ = session_check.tick() => {
                let active = tokio::time::timeout(
                    RELAY_SESSION_CHECK_TIMEOUT,
                    relay_connection_active(state, target),
                )
                .await
                .unwrap_or_else(|_| {
                    tracing::warn!(event = "relay_session_state_check_timed_out");
                    false
                });
                if !active {
                    tracing::warn!(event = "relay_connection_closed", reason = "session_inactive");
                    return Err(RelayIoAbort::SessionInactive);
                }
            }
            result = &mut future => return Ok(result),
        }
    }
}

/// Records a successful TCP connection before any SSH bytes are forwarded.
/// The writer lock orders this check with logout, device revocation and purge.
/// Access-token refresh keeps the session ID; it must not invalidate an SSH
/// transport whose short-lived ticket was already consumed. Once connected,
/// the refresh-token expiry is the session lifetime boundary: the access token
/// may briefly expire before the client receives its refresh hint.
async fn record_connected(
    state: &AppState,
    target: &RelayTarget,
    connection_id: uuid::Uuid,
) -> Result<bool, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::record_connected(state, target, connection_id).await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let locked = sqlx::query("UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND revoked_at IS NULL")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() != 1 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .bind(now_text)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if !active {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        state,
        &target.user_id,
        Some(&target.device_id),
        "relay.connected",
        "relay",
        None,
        crate::audit::AuditSource::Api,
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(true)
}

fn acquire_connection(state: Arc<AppState>, user_id: &str) -> Option<RelayConnectionGuard> {
    let global_permit = state
        .relay_connection_slots
        .clone()
        .try_acquire_owned()
        .ok()?;
    let mut connections = state.relay_connections.lock().ok()?;
    let count = connections.get(user_id).copied().unwrap_or_default();
    if count >= state.config.relay_max_connections_per_user {
        return None;
    }
    *connections.entry(user_id.to_owned()).or_default() += 1;
    drop(connections);
    Some(RelayConnectionGuard {
        state,
        user_id: user_id.to_owned(),
        _global_permit: global_permit,
    })
}

async fn send_close(socket: &mut WebSocket) {
    let _ = tokio::time::timeout(RELAY_SHUTDOWN_TIMEOUT, socket.send(Message::Close(None))).await;
}

async fn relay_socket(mut socket: WebSocket, state: Arc<AppState>, desktop: bool) {
    let token = match tokio::time::timeout(Duration::from_secs(10), socket.recv()).await {
        Ok(Some(Ok(Message::Text(value)))) => value.to_string(),
        Ok(Some(Ok(Message::Binary(value)))) => {
            String::from_utf8(value.to_vec()).unwrap_or_default()
        }
        _ => {
            send_close(&mut socket).await;
            return;
        }
    };
    if !is_valid_ticket(&token) {
        send_close(&mut socket).await;
        return;
    }
    let target = match consume_ticket(&state, &token).await {
        Ok(Some(target)) => target,
        _ => {
            send_close(&mut socket).await;
            return;
        }
    };
    let session_active = tokio::time::timeout(
        RELAY_SESSION_CHECK_TIMEOUT,
        relay_connection_active(&state, &target),
    )
    .await
    .unwrap_or_else(|_| {
        tracing::warn!(event = "relay_session_state_check_timed_out");
        false
    });
    if !session_active {
        tracing::warn!(
            event = "relay_connection_closed",
            reason = "session_inactive"
        );
        send_close(&mut socket).await;
        return;
    }
    let Some(guard) = acquire_connection(state.clone(), &target.user_id) else {
        send_close(&mut socket).await;
        return;
    };
    let destination = if desktop {
        let Some(address) = state.config.guacd_address.as_ref() else {
            return;
        };
        address.clone()
    } else {
        SocketAddr::new(target.ip, target.port).to_string()
    };
    let mut tcp =
        match tokio::time::timeout(RELAY_CONNECT_TIMEOUT, TcpStream::connect(destination)).await {
            Ok(Ok(stream)) => stream,
            Ok(Err(_)) | Err(_) => {
                send_close(&mut socket).await;
                drop(guard);
                return;
            }
        };
    if desktop {
        let setup = async {
            let Some(Ok(Message::Text(text))) = socket.recv().await else {
                return Err(());
            };
            let hello = serde_json::from_str::<crate::desktop::DesktopHello>(&text).map_err(|_| ());
            // Credentials are transient; never logged or persisted in tickets.
            drop(text);
            crate::desktop::handshake(&mut tcp, hello?, target.ip, target.port).await
        };
        if !matches!(timeout(RELAY_CONNECT_TIMEOUT, setup).await, Ok(Ok(()))) {
            send_close(&mut socket).await;
            return;
        }
    }
    let mut target = target;
    let connection_id = uuid::Uuid::new_v4();
    match record_connected(&state, &target, connection_id).await {
        Ok(true) => target.connection_id = Some(connection_id),
        _ => {
            send_close(&mut socket).await;
            drop(tcp);
            drop(guard);
            return;
        }
    }

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (mut tcp_rx, mut tcp_tx) = tokio::io::split(tcp);
    let mut buf = vec![0_u8; 16 * 1024];
    let mut transferred = 0_u64;
    let deadline_at = Instant::now() + MAX_RELAY_DURATION;
    let mut session_check = tokio::time::interval(Duration::from_secs(RELAY_POLL_SESSION_SECONDS));
    session_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    session_check.tick().await;
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline_at) => break,
            _ = session_check.tick() => {
                let active = tokio::time::timeout(
                    RELAY_SESSION_CHECK_TIMEOUT,
                    relay_connection_active(&state, &target),
                )
                .await
                .unwrap_or_else(|_| {
                    tracing::warn!(event = "relay_session_state_check_timed_out");
                    false
                });
                if !active {
                    tracing::warn!(event = "relay_connection_closed", reason = "session_inactive");
                    break;
                }
            },
            inbound = ws_rx.next() => match inbound {
                Some(Ok(Message::Binary(bytes))) => {
                    if desktop && !crate::desktop::valid_input(&bytes) { break; }
                    transferred = transferred.saturating_add(bytes.len() as u64);
                    if transferred > MAX_RELAY_BYTES {
                        break;
                    }
                    if !matches!(
                        relay_io_with_guards(
                            tcp_tx.write_all(&bytes),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Some(Ok(Message::Ping(payload))) => {
                    if !matches!(
                        relay_io_with_guards(
                            ws_tx.send(Message::Pong(payload)),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                Some(Ok(_)) => break,
            },
            read = tcp_rx.read(&mut buf) => match read {
                Ok(0) => {
                    let _ = tokio::time::timeout(
                        RELAY_SHUTDOWN_TIMEOUT,
                        ws_tx.send(Message::Close(None)),
                    )
                    .await;
                    break;
                }
                Ok(count) => {
                    transferred = transferred.saturating_add(count as u64);
                    if transferred > MAX_RELAY_BYTES {
                        break;
                    }
                    if !matches!(
                        relay_io_with_guards(
                            ws_tx.send(Message::Binary(axum::body::Bytes::copy_from_slice(&buf[..count]))),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Err(_) => break,
            },
        }
    }
    let _ = tokio::time::timeout(RELAY_SHUTDOWN_TIMEOUT, tcp_tx.shutdown()).await;
    if state.pg_sync_pool.is_some()
        && let Some(connection_id) = target.connection_id
    {
        crate::pg_relay::release_connection_lease(&state, connection_id).await;
    }
    drop(guard);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AuthRateLimits, Config, auth::AuthUser, open_state, secure_file::create_private_data_dir,
    };
    use axum::http::HeaderValue;
    use chrono::Duration as ChronoDuration;
    use std::{
        path::PathBuf,
        sync::{
            Mutex as StdMutex,
            atomic::{AtomicUsize, Ordering},
        },
    };
    use uuid::Uuid;

    #[derive(Clone)]
    enum FakeResolveResult {
        Answers(Vec<IpAddr>),
        Error,
        Pending,
    }

    struct FakeRelayResolver {
        expected_hostname: String,
        result: StdMutex<FakeResolveResult>,
        calls: AtomicUsize,
    }

    impl FakeRelayResolver {
        fn new(expected_hostname: &str, result: FakeResolveResult) -> Self {
            Self {
                expected_hostname: expected_hostname.to_owned(),
                result: StdMutex::new(result),
                calls: AtomicUsize::new(0),
            }
        }

        fn set_result(&self, result: FakeResolveResult) {
            *self.result.lock().unwrap() = result;
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    impl RelayResolver for FakeRelayResolver {
        fn resolve<'a>(
            &'a self,
            hostname: &'a str,
            _port: u16,
            permit: OwnedSemaphorePermit,
        ) -> RelayResolveFuture<'a> {
            assert_eq!(hostname, self.expected_hostname);
            self.calls.fetch_add(1, Ordering::SeqCst);
            let result = self.result.lock().unwrap().clone();
            Box::pin(async move {
                let _permit = permit;
                match result {
                    FakeResolveResult::Answers(addresses) => Ok(addresses),
                    FakeResolveResult::Error => Err(io::Error::other("synthetic resolver error")),
                    FakeResolveResult::Pending => {
                        std::future::pending::<io::Result<Vec<IpAddr>>>().await
                    }
                }
            })
        }
    }

    struct BlockingFakeRelayResolver {
        started: Arc<tokio::sync::Notify>,
        finished: Arc<tokio::sync::Notify>,
        release: StdMutex<Option<std::sync::mpsc::Sender<()>>>,
    }

    impl BlockingFakeRelayResolver {
        fn new() -> Self {
            Self {
                started: Arc::new(tokio::sync::Notify::new()),
                finished: Arc::new(tokio::sync::Notify::new()),
                release: StdMutex::new(None),
            }
        }

        fn release(&self) {
            self.release
                .lock()
                .unwrap()
                .take()
                .unwrap()
                .send(())
                .unwrap();
        }
    }

    impl RelayResolver for BlockingFakeRelayResolver {
        fn resolve<'a>(
            &'a self,
            _hostname: &'a str,
            _port: u16,
            permit: OwnedSemaphorePermit,
        ) -> RelayResolveFuture<'a> {
            let (release, wait_for_release) = std::sync::mpsc::channel();
            *self.release.lock().unwrap() = Some(release);
            let started = self.started.clone();
            let finished = self.finished.clone();
            let worker = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                started.notify_one();
                wait_for_release
                    .recv()
                    .map_err(|_| io::Error::other("test resolver release channel closed"))?;
                finished.notify_one();
                Ok(vec!["10.2.3.4".parse().unwrap()])
            });
            Box::pin(async move {
                worker
                    .await
                    .map_err(|_| io::Error::other("synthetic resolver worker failed"))?
            })
        }
    }

    fn test_config(data_dir: PathBuf) -> Config {
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
            relay_enabled: true,
            terminal_collaboration_enabled: false,
            relay_max_connections_per_user: 1,
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
            admin_usernames: Vec::new(),
            auth_rate_limits: AuthRateLimits::default(),
        }
    }

    async fn test_state() -> AppState {
        let data_dir = std::env::temp_dir().join(format!("atermius-relay-{}", Uuid::new_v4()));
        create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        open_state(&database, test_config(data_dir)).await.unwrap()
    }

    async fn close_state(state: &AppState) {
        let path = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(path).await.unwrap();
    }

    async fn seed_session(state: &AppState) -> (AuthUser, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("relay-access-{}", Uuid::new_v4());
        let now = Utc::now();
        let expires = (now + ChronoDuration::minutes(10)).to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("relay-{}@example.test", Uuid::new_v4()))
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'relay-test','sign','enc',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'relay-family',?,?,?,? ,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(sha256_hex(access.as_bytes()))
            .bind(format!("relay-refresh-{}", Uuid::new_v4()))
            .bind(&expires)
            .bind((now + ChronoDuration::days(30)).to_rfc3339())
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

    fn auth_headers(access: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access}")).unwrap(),
        );
        headers
    }

    /// Resolver for IP-literal targets, which must never reach DNS.
    fn no_dns() -> FakeRelayResolver {
        FakeRelayResolver::new("dns-must-not-be-used.invalid", FakeResolveResult::Error)
    }

    async fn resolve_literal(host: &str, port: u16) -> Result<IpAddr, ApiError> {
        let resolver = no_dns();
        let result = resolve_ticket_target(
            host,
            port,
            &resolver,
            &Arc::new(Semaphore::new(1)),
            Duration::from_secs(1),
        )
        .await;
        assert_eq!(resolver.calls(), 0, "{host} must not be resolved");
        result
    }

    const FORBIDDEN_TARGETS: [&str; 17] = [
        "127.0.0.1",
        "127.10.20.30",
        "::1",
        "169.254.2.1",
        "fe80::1",
        "169.254.169.254",
        "100.100.100.200",
        "fd00:ec2::254",
        "224.0.0.1",
        "ff02::1",
        "255.255.255.255",
        "0.0.0.0",
        "::",
        "::ffff:127.0.0.1",
        "::ffff:169.254.169.254",
        "::ffff:100.100.100.200",
        "::ffff:224.0.0.1",
    ];

    #[test]
    fn destination_rule_is_only_a_nonzero_port_outside_the_forbidden_floor() {
        for value in FORBIDDEN_TARGETS {
            let ip: IpAddr = value.parse().unwrap();
            assert!(
                is_forbidden_ip(ip),
                "{value} must be in the forbidden floor"
            );
            assert!(!relay_target_allowed(ip, 22), "{value} must be denied");
        }
        assert!(is_forbidden_ip(EC2_IPV6_METADATA.into()));
        for value in [
            "10.20.30.40",
            "192.168.1.5",
            "172.16.0.9",
            "100.64.0.1",
            "198.51.100.7",
            "8.8.8.8",
            "fd12:3456::1",
            "2001:db8::1",
            "::ffff:10.20.30.40",
        ] {
            let ip: IpAddr = value.parse().unwrap();
            for port in [1, 22, 2222, 3389, 65535] {
                assert!(
                    relay_target_allowed(ip, port),
                    "{value}:{port} must be allowed"
                );
            }
            assert!(!relay_target_allowed(ip, 0), "{value}:0 must be denied");
        }
    }

    #[tokio::test]
    async fn ip_literal_targets_need_no_policy_and_still_reject_the_forbidden_floor() {
        assert_eq!(
            resolve_literal("10.20.30.40", 2222).await.unwrap(),
            "10.20.30.40".parse::<IpAddr>().unwrap()
        );
        assert_eq!(
            resolve_literal("fd12:3456::1", 22).await.unwrap(),
            "fd12:3456::1".parse::<IpAddr>().unwrap()
        );
        for value in FORBIDDEN_TARGETS {
            let error = resolve_literal(value, 22).await.unwrap_err();
            assert_eq!(error.status, StatusCode::FORBIDDEN, "{value}");
            assert_eq!(error.body.code, "TARGET_DENIED", "{value}");
            assert!(!error.body.message.contains("policy"));
        }
        // Port zero and malformed literals stay request validation errors.
        let zero = resolve_literal("10.20.30.40", 0).await.unwrap_err();
        assert_eq!(zero.status, StatusCode::BAD_REQUEST);
        assert_eq!(zero.body.code, "INVALID_TARGET");
        for malformed in ["10.20.30.40:22", "[::1]", "bad..example", ""] {
            assert_eq!(
                resolve_literal(malformed, 22).await.unwrap_err().body.code,
                "INVALID_TARGET",
                "{malformed:?}"
            );
        }
    }

    #[test]
    fn dns_hostnames_require_ascii_idna_alabels_and_normalize_root_and_case() {
        assert_eq!(
            normalize_dns_hostname("SSH.XN--BCHER-KVA.Example.").unwrap(),
            "ssh.xn--bcher-kva.example"
        );
        assert_eq!(
            normalize_dns_hostname("Host.Example.Test").unwrap(),
            "host.example.test"
        );
        for invalid in [
            "",
            "bücher.example",
            "bad..example",
            "-bad.example",
            "bad-.example",
            "bad_.example",
            "xn--.example",
            "127.1",
            "999.1.1.1",
            "a..",
        ] {
            assert!(
                normalize_dns_hostname(invalid).is_err(),
                "{invalid:?} must be rejected"
            );
        }
        let long_label = format!("{}.example", "a".repeat(64));
        assert!(normalize_dns_hostname(&long_label).is_err());
        let max_name = format!(
            "{}.{}.{}.{}",
            "a".repeat(63),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(61)
        );
        assert_eq!(max_name.len(), 253);
        assert_eq!(normalize_dns_hostname(&max_name).unwrap(), max_name);
        let max_absolute_name = format!("{max_name}.");
        assert_eq!(max_absolute_name.len(), 254);
        assert_eq!(
            normalize_dns_hostname(&max_absolute_name).unwrap(),
            max_name
        );
        assert!(normalize_dns_hostname(&format!("{max_name}x")).is_err());
        let long_name = (0..4).map(|_| "a".repeat(63)).collect::<Vec<_>>().join(".");
        assert!(long_name.len() > 253);
        assert!(normalize_dns_hostname(&long_name).is_err());
    }

    #[tokio::test]
    async fn relay_dns_selects_the_first_answer_outside_the_forbidden_floor() {
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "127.0.0.1".parse().unwrap(),
                "100.100.100.200".parse().unwrap(),
                "::ffff:127.0.0.1".parse().unwrap(),
                "192.168.1.5".parse().unwrap(),
                "10.2.3.5".parse().unwrap(),
            ]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let selected = resolve_dns_target(
            "ssh.example.test",
            2222,
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert_eq!(selected, "192.168.1.5".parse::<IpAddr>().unwrap());
        assert_eq!(resolver.calls(), 1);

        let zero_port = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.4".parse().unwrap()]),
        );
        let invalid = resolve_dns_target(
            "ssh.example.test",
            0,
            &zero_port,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_TARGET");
        assert_eq!(zero_port.calls(), 0);

        let no_allowed_answer = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "127.0.0.1".parse().unwrap(),
                "169.254.169.254".parse().unwrap(),
                "fd00:ec2::254".parse().unwrap(),
                "224.0.0.1".parse().unwrap(),
            ]),
        );
        let denied = resolve_dns_target(
            "ssh.example.test",
            22,
            &no_allowed_answer,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(denied.status, StatusCode::FORBIDDEN);
        assert_eq!(denied.body.code, "TARGET_DENIED");
    }

    #[tokio::test]
    async fn relay_dns_failures_timeouts_and_answer_overflow_are_bounded() {
        let slots = Arc::new(Semaphore::new(1));
        let cases = [
            FakeResolveResult::Answers(Vec::new()),
            FakeResolveResult::Error,
            FakeResolveResult::Pending,
            FakeResolveResult::Answers(
                (1..=MAX_RELAY_DNS_ANSWERS + 1)
                    .map(|last| IpAddr::V4(Ipv4Addr::new(10, 2, 3, last as u8)))
                    .collect(),
            ),
        ];
        for (index, result) in cases.into_iter().enumerate() {
            let resolver = FakeRelayResolver::new("ssh.example.test", result);
            let error = resolve_dns_target(
                "ssh.example.test",
                22,
                &resolver,
                &slots,
                if index == 2 {
                    Duration::from_millis(5)
                } else {
                    Duration::from_secs(1)
                },
            )
            .await
            .unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_GATEWAY);
            assert_eq!(error.body.code, "TARGET_RESOLUTION_FAILED");
            assert!(!error.body.message.contains("ssh.example.test"));
            assert_eq!(resolver.calls(), 1);
        }
    }

    #[tokio::test]
    async fn relay_dns_concurrency_gate_rejects_without_starting_resolution() {
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.4".parse().unwrap()]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let _held = slots.clone().try_acquire_owned().unwrap();
        let error = resolve_dns_target(
            "ssh.example.test",
            22,
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.body.code, "RELAY_BUSY");
        assert_eq!(resolver.calls(), 0);
    }

    #[tokio::test]
    async fn timed_out_blocking_dns_keeps_its_concurrency_slot_until_worker_finishes() {
        let slots = Arc::new(Semaphore::new(1));
        let resolver = BlockingFakeRelayResolver::new();
        let error = resolve_dns_target(
            "ssh.example.test",
            22,
            &resolver,
            &slots,
            Duration::from_millis(1),
        )
        .await
        .unwrap_err();
        assert_eq!(error.body.code, "TARGET_RESOLUTION_FAILED");
        resolver.started.notified().await;
        assert_eq!(slots.available_permits(), 0);

        let second = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.8".parse().unwrap()]),
        );
        let busy = resolve_dns_target(
            "ssh.example.test",
            22,
            &second,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(busy.body.code, "RELAY_BUSY");
        assert_eq!(second.calls(), 0);

        let finished = resolver.finished.notified();
        resolver.release();
        finished.await;
        assert_eq!(slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn consumed_dns_ticket_uses_the_original_selected_ip_without_resolving_again() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "127.0.0.1".parse().unwrap(),
                "10.2.3.4".parse().unwrap(),
            ]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let Json(body) = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "SSH.Example.Test.".to_owned(),
                target_port: 22,
            },
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        let ticket = body["ticket"].as_str().unwrap();
        assert_eq!(resolver.calls(), 1);

        let (stored_destination, stored_port): (String, i64) =
            sqlx::query_as("SELECT target_ip,target_port FROM relay_tickets WHERE ticket_hash=?")
                .bind(sha256_hex(ticket.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(!stored_destination.contains("ssh.example.test"));
        assert_eq!(stored_port, 0);

        resolver.set_result(FakeResolveResult::Answers(vec![
            "10.9.8.7".parse().unwrap(),
        ]));
        let target = consume_ticket(&state, ticket).await.unwrap().unwrap();
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);
        assert_eq!(resolver.calls(), 1);
        close_state(&state).await;
    }

    #[test]
    fn relay_origin_requires_one_exact_header_and_ticket_is_canonical() {
        let expected = "https://relay.example.test";
        let mut headers = HeaderMap::new();
        headers.insert(ORIGIN, HeaderValue::from_static(expected));
        assert!(is_origin_allowed(expected, &headers));
        headers.append(ORIGIN, HeaderValue::from_static(expected));
        assert!(!is_origin_allowed(expected, &headers));
        headers.remove(ORIGIN);
        assert!(!is_origin_allowed(expected, &headers));

        let token = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        assert!(is_valid_ticket(&token));
        assert!(!is_valid_ticket(&format!("{token}=")));
        assert!(!is_valid_ticket("not-a-ticket"));
    }

    #[tokio::test]
    async fn ticket_issue_is_session_bound_rate_limited_and_audited_without_target_data() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let request = || TicketRequest {
            device_id: user.device_id.clone(),
            target_host: "10.2.3.4".to_owned(),
            target_port: 22,
        };
        let Json(body) =
            create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
                .await
                .unwrap();
        let token = body["ticket"].as_str().unwrap();
        assert_eq!(body["connect_path"], "/relay/v1/connect");
        let ticket = sqlx::query("SELECT ticket_hash,user_id,device_id,session_id,target_ip,target_port,created_at FROM relay_tickets")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(
            ticket.get::<String, _>("ticket_hash"),
            sha256_hex(token.as_bytes())
        );
        assert_eq!(ticket.get::<String, _>("session_id"), user.session_id);
        let stored_destination: String = ticket.get("target_ip");
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(!stored_destination.contains("10.2.3.4"));
        assert_eq!(ticket.get::<i64, _>("target_port"), 0);

        let scope = crate::audit::account_scope_id(&state.cursor_key, &user.user_id).unwrap();
        let audit = sqlx::query("SELECT action,resource_type,resource_id,actor_user_id,actor_device_id FROM audit_events WHERE scope_type='account' AND scope_id=?")
            .bind(scope)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(audit.get::<String, _>("action"), "relay.ticket_issued");
        assert_eq!(audit.get::<String, _>("resource_type"), "relay");
        assert_eq!(audit.get::<Option<String>, _>("resource_id"), None);
        assert_eq!(
            audit.get::<Option<String>, _>("actor_user_id").as_deref(),
            Some(user.user_id.as_str())
        );
        assert_eq!(
            audit.get::<Option<String>, _>("actor_device_id").as_deref(),
            Some(user.device_id.as_str())
        );

        let target = consume_ticket(&state, token).await.unwrap().unwrap();
        assert_eq!(target.user_id, user.user_id);
        assert_eq!(target.session_id, user.session_id);
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);
        assert!(consume_ticket(&state, token).await.unwrap().is_none());
        let cleared: (String, i64) =
            sqlx::query_as("SELECT target_ip,target_port FROM relay_tickets")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(cleared, (String::new(), 0));

        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,created_at) VALUES('stale-throttle-row',?,?, '10.2.3.4',22,?,?)")
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(Utc::now().timestamp() - TICKET_RATE_WINDOW_SECONDS - 1)
            .execute(&state.db)
            .await
            .unwrap();
        for _ in 1..MAX_TICKETS_PER_USER_PER_WINDOW {
            let _ = create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
                .await
                .unwrap();
        }
        let limited = create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
            .await
            .unwrap_err();
        assert_eq!(limited.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(limited.body.code, "RELAY_RATE_LIMITED");
        assert!(limited.retry_after_secs.is_some());
        let stale: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash='stale-throttle-row'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            stale, 0,
            "rate-limited attempts must commit stale-row cleanup"
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn encrypted_relay_ticket_destination_survives_server_restart() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let data_dir = state.config.data_dir.clone();
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let config = (*state.config).clone();
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let ticket = body["ticket"].as_str().unwrap().to_owned();
        let ticket_hash = sha256_hex(ticket.as_bytes());
        let stored_destination: String =
            sqlx::query_scalar("SELECT target_ip FROM relay_tickets WHERE ticket_hash=?")
                .bind(&ticket_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));

        // Close only the pool. The owner-only auth-rate-limit secret and DB
        // remain in place, so the relay destination key stays stable.
        state.db.close().await;
        let restarted = open_state(&database_url, config).await.unwrap();

        let target = consume_ticket(&restarted, &ticket)
            .await
            .unwrap()
            .expect("outstanding ticket should remain usable after restart");
        assert_eq!(target.user_id, user.user_id);
        assert_eq!(target.device_id, user.device_id);
        assert_eq!(target.session_id, user.session_id);
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);

        let row: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(ticket_hash)
        .fetch_one(&restarted.db)
        .await
        .unwrap();
        assert!(row.0.is_some());
        assert_eq!((row.1.as_str(), row.2), ("", 0));
        close_state(&restarted).await;
    }

    #[tokio::test]
    async fn relay_ticket_destination_tampering_and_hash_swaps_fail_closed_and_clear() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let (first_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let (second_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let first_hash = sha256_hex(first_ticket.as_bytes());
        let second_hash = sha256_hex(second_ticket.as_bytes());
        let (first_envelope, second_envelope): (String, String) = sqlx::query_as(
            "SELECT target_ip,(SELECT target_ip FROM relay_tickets WHERE ticket_hash=?) \
             FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&second_hash)
        .bind(&first_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(first_envelope.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(second_envelope.starts_with(RELAY_DESTINATION_PREFIX));

        // A ciphertext copied to a different ticket hash must fail AEAD
        // authentication and burn the claimed ticket without exposing a
        // destination or leaving encrypted metadata behind.
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(&second_envelope)
            .bind(&first_hash)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(&first_envelope)
            .bind(&second_hash)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &first_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let first_state: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&first_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(first_state.0.is_some());
        assert_eq!((first_state.1.as_str(), first_state.2), ("", 0));
        assert!(
            consume_ticket(&state, &second_ticket)
                .await
                .unwrap()
                .is_none()
        );

        let (tampered_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let tampered_hash = sha256_hex(tampered_ticket.as_bytes());
        let mut tampered_envelope: String =
            sqlx::query_scalar("SELECT target_ip FROM relay_tickets WHERE ticket_hash=?")
                .bind(&tampered_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let encoded = tampered_envelope
            .strip_prefix(RELAY_DESTINATION_PREFIX)
            .unwrap();
        let mut packed = URL_SAFE_NO_PAD.decode(encoded).unwrap();
        let last = packed.last_mut().unwrap();
        *last ^= 0x80;
        tampered_envelope = format!(
            "{RELAY_DESTINATION_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(packed)
        );
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(tampered_envelope)
            .bind(&tampered_hash)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &tampered_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let tampered_state: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(tampered_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(tampered_state.0.is_some());
        assert_eq!((tampered_state.1.as_str(), tampered_state.2), ("", 0));
        close_state(&state).await;
    }

    #[tokio::test]
    async fn legacy_plaintext_destinations_are_invalidated_and_scrubbed() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let session_access_expires_at: String =
            sqlx::query_scalar("SELECT access_expires_at FROM sessions WHERE session_id=?")
                .bind(&user.session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let marker = "198.51.100.237";
        let token = URL_SAFE_NO_PAD.encode([0xa7_u8; 32]);
        let ticket_hash = sha256_hex(token.as_bytes());
        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&ticket_hash)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(marker)
            .bind(2222_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(&session_access_expires_at)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();

        // Model the previous implementation's already-consumed row: its
        // current SQL values are blank, while an older WAL frame can still
        // retain the original destination until startup truncates the WAL.
        let consumed_marker = "198.51.100.238";
        let consumed_token = URL_SAFE_NO_PAD.encode([0xa8_u8; 32]);
        let consumed_hash = sha256_hex(consumed_token.as_bytes());
        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&consumed_hash)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(consumed_marker)
            .bind(2223_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(&session_access_expires_at)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE relay_tickets SET consumed_at=?,target_ip='',target_port=0 WHERE ticket_hash=?",
        )
        .bind(now_rfc3339())
        .bind(&consumed_hash)
        .execute(&state.db)
        .await
        .unwrap();

        clear_legacy_relay_ticket_destinations(&state.db)
            .await
            .unwrap();

        let ticket: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(ticket.0.is_some());
        assert_eq!((ticket.1.as_str(), ticket.2), ("", 0));
        assert!(consume_ticket(&state, &token).await.unwrap().is_none());
        let consumed_ticket: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&consumed_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(consumed_ticket.0.is_some());
        assert_eq!((consumed_ticket.1.as_str(), consumed_ticket.2), ("", 0));

        let database_path = state.config.data_dir.join("atermius.db");
        let database_bytes = std::fs::read(database_path).unwrap();
        for plaintext_marker in [marker, consumed_marker] {
            assert!(
                !database_bytes
                    .windows(plaintext_marker.len())
                    .any(|window| window == plaintext_marker.as_bytes())
            );
        }
        let wal_path = state.config.data_dir.join("atermius.db-wal");
        if wal_path.exists() {
            let wal_bytes = std::fs::read(wal_path).unwrap();
            for plaintext_marker in [marker, consumed_marker] {
                assert!(
                    !wal_bytes
                        .windows(plaintext_marker.len())
                        .any(|window| window == plaintext_marker.as_bytes())
                );
            }
        }
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_ticket_lifetime_is_bounded_by_refresh_expiry() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let refresh_expiry = (Utc::now() + ChronoDuration::seconds(20)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(&refresh_expiry)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();

        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        assert_eq!(body["expires_at"], refresh_expiry);
        let token = body["ticket"].as_str().unwrap();

        let expired_refresh = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(expired_refresh)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(consume_ticket(&state, token).await.unwrap().is_none());
        let expired_issue = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(expired_issue.status, StatusCode::UNAUTHORIZED);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn revoked_session_cannot_consume_relay_ticket() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let token = body["ticket"].as_str().unwrap().to_owned();
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(consume_ticket(&state, &token).await.unwrap().is_none());
        let consumed: Option<String> = sqlx::query_scalar("SELECT consumed_at FROM relay_tickets")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(consumed, None);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn concurrent_ticket_replay_has_one_winner_and_records_connection_without_target() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let token = body["ticket"].as_str().unwrap().to_owned();
        let (first, second) = tokio::join!(
            consume_ticket(&state, &token),
            consume_ticket(&state, &token)
        );
        assert_eq!(
            usize::from(first.unwrap().is_some()) + usize::from(second.unwrap().is_some()),
            1
        );
        let target = sqlx::query(
            "SELECT user_id,device_id,session_id,target_ip,target_port FROM relay_tickets",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        let connection = RelayTarget {
            user_id: target.get("user_id"),
            device_id: target.get("device_id"),
            session_id: target.get("session_id"),
            ip: "10.2.3.4".parse().unwrap(),
            port: 22,
            connection_id: None,
        };
        assert!(
            record_connected(&state, &connection, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        let scope = crate::audit::account_scope_id(&state.cursor_key, &user.user_id).unwrap();
        let actions: Vec<String> = sqlx::query_scalar("SELECT action FROM audit_events WHERE scope_type='account' AND scope_id=? ORDER BY event_id")
            .bind(scope)
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert_eq!(
            actions,
            vec![
                "relay.ticket_issued".to_owned(),
                "relay.connected".to_owned()
            ]
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_connection_survives_access_expiry_and_refresh_but_not_session_expiry_or_revocation()
     {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let target = consume_ticket(&state, body["ticket"].as_str().unwrap())
            .await
            .unwrap()
            .expect("fresh ticket should bind to its active session");

        // A just-expired access token may precede the client's notification
        // refresh. That does not end an already-authorized SSH transport while
        // the session's refresh lifetime is still active.
        let expired_access = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET access_expires_at=? WHERE session_id=?")
            .bind(expired_access)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(relay_session_active(&state, &target).await);
        assert!(
            record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=?")
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("UPDATE users SET status='disabled' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        sqlx::query("UPDATE users SET status='active' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();

        // Refresh rotates bearer credentials and extends the same session.
        // An already-consumed one-use ticket stays attached to that session.
        let refreshed_expiry = (Utc::now() + ChronoDuration::minutes(20)).to_rfc3339();
        sqlx::query("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires_at=? WHERE session_id=?")
            .bind(sha256_hex(b"rotated access token"))
            .bind(sha256_hex(b"rotated refresh token"))
            .bind(refreshed_expiry)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();

        assert!(relay_session_active(&state, &target).await);
        assert!(
            record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        let expired_refresh = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(expired_refresh)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_connection_limits_cover_user_and_instance_and_release_on_drop() {
        let mut state = test_state().await;
        state.relay_connection_slots = Arc::new(tokio::sync::Semaphore::new(2));
        let state = Arc::new(state);
        let first = acquire_connection(state.clone(), "user-a").unwrap();
        assert!(acquire_connection(state.clone(), "user-a").is_none());
        let second = acquire_connection(state.clone(), "user-b").unwrap();
        assert!(acquire_connection(state.clone(), "user-c").is_none());
        drop(first);
        let third = acquire_connection(state.clone(), "user-c").unwrap();
        drop(second);
        drop(third);
        assert!(state.relay_connections.lock().unwrap().is_empty());
        assert_eq!(state.relay_connection_slots.available_permits(), 2);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn blocked_relay_write_keeps_session_revocation_live() {
        let state = Arc::new(test_state().await);
        let (user, _) = seed_session(&state).await;
        let target = RelayTarget {
            user_id: user.user_id.clone(),
            device_id: user.device_id.clone(),
            session_id: user.session_id.clone(),
            ip: "10.0.0.1".parse().unwrap(),
            port: 22,
            connection_id: None,
        };
        let task_state = state.clone();
        let task_target = target.clone();
        let pending_write = tokio::spawn(async move {
            let (mut writer, _reader) = tokio::io::duplex(1);
            let payload = vec![0x5a; 4096];
            let mut checks = tokio::time::interval(Duration::from_millis(10));
            checks.tick().await;
            relay_io_with_guards(
                writer.write_all(&payload),
                &task_state,
                &task_target,
                Instant::now() + Duration::from_secs(30),
                &mut checks,
            )
            .await
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), pending_write)
            .await
            .expect("blocked write did not observe session revocation")
            .unwrap();
        assert!(matches!(result, Err(RelayIoAbort::SessionInactive)));
        close_state(&state).await;
    }

    #[tokio::test]
    async fn maintenance_prunes_old_relay_ticket_rows() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let now = Utc::now().timestamp();
        for (hash, age) in [("old-ticket", 120_i64), ("recent-ticket", 20_i64)] {
            sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,created_at) VALUES(?,?,?,?,?,?,?)")
                .bind(hash)
                .bind(&user.user_id)
                .bind(&user.device_id)
                .bind("10.2.3.4")
                .bind(22_i64)
                .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
                .bind(now - age)
                .execute(&state.db)
                .await
                .unwrap();
        }
        let mut tx = state.db.begin().await.unwrap();
        prune_tickets_tx(&mut tx, now - TICKET_RATE_WINDOW_SECONDS)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let remaining: Vec<String> =
            sqlx::query_scalar("SELECT ticket_hash FROM relay_tickets ORDER BY ticket_hash")
                .fetch_all(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining, ["recent-ticket"]);
        close_state(&state).await;
    }

    fn ticket_request(user: &AuthUser, host: &str, port: u16) -> TicketRequest {
        TicketRequest {
            device_id: user.device_id.clone(),
            target_host: host.to_owned(),
            target_port: port,
        }
    }

    #[tokio::test]
    async fn tickets_reach_arbitrary_private_targets_without_any_relay_policy() {
        // The test config enables Relay with a public origin and nothing else:
        // no allowlist, no stored policy.
        let state = test_state().await;
        assert!(relay_available(&state));
        let (user, access) = seed_session(&state).await;
        let slots = Arc::new(Semaphore::new(1));

        let Json(body) = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            ticket_request(&user, "10.20.30.40", 2222),
            &no_dns(),
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        let target = consume_ticket(&state, body["ticket"].as_str().unwrap())
            .await
            .unwrap()
            .expect("private IP literal ticket must be redeemable");
        assert_eq!(target.ip, "10.20.30.40".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 2222);
        assert!(relay_connection_active(&state, &target).await);
        assert!(
            record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        let resolver = FakeRelayResolver::new(
            "ssh.internal.example",
            FakeResolveResult::Answers(vec!["192.168.1.5".parse().unwrap()]),
        );
        let Json(body) = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            ticket_request(&user, "SSH.Internal.Example", 22),
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        let target = consume_ticket(&state, body["ticket"].as_str().unwrap())
            .await
            .unwrap()
            .expect("DNS ticket must be redeemable");
        assert_eq!(target.ip, "192.168.1.5".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);
        assert!(relay_connection_active(&state, &target).await);

        let session_revoked = RelayTarget {
            session_id: Uuid::new_v4().to_string(),
            ..target.clone()
        };
        assert!(!relay_connection_active(&state, &session_revoked).await);
        let forbidden = RelayTarget {
            ip: "127.0.0.1".parse().unwrap(),
            ..target
        };
        assert!(!relay_connection_active(&state, &forbidden).await);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn forbidden_targets_are_denied_before_any_ticket_is_written() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let slots = Arc::new(Semaphore::new(1));
        for host in FORBIDDEN_TARGETS {
            let error = create_ticket_with_resolver(
                &state,
                &auth_headers(&access),
                ticket_request(&user, host, 22),
                &no_dns(),
                &slots,
                Duration::from_secs(1),
            )
            .await
            .unwrap_err();
            assert_eq!(error.status, StatusCode::FORBIDDEN, "{host}");
            assert_eq!(error.body.code, "TARGET_DENIED", "{host}");
            assert_eq!(error.body.message, "target address is not allowed");
        }

        let loopback_name = FakeRelayResolver::new(
            "localhost.example",
            FakeResolveResult::Answers(vec!["127.0.0.1".parse().unwrap(), "::1".parse().unwrap()]),
        );
        let error = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            ticket_request(&user, "localhost.example", 22),
            &loopback_name,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(error.body.code, "TARGET_DENIED");

        let zero_port = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            ticket_request(&user, "10.20.30.40", 0),
            &no_dns(),
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(zero_port.status, StatusCode::BAD_REQUEST);
        assert_eq!(zero_port.body.code, "INVALID_TARGET");

        // The ticket writer refuses the floor on its own as well.
        for (ip, port) in [
            ("127.0.0.1", 22),
            ("::ffff:127.0.0.1", 22),
            ("10.20.30.40", 0),
        ] {
            let error = issue_ticket(
                &state,
                &user.user_id,
                &user.device_id,
                &user.session_id,
                &user.access_hash,
                ip.parse().unwrap(),
                port,
            )
            .await
            .unwrap_err();
            assert_eq!(error.body.code, "TARGET_DENIED", "{ip}:{port}");
        }
        let tickets: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_tickets")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(tickets, 0);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_availability_needs_only_the_enable_flag_and_a_public_origin() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        assert_eq!(
            admin_overview_json(&state),
            json!({"enabled": true, "max_connections_per_user": 1})
        );
        let variants: [fn(&mut Config); 3] = [
            |config| config.relay_enabled = false,
            |config| config.public_origin = None,
            |config| config.public_origin = Some("  ".to_owned()),
        ];
        for disable in variants {
            let mut config = (*state.config).clone();
            disable(&mut config);
            let mut disabled = state.clone();
            disabled.config = Arc::new(config);
            assert!(!relay_available(&disabled));
            assert_eq!(admin_overview_json(&disabled)["enabled"], false);
            let error = create_ticket_with_resolver(
                &disabled,
                &auth_headers(&access),
                ticket_request(&user, "10.20.30.40", 22),
                &no_dns(),
                &Arc::new(Semaphore::new(1)),
                Duration::from_secs(1),
            )
            .await
            .unwrap_err();
            assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(error.body.code, "RELAY_DISABLED");
        }
        close_state(&state).await;
    }

    #[tokio::test]
    async fn retired_relay_policy_and_group_admin_routes_no_longer_exist() {
        use axum::{body::Body, http::Request};
        use http_body_util::BodyExt;
        use tower::ServiceExt;

        let data_dir =
            std::env::temp_dir().join(format!("atermius-relay-routes-{}", Uuid::new_v4()));
        create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let mut config = test_config(data_dir);
        config.admin_usernames = vec!["relay-admin@example.test".to_owned()];
        let state = open_state(&database, config).await.unwrap();
        let (user, access) = seed_session(&state).await;
        sqlx::query("UPDATE users SET username='relay-admin@example.test' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        let app = crate::router(state.clone()).await;
        let group = "123e4567-e89b-12d3-a456-426614174000";
        let user_path = format!("/api/v1/admin/relay-policy/users/{}", user.user_id);
        let group_path = format!("/api/v1/admin/relay-groups/{group}");
        let members_path = format!("{group_path}/members");
        let group_policy_path = format!("{group_path}/relay-policy");
        let policy_body = r#"{"expected_revision":0,"enabled":true,"allow_cidrs":["10.0.0.0/8"],"allow_ports":[22]}"#;
        for (method, path, body) in [
            ("GET", "/api/v1/admin/relay-policy", ""),
            ("PUT", "/api/v1/admin/relay-policy", policy_body),
            ("GET", user_path.as_str(), ""),
            ("PUT", user_path.as_str(), policy_body),
            ("DELETE", user_path.as_str(), r#"{"expected_revision":0}"#),
            ("GET", "/api/v1/admin/relay-groups", ""),
            ("POST", "/api/v1/admin/relay-groups", r#"{"name":"Ops"}"#),
            ("GET", group_path.as_str(), ""),
            (
                "PUT",
                group_path.as_str(),
                r#"{"expected_revision":1,"name":"Ops"}"#,
            ),
            ("DELETE", group_path.as_str(), r#"{"expected_revision":1}"#),
            (
                "PUT",
                members_path.as_str(),
                r#"{"expected_revision":0,"user_ids":[]}"#,
            ),
            ("GET", group_policy_path.as_str(), ""),
            ("PUT", group_policy_path.as_str(), policy_body),
            (
                "DELETE",
                group_policy_path.as_str(),
                r#"{"expected_revision":0}"#,
            ),
        ] {
            let mut request = Request::builder().method(method).uri(path).header(
                axum::http::header::AUTHORIZATION,
                format!("Bearer {access}"),
            );
            if !body.is_empty() {
                request = request.header(axum::http::header::CONTENT_TYPE, "application/json");
            }
            let response = app
                .clone()
                .oneshot(request.body(Body::from(body)).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{method} {path}");
            let body: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(body["error"]["code"], "NOT_FOUND", "{method} {path}");
        }
        for table in [
            "instance_relay_policy",
            "user_relay_policies",
            "relay_access_groups",
            "relay_access_group_members",
        ] {
            let rows: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table}"))
                .fetch_one(&state.db)
                .await
                .unwrap();
            assert_eq!(rows, 0, "{table} must not be written");
        }
        close_state(&state).await;
    }
}
