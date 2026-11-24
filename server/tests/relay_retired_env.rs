//! Deployments set the Relay allowlist variables before the Relay policy was
//! removed. The server must still start with them, ignore them, and say so.

use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::PermissionsExt,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

fn http_get(port: u16, path: &str) -> Option<(u16, String)> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    let status = response.split_whitespace().nth(1)?.parse().ok()?;
    let body = response.split_once("\r\n\r\n")?.1.to_owned();
    Some((status, body))
}

fn stop(mut child: Child) -> String {
    let _ = child.kill();
    let _ = child.wait();
    let mut output = String::new();
    for stream in [
        child.stdout.take().map(|s| Box::new(s) as Box<dyn Read>),
        child.stderr.take().map(|s| Box::new(s) as Box<dyn Read>),
    ]
    .into_iter()
    .flatten()
    {
        for line in BufReader::new(stream).lines().map_while(Result::ok) {
            output.push_str(&line);
            output.push('\n');
        }
    }
    output
}

#[test]
fn server_starts_ignoring_and_warning_about_retired_relay_allowlists() {
    let data_dir = std::env::temp_dir().join(format!(
        "atermius-retired-relay-env-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&data_dir).unwrap();
    std::fs::set_permissions(&data_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();

    // Malformed values used to fail closed and disable Relay; now they are
    // reported once and otherwise have no effect.
    let child = Command::new(env!("CARGO_BIN_EXE_atermius-server"))
        .arg("serve")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("ATERMIUS_DATA_DIR", &data_dir)
        .env("ATERMIUS_BIND", format!("127.0.0.1:{port}"))
        .env("ATERMIUS_PUBLIC_ORIGIN", format!("http://127.0.0.1:{port}"))
        .env("ATERMIUS_RELAY_ENABLED", "true")
        .env("ATERMIUS_RELAY_ALLOW_CIDRS", "10.0.0.0/8,not-a-cidr")
        .env("ATERMIUS_RELAY_ALLOW_PORTS", "22,0")
        .env("RUST_LOG", "warn")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start atermius-server");

    let deadline = Instant::now() + Duration::from_secs(60);
    let mut child = Some(child);
    let instance = loop {
        if let Some(status) = child.as_mut().unwrap().try_wait().unwrap() {
            let output = stop(child.take().unwrap());
            let _ = std::fs::remove_dir_all(&data_dir);
            panic!("server exited with {status} while retired variables were set:\n{output}");
        }
        if http_get(port, "/health/ready").is_some_and(|(status, _)| status == 200) {
            break http_get(port, "/api/v1/instance").expect("read instance metadata");
        }
        assert!(Instant::now() < deadline, "server did not become ready");
        std::thread::sleep(Duration::from_millis(100));
    };
    let output = stop(child.take().unwrap());
    let _ = std::fs::remove_dir_all(&data_dir);

    assert_eq!(instance.0, 200, "{}", instance.1);
    let instance: serde_json::Value = serde_json::from_str(&instance.1).unwrap();
    assert!(
        instance["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "relay"),
        "Relay must be available from the enable flag and origin alone: {instance}"
    );
    let warnings = output
        .lines()
        .filter(|line| line.contains("Relay allowlist variables are no longer used"))
        .collect::<Vec<_>>();
    assert_eq!(warnings.len(), 1, "{output}");
    assert!(warnings[0].contains("ATERMIUS_RELAY_ALLOW_CIDRS,ATERMIUS_RELAY_ALLOW_PORTS"));
    assert!(!output.contains("not-a-cidr"));
}
