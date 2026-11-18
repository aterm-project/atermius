use crate::wire::{Completion, Job, Key, Task};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

pub const MAX_SNAPSHOT: u64 = 512 * 1024 * 1024;
pub const MAX_CLUSTERS: usize = 256;

pub use atermius_workspace_admin::{Phase, image_id, name, sha, valid_network, validate_keys};
pub fn private_dir(p: &Path) -> Result<()> {
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(p)?;
    Ok(())
}
pub fn write_atomic(p: &Path, data: &[u8]) -> Result<()> {
    let dir = p.parent().context("missing parent directory")?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    tmp.write_all(data)?;
    // The operator CLI and an unprivileged hub may share the operator-owned directory.
    let owner = dir.metadata()?;
    let temp_owner = tmp.as_file().metadata()?;
    if owner.uid() != temp_owner.uid() || owner.gid() != temp_owner.gid() {
        std::os::unix::fs::chown(tmp.path(), Some(owner.uid()), Some(owner.gid()))?;
    }
    tmp.as_file().sync_all()?;
    tmp.persist(p)?;
    File::open(dir)?.sync_all()?;
    Ok(())
}

#[derive(Clone)]
pub struct Store(pub PathBuf);
impl Store {
    fn open_lock(&self) -> Result<File> {
        private_dir(&self.0)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.0.join("state.lock"))?;
        lock.lock()?;
        Ok(lock)
    }
    fn load(&self) -> Result<State> {
        match fs::read(self.0.join("state.json")) {
            Ok(b) => Ok(serde_json::from_slice(&b)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e.into()),
        }
    }
    pub fn read(&self) -> Result<State> {
        let _lock = self.open_lock()?;
        self.load()
    }
    pub fn update<T>(&self, f: impl FnOnce(&mut State) -> Result<T>) -> Result<T> {
        let _lock = self.open_lock()?;
        let mut v = self.load()?;
        let out = f(&mut v)?;
        write_atomic(&self.0.join("state.json"), &serde_json::to_vec_pretty(&v)?)?;
        Ok(out)
    }
    pub fn blob(&self, id: &str, g: u64, digest: &str) -> PathBuf {
        self.0.join(format!("snapshot-{id}-{g}-{digest}.tar"))
    }
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct Node {
    pub enabled: bool,
    pub revision: u64,
    pub host_ssh: bool,
    pub network: String,
    pub fingerprint: String,
    pub image: String,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Blob {
    pub digest: String,
    pub size: u64,
    pub generation: u64,
}
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Retired {
    pub node: String,
    pub volume: u64,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Cluster {
    pub owner: String,
    pub target: Option<String>,
    pub phase: Phase,
    pub generation: u64,
    pub volume: u64,
    pub port: u16,
    pub image: String,
    pub keys: String,
    pub snapshot: Option<Blob>,
    pub retired: Vec<Retired>,
}
#[derive(Default, Serialize, Deserialize)]
pub struct State {
    pub nodes: BTreeMap<String, Node>,
    pub clusters: BTreeMap<String, Cluster>,
}
impl State {
    pub fn register(&mut self, id: &str, node: Node) -> Result<()> {
        name(id)?;
        ensure!(
            sha(&node.fingerprint) && (node.image.is_empty() || image_id(&node.image)),
            "invalid certificate digest or image ID"
        );
        ensure!(
            node.network == "none" || valid_network(&node.network),
            "invalid egress network"
        );
        if let Some(old) = self.nodes.get(id) {
            ensure!(
                old.fingerprint == node.fingerprint
                    && old.image == node.image
                    && old.network == node.network
                    && old.host_ssh == node.host_ssh,
                "node already enrolled with another identity or image"
            );
            return Ok(());
        }
        ensure!(
            self.nodes.len() < 256
                && !self
                    .nodes
                    .values()
                    .any(|v| v.fingerprint == node.fingerprint),
            "node limit or certificate already assigned"
        );
        self.nodes.insert(id.into(), node);
        Ok(())
    }
    pub fn create(
        &mut self,
        id: &str,
        owner: &str,
        port: u16,
        keys: &str,
        host: bool,
    ) -> Result<()> {
        name(id)?;
        let node = self.nodes.get(owner).context("unknown node")?;
        ensure!(
            node.enabled && (!host || node.host_ssh),
            "node disabled or host SSH not approved"
        );
        ensure!(port >= 1024, "use an unprivileged SSH access port");
        if !host {
            ensure!(image_id(&node.image), "node has no workspace image");
            validate_keys(keys)?;
        }
        let image = if host {
            String::new()
        } else {
            node.image.clone()
        };
        if let Some(c) = self.clusters.get(id) {
            ensure!(
                c.owner == owner && c.image == image && c.port == port && c.keys == keys,
                "cluster already exists with different settings"
            );
            return Ok(());
        }
        ensure!(
            self.clusters.len() < MAX_CLUSTERS && self.clusters.values().all(|c| c.port != port),
            "duplicate port or cluster limit"
        );
        self.clusters.insert(
            id.into(),
            Cluster {
                owner: owner.into(),
                target: None,
                phase: if host {
                    Phase::Running
                } else {
                    Phase::Provisioning
                },
                generation: 1,
                volume: 1,
                port,
                image,
                keys: keys.into(),
                snapshot: None,
                retired: vec![],
            },
        );
        Ok(())
    }
    pub fn migrate(&mut self, id: &str, to: &str) -> Result<()> {
        let dest = self.nodes.get(to).context("unregistered destination")?;
        let c = self.clusters.get_mut(id).context("unknown cluster")?;
        ensure!(
            !c.image.is_empty()
                && dest.enabled
                && dest.image == c.image
                && dest.network == self.nodes[&c.owner].network,
            "destination must be enabled and match the workspace image and egress network"
        );
        if c.target.as_deref() == Some(to) && matches!(c.phase, Phase::Snapshot | Phase::Restore) {
            return Ok(());
        }
        ensure!(c.phase == Phase::Running, "cluster is busy");
        if c.owner != to {
            c.generation += 1;
            c.target = Some(to.into());
            c.phase = Phase::Snapshot;
        }
        Ok(())
    }
    pub fn abort(&mut self, id: &str) -> Result<()> {
        let c = self.clusters.get_mut(id).context("unknown cluster")?;
        match c.phase {
            Phase::Snapshot => {
                c.generation += 1;
                c.target = None;
                c.phase = Phase::Resume;
            }
            Phase::Restore => {
                c.phase = Phase::Fence;
            }
            Phase::Fence | Phase::Resume => {}
            _ => bail!("no pending migration"),
        }
        Ok(())
    }
    pub fn jobs(&self, node: &str) -> Vec<Job> {
        let mut out = vec![];
        for (id, c) in &self.clusters {
            if c.image.is_empty() {
                continue;
            }
            let job = |task: Task, g: u64, vol: u64| Job {
                key: Some(Key {
                    cluster: id.clone(),
                    generation: g,
                }),
                task: task as i32,
                authorized_key: c.keys.clone(),
                image: c.image.clone(),
                volume_generation: vol,
                create: c.phase == Phase::Provisioning,
                acknowledge: c.phase != Phase::Running,
                digest: c
                    .snapshot
                    .as_ref()
                    .map(|b| b.digest.clone())
                    .unwrap_or_default(),
                size: c.snapshot.as_ref().map(|b| b.size).unwrap_or_default(),
            };
            for retired in &c.retired {
                if retired.node == node {
                    out.push(job(Task::Retire, retired.volume, retired.volume))
                }
            }
            let task = match c.phase {
                Phase::Provisioning | Phase::Running | Phase::Resume if c.owner == node => {
                    Some((Task::Start, c.volume))
                }
                Phase::Snapshot if c.owner == node => Some((Task::Snapshot, c.volume)),
                Phase::Restore if c.target.as_deref() == Some(node) => {
                    Some((Task::Restore, c.generation))
                }
                Phase::Fence if c.target.as_deref() == Some(node) => {
                    Some((Task::Fence, c.generation))
                }
                _ => None,
            };
            if let Some((task, volume)) = task {
                out.push(job(task, c.generation, volume));
            }
        }
        out
    }
    pub fn finish(&mut self, node: &str, done: &Completion) -> Result<Option<(String, Blob)>> {
        let k = done.key.as_ref().context("missing job")?;
        let c = self
            .clusters
            .get_mut(&k.cluster)
            .context("unknown cluster")?;
        let task = Task::try_from(done.task)?;
        if task == Task::Retire {
            ensure!(
                k.generation == done.volume_generation
                    && !(c.owner == node && c.volume == done.volume_generation),
                "invalid retirement"
            );
            c.retired
                .retain(|r| r.node != node || r.volume != done.volume_generation);
            return Ok(None);
        }
        ensure!(k.generation == c.generation, "stale job");
        match task {
            Task::Start
                if c.owner == node
                    && c.volume == done.volume_generation
                    && matches!(
                        c.phase,
                        Phase::Provisioning | Phase::Resume | Phase::Running
                    ) =>
            {
                c.phase = Phase::Running
            }
            Task::Restore
                if c.target.as_deref() == Some(node)
                    && c.phase == Phase::Restore
                    && c.generation == done.volume_generation =>
            {
                c.retired.push(Retired {
                    node: c.owner.clone(),
                    volume: c.volume,
                });
                c.owner = node.into();
                c.volume = c.generation;
                c.phase = Phase::Running;
                c.target = None;
            }
            Task::Fence
                if c.target.as_deref() == Some(node)
                    && c.phase == Phase::Fence
                    && c.generation == done.volume_generation =>
            {
                c.retired.push(Retired {
                    node: node.into(),
                    volume: c.generation,
                });
                c.target = None;
                c.generation += 1;
                c.phase = Phase::Resume;
            }
            _ => bail!("job not assigned to this node"),
        }
        Ok(c.snapshot.take().map(|b| (k.cluster.clone(), b)))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn node(n: u8) -> Node {
        Node {
            enabled: true,
            revision: 1,
            host_ssh: false,
            network: "none".into(),
            fingerprint: format!("{n:02x}").repeat(32),
            image: format!("sha256:{}", "a".repeat(64)),
        }
    }
    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGM5yPbvjkN7N/x5KQ0a+AHSs/ZuLkSS2FXQDq20Nii3";
    fn fixture() -> State {
        let mut s = State::default();
        s.register("a", node(1)).unwrap();
        s.register("b", node(2)).unwrap();
        s.create("lab", "a", 24000, KEY, false).unwrap();
        s
    }
    fn done(task: Task, generation: u64, vol: u64) -> Completion {
        Completion {
            key: Some(Key {
                cluster: "lab".into(),
                generation,
            }),
            task: task as i32,
            volume_generation: vol,
        }
    }
    #[test]
    fn only_the_assigned_node_can_advance_a_generation() {
        let mut s = fixture();
        assert!(s.finish("b", &done(Task::Start, 1, 1)).is_err());
        s.finish("a", &done(Task::Start, 1, 1)).unwrap();
        s.migrate("lab", "b").unwrap();
        s.migrate("lab", "b").unwrap();
        assert_eq!(s.jobs("a")[0].task, Task::Snapshot as i32);
        assert!(s.jobs("b").is_empty());
        assert!(s.finish("b", &done(Task::Restore, 2, 2)).is_err());
        s.abort("lab").unwrap();
        assert_eq!(s.jobs("a")[0].key.as_ref().unwrap().generation, 3);
        assert!(!s.jobs("a")[0].create);
        assert!(s.finish("a", &done(Task::Start, 1, 1)).is_err());
        s.finish("a", &done(Task::Start, 3, 1)).unwrap();
        assert_eq!(s.clusters["lab"].phase, Phase::Running);
    }
    #[test]
    fn validates_registration_capacity_and_capabilities() {
        let mut s = fixture();
        assert!(s.register("alias", node(1)).is_err());
        assert!(s.create("other", "b", 24000, KEY, false).is_err());
        assert!(s.create("host", "b", 24001, "", true).is_err());
        assert!(s.create("../escape", "b", 24001, KEY, false).is_err());
        assert!(
            s.create("other", "b", 24001, "command=bad ssh-ed25519 AAAA", false)
                .is_err()
        );
        s.finish("a", &done(Task::Start, 1, 1)).unwrap();
        s.nodes.get_mut("b").unwrap().network = "other".into();
        assert!(s.migrate("lab", "b").is_err());
    }
    #[test]
    fn failed_transaction_does_not_publish_partial_enrollment() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Store(tmp.path().into());
        assert!(
            db.update(|s| {
                s.register("a", node(1))?;
                s.create("lab", "a", 22, KEY, false)
            })
            .is_err()
        );
        assert!(db.read().unwrap().nodes.is_empty());
    }
}
