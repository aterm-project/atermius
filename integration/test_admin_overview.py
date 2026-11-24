"""Black-box checks for the opt-in, aggregate-only instance admin overview."""

from __future__ import annotations

from datetime import datetime
import uuid

import pytest

from test_account_deletion import _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def test_admin_overview_requires_allowlisted_active_account_and_returns_aggregates(
    api, account, tmp_path
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin overview acceptance needs the suite-owned disposable server")

    member = _register_account(
        api,
        f"instance-admin-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "instance-admin-outsider",
    )

    missing = api.request("GET", "/api/v1/admin/overview")
    assert missing.status == 401

    admin_profile = api.request("GET", "/api/v1/me", token=account["access_token"])
    member_profile = api.request("GET", "/api/v1/me", token=member["access_token"])
    assert admin_profile.status == member_profile.status == 200
    assert admin_profile.json()["policy"]["instance_admin"] is True
    assert member_profile.json()["policy"]["instance_admin"] is False

    denied = api.request(
        "GET", "/api/v1/admin/overview", token=member["access_token"]
    )
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"

    response = api.request(
        "GET", "/api/v1/admin/overview", token=account["access_token"]
    )
    assert response.status == 200
    body = response.json()
    assert set(body) == {
        "instance",
        "counts",
        "relay",
        "database_encryption",
        "generated_at",
    }
    # Main SQLite database encryption at rest (ATERMIUS_DATABASE_KEY_FILE).
    expected_encryption = (
        "enabled" if api.admin_env.get("ATERMIUS_DATABASE_KEY_FILE") else "disabled"
    )
    assert body["database_encryption"] == expected_encryption
    assert set(body["instance"]) == {
        "instance_id",
        "server_space_id",
        "generation",
        "protocol_version",
    }
    assert body["instance"]["protocol_version"] == 1
    assert set(body["counts"]) == {
        "accounts_total",
        "accounts_active",
        "accounts_deleting",
        "accounts_disabled",
        "devices_active",
        "vaults_active",
        "vaults_deleting",
        "stored_bytes",
        "reserved_upload_bytes",
        "vault_quota_bytes",
    }
    assert body["counts"]["accounts_total"] >= 2
    assert body["counts"]["accounts_active"] >= 2
    assert body["counts"]["devices_active"] >= 2
    assert body["counts"]["vaults_active"] >= 2
    assert all(type(value) is int and value >= 0 for value in body["counts"].values())
    # Relay has no destination policy any more: availability is the
    # deployment gate plus a configured public Origin.
    assert set(body["relay"]) == {"enabled", "max_connections_per_user"}
    expected_relay = api.admin_env.get("ATERMIUS_RELAY_ENABLED") == "true" and bool(
        api.admin_env.get("ATERMIUS_PUBLIC_ORIGIN")
    )
    assert body["relay"]["enabled"] is expected_relay
    assert type(body["relay"]["max_connections_per_user"]) is int
    assert body["relay"]["max_connections_per_user"] > 0
    assert datetime.fromisoformat(body["generated_at"].replace("Z", "+00:00"))

    # The overview must not become a shortcut to user identity or Vault content.
    serialized = str(body).lower()
    assert "username" not in serialized
    assert "vault_name" not in serialized
    assert "access_token" not in serialized
    assert "envelope" not in serialized


def test_retired_relay_policy_and_group_admin_routes_are_unknown(api, account):
    """The Relay policy/group admin APIs were removed; even an admin gets a JSON 404."""
    group_id = str(uuid.uuid4())
    user_id = str(uuid.uuid4())
    for method, path in (
        ("GET", "/api/v1/admin/relay-policy"),
        ("PUT", "/api/v1/admin/relay-policy"),
        ("GET", f"/api/v1/admin/relay-policy/users/{user_id}"),
        ("PUT", f"/api/v1/admin/relay-policy/users/{user_id}"),
        ("DELETE", f"/api/v1/admin/relay-policy/users/{user_id}"),
        ("GET", "/api/v1/admin/relay-groups"),
        ("POST", "/api/v1/admin/relay-groups"),
        ("GET", f"/api/v1/admin/relay-groups/{group_id}"),
        ("PUT", f"/api/v1/admin/relay-groups/{group_id}"),
        ("DELETE", f"/api/v1/admin/relay-groups/{group_id}"),
        ("PUT", f"/api/v1/admin/relay-groups/{group_id}/members"),
        ("GET", f"/api/v1/admin/relay-groups/{group_id}/relay-policy"),
        ("PUT", f"/api/v1/admin/relay-groups/{group_id}/relay-policy"),
        ("DELETE", f"/api/v1/admin/relay-groups/{group_id}/relay-policy"),
    ):
        response = api.request(method, path, token=account["access_token"])
        assert response.status == 404, f"{method} {path} returned HTTP {response.status}"
        assert _error_code(response) == "NOT_FOUND", f"{method} {path}"
