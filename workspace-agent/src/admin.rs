//! Local operator socket. The public mTLS node listener never handles these requests.
use crate::state::{Node, State, Store};
use anyhow::{Context, Result, ensure};
use atermius_workspace_admin::{self as ipc, ClusterStatus, Command, NodeStatus, Overview, Reply};
use std::{
    fs,
    io::ErrorKind,
    net::IpAddr,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::Path,
    sync::Arc,
    time::Duration,
};
use tokio::{
    net::{UnixListener, UnixStream},
    sync::{Semaphore, watch},
    time::timeout,
};

/// Weak handles ensure completed, failed and cancelled transfers disappear from the live view.
#[derive(Default, Clone)]
pub struct Transfers(
    Arc<std::sync::Mutex<std::collections::HashMap<String, std::sync::Weak<CopyProgress>>>>,
);
pub struct CopyProgress {
    generation: u64,
    phase: crate::state::Phase,
    total: u64,
    bytes: std::sync::atomic::AtomicU64,
}
impl CopyProgress {
    pub fn add(&self, n: usize) {
        self.bytes
            .fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
    }
}
impl Transfers {
    pub fn begin(
        &self,
        key: &crate::wire::Key,
        phase: crate::state::Phase,
        total: u64,
    ) -> Arc<CopyProgress> {
        let p = Arc::new(CopyProgress {
            generation: key.generation,
            phase,
            total,
            bytes: 0.into(),
        });
        self.0
            .lock()
            .unwrap()
            .insert(key.cluster.clone(), Arc::downgrade(&p));
        p
    }
    fn annotate(&self, overview: &mut Overview) {
        let mut copies = self.0.lock().unwrap();
        copies.retain(|_, value| value.strong_count() > 0);
        for c in &mut overview.clusters {
            if let Some(p) = copies.get(&c.cluster).and_then(|w| w.upgrade())
                && c.generation == p.generation
                && c.phase == p.phase
            {
                c.transfer = Some(ipc::TransferStatus {
                    bytes: p.bytes.load(std::sync::atomic::Ordering::Relaxed),
                    total: p.total,
                });
            }
        }
    }
}

impl Store {
    pub fn overview(&self) -> Result<Overview> {
        let state = self.read()?;
        let mut retrying = std::collections::HashMap::new();
        let nodes = state
            .nodes
            .into_iter()
            .map(|(name, node)| {
                let seen = fs::metadata(self.0.join(format!("seen-{name}")))
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .map(|d| d.as_secs());
                if node.enabled && seen.is_some_and(|age| age < 30) {
                    let failed: Vec<(String, u64, i32)> =
                        fs::read(self.0.join(format!("seen-{name}")))
                            .ok()
                            .and_then(|b| serde_json::from_slice(&b).ok())
                            .unwrap_or_default();
                    for (id, g, t) in failed {
                        if t != crate::wire::Task::Retire as i32 {
                            retrying.insert((id, g), name.clone());
                        }
                    }
                }
                NodeStatus {
                    name,
                    enabled: node.enabled,
                    revision: node.revision,
                    online: node.enabled && seen.is_some_and(|s| s < 30),
                    last_seen_seconds_ago: seen,
                    network: node.network,
                    host_ssh: node.host_ssh,
                    image: node.image,
                    fingerprint: node.fingerprint,
                }
            })
            .collect();
        let clusters = state
            .clusters
            .into_iter()
            .map(|(cluster, c)| ClusterStatus {
                retrying_on: retrying
                    .remove(&(cluster.clone(), c.generation))
                    .filter(|n| n == &c.owner || Some(n) == c.target.as_ref()),
                cluster,
                node: c.owner,
                target: c.target,
                phase: c.phase,
                generation: c.generation,
                volume_generation: c.volume,
                port: c.port,
                pending_cleanup: c.retired.len(),
                kind: if c.image.is_empty() {
                    "host"
                } else {
                    "workspace"
                }
                .into(),
                snapshot_bytes: c.snapshot.map(|b| b.size),
                transfer: None,
            })
            .collect();
        Ok(Overview { nodes, clusters })
    }
}
impl State {
    pub fn set_enabled(&mut self, id: &str, enabled: bool, expected: Option<u64>) -> Result<()> {
        let node = self.nodes.get_mut(id).context("unknown node")?;
        if let Some(rev) = expected {
            ensure!(node.revision == rev, "stale node revision")
        }
        if node.enabled != enabled {
            node.enabled = enabled;
            node.revision += 1;
        }
        Ok(())
    }
    fn apply(&mut self, command: Command) -> Result<()> {
        match command {
            Command::RegisterNode { registration: r } => {
                self.register(
                    &r.node,
                    Node {
                        enabled: true,
                        revision: 1,
                        fingerprint: r.fingerprint,
                        image: r.image,
                        network: r.network,
                        host_ssh: r.host_ssh,
                    },
                )?;
                if let Some(initial) = r.initial_workspace {
                    self.create(
                        &initial.cluster,
                        &r.node,
                        initial.port,
                        initial.authorized_keys.trim(),
                        false,
                    )?;
                }
                Ok(())
            }
            Command::SetNodeEnabled {
                node,
                enabled,
                expected_revision,
            } => self.set_enabled(&node, enabled, Some(expected_revision)),
            Command::CreateWorkspace {
                cluster,
                node,
                port,
                authorized_keys,
            } => self.create(&cluster, &node, port, authorized_keys.trim(), false),
            Command::PublishHost {
                cluster,
                node,
                port,
            } => self.create(&cluster, &node, port, "", true),
            Command::Migrate {
                cluster,
                destination,
                expected_generation,
            } => {
                let c = self.clusters.get(&cluster).context("unknown cluster")?;
                ensure!(
                    c.generation == expected_generation
                        && c.phase == crate::state::Phase::Running
                        && c.owner != destination,
                    "stale migration"
                );
                self.migrate(&cluster, &destination)
            }
            Command::Abort {
                cluster,
                expected_generation,
            } => {
                let c = self.clusters.get(&cluster).context("unknown cluster")?;
                ensure!(c.generation == expected_generation, "stale migration");
                self.abort(&cluster)
            }
        }
    }
}

pub async fn bind(path: &Path) -> Result<UnixListener> {
    ensure!(path.is_absolute(), "admin socket requires an absolute path");
    let parent = path.parent().context("admin socket has no directory")?;
    let meta = fs::symlink_metadata(parent)?;
    ensure!(
        meta.is_dir() && meta.permissions().mode() & 0o007 == 0,
        "use a private directory for the workspace admin socket"
    );
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            ensure!(meta.file_type().is_socket(), "admin path is not a socket");
            match UnixStream::connect(path).await {
                Err(e) if e.kind() == ErrorKind::ConnectionRefused => fs::remove_file(path)?,
                _ => anyhow::bail!("workspace admin socket already in use"),
            }
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o660))?;
    Ok(listener)
}
fn process(store: &Store, access: IpAddr, transfers: &Transfers, request: ipc::Request) -> Reply {
    if request.version != ipc::PROTOCOL {
        return Reply::Invalid;
    }
    let Some(command) = request.command else {
        return match store.overview() {
            Ok(mut overview) => {
                transfers.annotate(&mut overview);
                Reply::Status {
                    overview,
                    ssh_host: access.to_string(),
                }
            }
            Err(_) => Reply::Unavailable,
        };
    };
    if command.validate().is_err() {
        return Reply::Invalid;
    }
    let mut rejected = false;
    match store.update(|s| {
        let result = s.apply(command);
        rejected = result.is_err();
        result
    }) {
        Ok(()) => Reply::Accepted,
        Err(_) if rejected => Reply::Conflict,
        Err(_) => Reply::Unavailable,
    }
}
pub async fn serve(
    listener: UnixListener,
    store: Store,
    access: IpAddr,
    signal: watch::Sender<u64>,
    transfers: Transfers,
) -> Result<()> {
    let slots = Arc::new(Semaphore::new(8));
    loop {
        let permit = slots.clone().acquire_owned().await?;
        let (mut sock, _) = listener.accept().await?;
        let store = store.clone();
        let transfers = transfers.clone();
        let signal = signal.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let Ok(Ok(request)) = timeout(
                Duration::from_secs(3),
                ipc::receive(&mut sock, ipc::MAX_COMMAND),
            )
            .await
            else {
                return;
            };
            let reply =
                tokio::task::spawn_blocking(move || process(&store, access, &transfers, request))
                    .await
                    .unwrap_or(Reply::Unavailable);
            if matches!(reply, Reply::Accepted) {
                signal.send_modify(|n| *n = n.wrapping_add(1));
            }
            let _ = timeout(
                Duration::from_secs(3),
                ipc::send(&mut sock, &reply, ipc::MAX_REPLY),
            )
            .await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ipc::{InitialWorkspace, Registration};
    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGM5yPbvjkN7N/x5KQ0a+AHSs/ZuLkSS2FXQDq20Nii3";
    fn register(id: &str, fp: char, port: u16) -> Command {
        Command::RegisterNode {
            registration: Registration {
                node: id.into(),
                fingerprint: fp.to_string().repeat(64),
                image: format!("sha256:{}", "a".repeat(64)),
                host_ssh: true,
                network: "none".into(),
                initial_workspace: Some(InitialWorkspace {
                    cluster: format!("{id}-cluster"),
                    port,
                    authorized_keys: KEY.into(),
                }),
            },
        }
    }
    #[test]
    fn registration_is_atomic_and_mutations_use_cli_state_and_revisions() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store(tmp.path().into());
        let call = |cmd| {
            process(
                &store,
                "127.0.0.1".parse().unwrap(),
                &Transfers::default(),
                ipc::Request {
                    version: ipc::PROTOCOL,
                    command: Some(cmd),
                },
            )
        };
        assert!(matches!(
            call(register("first", 'a', 24001)),
            Reply::Accepted
        ));
        assert!(matches!(
            call(register("second", 'b', 24001)),
            Reply::Conflict
        ));
        assert_eq!(store.overview().unwrap().nodes.len(), 1);
        assert!(matches!(
            call(register("second", 'b', 24002)),
            Reply::Accepted
        ));
        let toggle = |rev| Command::SetNodeEnabled {
            node: "second".into(),
            enabled: false,
            expected_revision: rev,
        };
        assert!(matches!(call(toggle(1)), Reply::Accepted));
        assert!(matches!(call(toggle(1)), Reply::Conflict));
        assert!(!store.read().unwrap().nodes["second"].enabled);
        let raw = serde_json::to_string(&store.overview().unwrap()).unwrap();
        assert!(!raw.contains(KEY));
        assert!(!raw.contains("authorized_keys"));
    }
    #[test]
    fn active_transfer_is_scoped_to_its_phase_and_generation() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store(tmp.path().into());
        store
            .update(|s| s.apply(register("first", 'a', 24001)))
            .unwrap();
        let mut status = store.overview().unwrap();
        let copies = Transfers::default();
        let key = crate::wire::Key {
            cluster: "first-cluster".into(),
            generation: 2,
        };
        let p = copies.begin(&key, crate::state::Phase::Snapshot, 100);
        p.add(40);
        copies.annotate(&mut status);
        assert!(status.clusters[0].transfer.is_none());
        let c = &mut status.clusters[0];
        c.phase = crate::state::Phase::Snapshot;
        c.generation = 2;
        copies.annotate(&mut status);
        assert_eq!(status.clusters[0].transfer.as_ref().unwrap().bytes, 40);
        drop(p);
        let mut fresh = store.overview().unwrap();
        fresh.clusters[0].generation = 2;
        fresh.clusters[0].phase = crate::state::Phase::Snapshot;
        copies.annotate(&mut fresh);
        assert!(fresh.clusters[0].transfer.is_none());
    }
}
