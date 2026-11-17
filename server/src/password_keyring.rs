
//! Password login key material is independent of optional disaster recovery.
//! Only authenticated sessions (including MFA where configured) can read it.
use axum::{Json, extract::State, http::HeaderMap};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::Row;
use crate::{ApiError, AppState};

pub(crate) fn validate_wrap(value: &Value) -> Result<(), ApiError> {
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    let valid = value.get("version").and_then(Value::as_u64) == Some(1)
        && [("nonce",24),("ciphertext",48)].iter().all(|(field,len)| {
            value.get(*field).and_then(Value::as_str)
                .and_then(|s| URL_SAFE_NO_PAD.decode(s).ok())
                .is_some_and(|bytes| bytes.len() == *len)
        });
    if !valid { return Err(ApiError::bad_request("INVALID_KEY_WRAP", "invalid account vault key wrap")); }
    Ok(())
}

#[derive(Deserialize)]
pub struct KeyringRequest {
    pub keys: Vec<Key>,
}
#[derive(Deserialize)]
pub struct Key {
    pub vault_id: String,
    pub key_epoch: i64,
    pub envelope: Value,
    pub membership_version: Option<i64>,
    pub recipient_device_id: Option<String>,
    pub signature: Option<String>,
}
enum Action { Read, Upload(Vec<Key>), Install(Vec<Key>) }

pub async fn get(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    operate(&state, &headers, Action::Read).await.map(Json)
}
pub async fn put(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<KeyringRequest>) -> Result<Json<Value>, ApiError> {
    operate(&state, &headers, Action::Upload(body.keys)).await.map(Json)
}
pub async fn install(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<KeyringRequest>) -> Result<Json<Value>, ApiError> {
    operate(&state, &headers, Action::Install(body.keys)).await.map(Json)
}
fn query(sql: &str, pg: bool) -> String {
    if !pg { return sql.to_owned(); }
    let mut i = 0;
    sql.chars().map(|c| if c == '?' { i+=1; format!("${}",i) } else { c.to_string() }).collect()
}

async fn operate(state: &AppState, headers: &HeaderMap, action: Action) -> Result<Value, ApiError> {
    let user = crate::auth::authenticate(state, headers).await?;
    // Instantiate exactly the same checks for both storage backends.
    macro_rules! run {
        ($tx:ident, $required:ident, $pg:expr) => {{
            let mut result = Vec::new();
            match &action {
                Action::Read => {
                    for context in &$required {
                        let row = sqlx::query(&query("SELECT envelope FROM account_vault_key_wraps WHERE user_id=? AND vault_id=? AND key_epoch=?", $pg))
                            .bind(&user.user_id).bind(&context.vault_id).bind(context.key_epoch)
                            .fetch_optional(&mut *$tx).await.map_err(ApiError::internal)?;
                        let installed: i64 = sqlx::query_scalar(&query("SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_user_id=? AND recipient_device_id=? AND vault_id=? AND epoch=?", $pg))
                            .bind(&user.user_id).bind(&user.device_id).bind(&context.vault_id).bind(context.key_epoch)
                            .fetch_one(&mut *$tx).await.map_err(ApiError::internal)?;
                        let envelope = row.map(|r| -> Result<Value, ApiError> {
                            let text: String = r.try_get("envelope").map_err(ApiError::internal)?;
                            serde_json::from_str(&text).map_err(ApiError::internal)
                        }).transpose()?;
                        result.push(json!({"vault_id":context.vault_id,"key_epoch":context.key_epoch,
                            "membership_version":context.membership_version,"envelope":envelope,"installed":installed>0}));
                    }
                }
                Action::Upload(keys) | Action::Install(keys) => {
                    if keys.len() > 1000 { return Err(ApiError::bad_request("INVALID_KEY_WRAP", "too many keys")); }
                    let signer: String = sqlx::query_scalar(&query("SELECT signing_public_key FROM devices WHERE device_id=?", $pg))
                        .bind(&user.device_id).fetch_one(&mut *$tx).await.map_err(ApiError::internal)?;
                    let mut seen = std::collections::BTreeSet::new();
                    for key in keys {
                        let context = $required.iter().find(|c| c.vault_id == key.vault_id && c.key_epoch == key.key_epoch)
                            .ok_or_else(|| ApiError::forbidden("INVALID_KEY_CONTEXT", "vault key context is unavailable"))?;
                        if !seen.insert((&key.vault_id,key.key_epoch)) || key.envelope.to_string().len()>65536 {
                            return Err(ApiError::bad_request("INVALID_KEY_WRAP", "duplicate or oversized key"));
                        }
                        if matches!(&action, Action::Upload(_)) {
                            validate_wrap(&key.envelope)?;
                            let source: i64 = sqlx::query_scalar(&query("SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_user_id=? AND recipient_device_id=? AND vault_id=? AND epoch=?", $pg))
                                .bind(&user.user_id).bind(&user.device_id).bind(&key.vault_id).bind(key.key_epoch)
                                .fetch_one(&mut *$tx).await.map_err(ApiError::internal)?;
                            if source != 1 { return Err(ApiError::forbidden("INVALID_KEY_CONTEXT", "device has no source key")); }
                            sqlx::query(&query("INSERT INTO account_vault_key_wraps(user_id,vault_id,key_epoch,envelope) VALUES(?,?,?,?) ON CONFLICT(user_id,vault_id,key_epoch) DO UPDATE SET envelope=excluded.envelope", $pg))
                                .bind(&user.user_id).bind(&key.vault_id).bind(key.key_epoch).bind(key.envelope.to_string())
                                .execute(&mut *$tx).await.map_err(ApiError::internal)?;
                        } else {
                            if key.membership_version != Some(context.membership_version) || key.recipient_device_id.as_deref()!=Some(user.device_id.as_str()) {
                                return Err(ApiError::bad_request("INVALID_KEY_CONTEXT", "key context mismatch"));
                            }
                            let signature = key.signature.as_deref().ok_or_else(|| ApiError::bad_request("INVALID_SIGNATURE", "missing signature"))?;
                            crate::auth::verify_key_signature(&signer, signature, &crate::jcs(&json!({
                                "vault_id":key.vault_id,"key_epoch":key.key_epoch,"membership_version":context.membership_version,
                                "recipient_device_id":user.device_id,"envelope":key.envelope
                            }))?)?;
                            let sql = if $pg {
                                "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?::jsonb,?,?,?) ON CONFLICT DO NOTHING"
                            } else {
                                "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"
                            };
                            sqlx::query(&query(sql,$pg)).bind(&key.vault_id).bind(key.key_epoch).bind(&user.user_id).bind(&user.device_id)
                                .bind(key.envelope.to_string()).bind(signature).bind(&user.device_id).bind(context.membership_version)
                                .execute(&mut *$tx).await.map_err(ApiError::internal)?;
                        }
                    }
                }
            }
            $tx.commit().await.map_err(ApiError::internal)?;
            Ok(json!({"keys":result}))
        }}
    }
    if let Some(pool) = &state.pg_sync_pool {
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_account_recovery::lock_active_principal(&mut tx, &user).await?;
        crate::pg_account_recovery::lock_user_vaults_and_memberships(&mut tx, &user.user_id).await?;
        let required = crate::pg_recovery_context::required_contexts(&mut tx, &user.user_id).await?;
        run!(tx, required, true)
    } else {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        sqlx::query("UPDATE users SET status=status WHERE user_id=?").bind(&user.user_id)
            .execute(&mut *tx).await.map_err(ApiError::internal)?;
        crate::require_active_session_device_tx(&mut tx, &user).await?;
        let required = crate::recovery::required_contexts(&mut *tx, &user.user_id).await?;
        run!(tx, required, false)
    }
}
