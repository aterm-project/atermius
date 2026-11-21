use sqlx::sqlite::SqlitePoolOptions;

#[tokio::test]
async fn migration_0058_creates_a_checked_singleton_sync_policy_without_freezing_the_default() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply all schema migrations");

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_sync_policy")
        .fetch_one(&pool)
        .await
        .expect("count policy rows");
    assert_eq!(
        rows, 0,
        "revision zero is derived from the current environment"
    );

    for invalid in [
        "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) VALUES(2,20,1,'now')",
        "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) VALUES(1,1,1,'now')",
        "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) VALUES(1,1001,1,'now')",
        "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) VALUES(1,20,0,'now')",
    ] {
        assert!(sqlx::query(invalid).execute(&pool).await.is_err());
    }
    for limit in [2_i64, 1000] {
        sqlx::query("DELETE FROM instance_sync_policy")
            .execute(&pool)
            .await
            .expect("clear policy");
        sqlx::query(
            "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
             VALUES(1,?,1,'2026-01-01T00:00:00Z')",
        )
        .bind(limit)
        .execute(&pool)
        .await
        .expect("insert boundary policy");
    }
    assert!(
        sqlx::query("UPDATE instance_sync_policy SET revision=0 WHERE policy_id=1")
            .execute(&pool)
            .await
            .is_err()
    );
    assert!(
        sqlx::query(
            "INSERT INTO instance_sync_policy(policy_id,record_history_limit,revision,updated_at) \
             VALUES(1,20,2,'now')"
        )
        .execute(&pool)
        .await
        .is_err(),
        "the policy is a singleton"
    );
}
