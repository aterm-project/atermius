use std::net::{IpAddr, SocketAddr};

use axum::{
    Json,
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, header::USER_AGENT},
};
use chrono::Utc;
use ipnet::IpNet;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{ApiError, AppState, audit::AuditSource, auth::AuthUser};

const PREVIOUS_IP_LIMIT: i64 = 10;

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Platform {
    Web,
    Windows,
    Macos,
    Ios,
    Android,
    Linux,
}

impl Platform {
    fn as_str(self) -> &'static str {
        match self {
            Self::Web => "web",
            Self::Windows => "windows",
            Self::Macos => "macos",
            Self::Ios => "ios",
            Self::Android => "android",
            Self::Linux => "linux",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ActivityRequest {
    platform: Platform,
    device_name: Option<String>,
}

pub(crate) fn trusted_proxies_from_env() -> Vec<IpNet> {
    let Ok(value) = std::env::var("ATERMIUS_DEVICE_TRUSTED_PROXIES") else {
        return Vec::new();
    };
    if value.trim().is_empty() {
        return Vec::new();
    }
    match value.split(',').map(|entry| entry.trim().parse()).collect() {
        Ok(networks) => networks,
        Err(_) => {
            tracing::warn!("Ignoring invalid ATERMIUS_DEVICE_TRUSTED_PROXIES CIDRs");
            Vec::new()
        }
    }
}

fn browser_ip(peer: IpAddr, headers: &HeaderMap, trusted_proxies: &[IpNet]) -> IpAddr {
    let peer = peer.to_canonical();
    let is_trusted = |ip: &IpAddr| trusted_proxies.iter().any(|network| network.contains(ip));
    if !is_trusted(&peer) {
        return peer;
    }
    // Walk from the trusted socket peer toward the client. Once a hop is
    // untrusted, any addresses farther left could have been supplied by it.
    let mut current = peer;
    for value in headers.get_all("x-forwarded-for").iter().rev() {
        let Ok(value) = value.to_str() else {
            return peer;
        };
        for hop in value.rsplit(',') {
            let Ok(ip) = hop.trim().parse::<IpAddr>() else {
                return peer;
            };
            current = ip.to_canonical();
            if !is_trusted(&current) {
                return current;
            }
        }
    }
    current
}

pub(crate) async fn report(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<ActivityRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    let platform = request.platform.as_str();
    let (name, agent, ip) = if matches!(request.platform, Platform::Web) {
        let agent = headers
            .get(USER_AGENT)
            .and_then(|value| value.to_str().ok())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.chars().take(1024).collect::<String>());
        let ip = browser_ip(peer.ip(), &headers, &state.device_trusted_proxies);
        (None, agent, Some(ip.to_string()))
    } else {
        let name = request.device_name.as_deref().map(str::trim);
        if name.is_some_and(|name| name.chars().count() > 120 || name.chars().any(char::is_control))
        {
            return Err(ApiError::bad_request(
                "INVALID_DEVICE_NAME",
                "invalid reported device name",
            ));
        }
        (name.filter(|name| !name.is_empty()), None, None)
    };

    if let Some(pool) = state.pg_sync_pool.as_ref() {
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(
            &mut tx, &user,
        )
        .await?;
        let ips: Vec<&str> = ip.as_deref().into_iter().collect();
        sqlx::query(
            "INSERT INTO device_activity(device_id,platform,device_name,user_agent,browser_ips) \
             VALUES($1,$2,$3,$4,$5) ON CONFLICT(device_id) DO UPDATE SET \
                 platform=EXCLUDED.platform,device_name=EXCLUDED.device_name,user_agent=EXCLUDED.user_agent, \
                 browser_ips=CASE WHEN EXCLUDED.platform='web' THEN \
                     (EXCLUDED.browser_ips || array_remove(device_activity.browser_ips,EXCLUDED.browser_ips[1]))[1:$6] \
                     ELSE EXCLUDED.browser_ips END \
             WHERE (device_activity.platform,device_activity.device_name,device_activity.user_agent,device_activity.browser_ips[1]) \
                 IS DISTINCT FROM (EXCLUDED.platform,EXCLUDED.device_name,EXCLUDED.user_agent,EXCLUDED.browser_ips[1])",
        )
        .bind(&user.device_id).bind(platform).bind(name).bind(agent.as_deref()).bind(&ips)
        .bind((PREVIOUS_IP_LIMIT + 1) as i32)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
    } else {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        crate::require_active_session_device_tx(&mut tx, &user).await?;
        sqlx::query(
            "INSERT INTO device_activity(device_id,platform,device_name,user_agent,browser_ips) \
             VALUES(?1,?2,?3,?4,CASE WHEN ?5 IS NULL THEN '[]' ELSE json_array(?5) END) \
             ON CONFLICT(device_id) DO UPDATE SET \
                 platform=excluded.platform,device_name=excluded.device_name,user_agent=excluded.user_agent, \
                 browser_ips=CASE WHEN ?5 IS NULL THEN '[]' ELSE ( \
                     SELECT json_group_array(ip) FROM ( \
                         SELECT ?5 AS ip, -1 AS position \
                         UNION ALL SELECT value, key FROM json_each(device_activity.browser_ips) WHERE value<>?5 \
                         ORDER BY position LIMIT ?6 \
                     ) \
                 ) END \
             WHERE device_activity.platform IS NOT excluded.platform \
                 OR device_activity.device_name IS NOT excluded.device_name \
                 OR device_activity.user_agent IS NOT excluded.user_agent \
                 OR json_extract(device_activity.browser_ips,'$[0]') IS NOT ?5",
        )
        .bind(&user.device_id).bind(platform).bind(name).bind(agent.as_deref()).bind(ip.as_deref())
        .bind(PREVIOUS_IP_LIMIT + 1)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
    }
    Ok(Json(json!({"status": "recorded"})))
}

pub(crate) fn activity_value(
    platform: Option<String>,
    device_name: Option<String>,
    user_agent: Option<String>,
    ips: &[String],
) -> Value {
    match platform.as_deref() {
        Some("web") => {
            let (last_ip, history) = ips
                .split_first()
                .map_or((None, &[][..]), |(ip, rest)| (Some(ip), rest));
            json!({"platform": platform, "user_agent": user_agent, "last_ip": last_ip, "ip_history": history})
        }
        Some(_) => json!({"platform": platform, "device_name": device_name}),
        None => Value::Null,
    }
}

pub(crate) async fn sign_out(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    if user.device_id == device_id {
        return Err(ApiError::bad_request(
            "CURRENT_DEVICE",
            "use logout on the current device",
        ));
    }
    let changed = if let Some(repository) = state.pg_account_onboarding.as_ref() {
        repository.sign_out_device(&user, &device_id).await?
    } else {
        sign_out_sqlite(&state, &user, &device_id).await?
    };
    Ok(Json(
        json!({"device_id": device_id, "signed_out_sessions": changed}),
    ))
}

async fn sign_out_sqlite(
    state: &AppState,
    user: &AuthUser,
    device_id: &str,
) -> Result<u64, ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, user).await?;
    let owned: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE user_id=? AND device_id=?)")
            .bind(&user.user_id)
            .bind(device_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if !owned {
        return Err(ApiError::not_found());
    }
    let now = Utc::now();
    let changed = sqlx::query(
        "UPDATE sessions SET revoked_at=? WHERE user_id=? AND device_id=? \
         AND revoked_at IS NULL AND julianday(refresh_expires_at)>julianday(?)",
    )
    .bind(now.to_rfc3339())
    .bind(&user.user_id)
    .bind(device_id)
    .bind(now.to_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    if changed > 0 {
        sqlx::query("DELETE FROM notification_push_endpoints WHERE user_id=? AND device_id=?")
            .bind(&user.user_id)
            .bind(device_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::audit::record_account_event_tx(
            &mut tx,
            state,
            &user.user_id,
            Some(&user.device_id),
            "device.sessions_signed_out",
            "device",
            Some(device_id),
            AuditSource::Api,
            now.timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(changed)
}
