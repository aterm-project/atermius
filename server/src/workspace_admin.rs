//! Instance-admin facade for the optional local Workspace Hub.
use crate::{ApiError, AppState, admin, audit, auth};
use atermius_workspace_admin::{self as ipc, Command, Reply};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Extension, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode},
    routing::get,
};
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};

#[derive(Clone)]
struct HubSocket(Option<PathBuf>);
const PATH: &str = "/api/v1/admin/workspace-agents";
pub(crate) fn routes() -> Router<AppState> {
    let socket = std::env::var_os("ATERMIUS_WORKSPACE_ADMIN_SOCKET")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from);
    Router::new()
        .route(PATH, get(status).post(change))
        .layer(DefaultBodyLimit::max(ipc::MAX_COMMAND))
        .layer(Extension(HubSocket(socket)))
}
fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "WORKSPACE_HUB_UNAVAILABLE",
        "Workspace Hub is unavailable. Refresh its status before retrying.",
    )
}
fn invalid() -> ApiError {
    ApiError::bad_request(
        "INVALID_WORKSPACE_ACTION",
        "Invalid node, workspace or operation parameters.",
    )
}
impl HubSocket {
    async fn call(&self, command: Option<Command>) -> Result<Reply, ApiError> {
        let path = self.0.as_ref().ok_or_else(unavailable)?;
        if !path.is_absolute() {
            return Err(unavailable());
        }
        #[cfg(unix)]
        {
            let exchange = async {
                let mut sock = tokio::net::UnixStream::connect(path)
                    .await
                    .map_err(|_| unavailable())?;
                ipc::send(
                    &mut sock,
                    &ipc::Request {
                        version: ipc::PROTOCOL,
                        command,
                    },
                    ipc::MAX_COMMAND,
                )
                .await
                .map_err(|_| unavailable())?;
                ipc::receive(&mut sock, ipc::MAX_REPLY)
                    .await
                    .map_err(|_| unavailable())
            };
            tokio::time::timeout(Duration::from_secs(4), exchange)
                .await
                .map_err(|_| unavailable())?
        }
        #[cfg(not(unix))]
        {
            let _ = command;
            Err(unavailable())
        }
    }
}
struct Resource {
    kind: &'static str,
    id: String,
    verb: &'static str,
}

/// Commit the intent to the instance audit before a request leaves the API
/// process. Keep database locks out of the socket round trip.
async fn check_admin(
    state: &AppState,
    user: &auth::AuthUser,
    resources: &[Resource],
    outcome: &str,
) -> Result<(), ApiError> {
    if let Some(pool) = &state.pg_sync_pool {
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            state,
            user,
            &state.config.admin_usernames,
        )
        .await?;
        for r in resources {
            audit::record_instance_admin_event_pg_tx(
                &mut tx,
                state,
                user,
                &format!("admin.workspace_{}_{}", r.verb, outcome),
                r.kind,
                Some(&r.id),
            )
            .await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
    } else {
        let mut tx = if resources.is_empty() {
            state.db.begin().await
        } else {
            state.db.begin_with("BEGIN IMMEDIATE").await
        }
        .map_err(ApiError::internal)?;
        if resources.is_empty() {
            admin::require_instance_admin_read_tx(&mut tx, state, user).await?;
        } else {
            admin::require_instance_admin_write_tx(&mut tx, state, user).await?;
            for r in resources {
                audit::record_instance_admin_event_tx(
                    &mut tx,
                    state,
                    &user.user_id,
                    &user.device_id,
                    &format!("admin.workspace_{}_{}", r.verb, outcome),
                    r.kind,
                    Some(&r.id),
                    chrono::Utc::now().timestamp(),
                )
                .await?;
            }
        }
        tx.commit().await.map_err(ApiError::internal)?;
    }
    Ok(())
}
async fn status(
    State(state): State<AppState>,
    Extension(hub): Extension<HubSocket>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    check_admin(&state, &user, &[], "").await?;
    if hub.0.is_none() {
        return Ok(Json(
            json!({"configured":false,"ssh_host":null,"nodes":[],"clusters":[]}),
        ));
    }
    match hub.call(None).await? {
        Reply::Status { overview, ssh_host } => Ok(Json(
            json!({"configured":true,"ssh_host":ssh_host,"nodes":overview.nodes,"clusters":overview.clusters}),
        )),
        _ => Err(unavailable()),
    }
}
async fn change(
    State(state): State<AppState>,
    Extension(hub): Extension<HubSocket>,
    headers: HeaderMap,
    body: Result<Json<Command>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    check_admin(&state, &user, &[], "").await?;
    let Json(command) = body.map_err(|e| {
        if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
            ApiError::too_large("Workspace action too large.")
        } else {
            invalid()
        }
    })?;
    command.validate().map_err(|_| invalid())?;
    if hub.0.is_none() {
        return Err(unavailable());
    }
    let (kind, id, verb) = command.resource();
    let mut resources = vec![Resource {
        kind,
        id: id.to_owned(),
        verb,
    }];
    if let Command::RegisterNode { registration } = &command
        && let Some(initial) = &registration.initial_workspace
    {
        resources.push(Resource {
            kind: "workspace_cluster",
            id: initial.cluster.clone(),
            verb: "create",
        });
    }
    check_admin(&state, &user, &resources, "requested").await?;
    let response = hub.call(Some(command)).await;
    let (outcome, result) = match response {
        Ok(Reply::Accepted) => ("accepted", Ok(Json(json!({"accepted":true})))),
        Ok(Reply::Invalid) => ("rejected", Err(invalid())),
        Ok(Reply::Conflict) => (
            "rejected",
            Err(ApiError::conflict(
                "WORKSPACE_CONFLICT",
                "The workspace state or registration conflicts. Refresh and try again.",
            )),
        ),
        _ => ("unconfirmed", Err(unavailable())),
    };
    check_admin(&state, &user, &resources, outcome).await?;
    result
}
