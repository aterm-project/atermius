use crate::{
    state::{self, Blob, Phase, Store},
    wire::{
        part::Payload,
        workspace_server::{Workspace, WorkspaceServer},
        *,
    },
};
use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch},
    time::{sleep, timeout},
};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{
    Request, Response, Status, Streaming,
    transport::{Certificate, Identity, Server, ServerTlsConfig},
};
use uuid::Uuid;

pub const CHUNK: usize = 65536;
const LEASE: Duration = Duration::from_secs(30);
type Stream = ReceiverStream<Result<Part, Status>>;
struct Pending {
    node: String,
    expires: Instant,
    revision: u64,
    open: Open,
    socket: TcpStream,
    _cluster: OwnedSemaphorePermit,
    _total: OwnedSemaphorePermit,
}
#[derive(Clone)]
struct Hub {
    store: Store,
    leases: Arc<Mutex<HashMap<String, (String, Instant)>>>,
    pending: Arc<Mutex<HashMap<String, Pending>>>,
    signal: watch::Sender<u64>,
    transfers: Arc<Semaphore>,
    sessions: Arc<Semaphore>,
}
fn fault(e: impl std::fmt::Display) -> Status {
    eprintln!("workspace state: {e}");
    Status::failed_precondition("workspace operation unavailable or stale")
}
fn invalid() -> Status {
    Status::invalid_argument("invalid workspace message")
}
fn touch(tx: &watch::Sender<u64>) {
    tx.send_modify(|n| *n = n.wrapping_add(1));
}
pub async fn message(s: &mut Streaming<Part>) -> Result<Option<Part>, Status> {
    timeout(Duration::from_secs(60), s.message())
        .await
        .map_err(|_| Status::deadline_exceeded("stream idle"))?
}
async fn header(s: &mut Streaming<Part>) -> Result<Header, Status> {
    match message(s).await?.and_then(|p| p.payload) {
        Some(Payload::Header(h)) => Ok(h),
        _ => Err(invalid()),
    }
}
pub fn data(b: &[u8]) -> Part {
    Part {
        payload: Some(Payload::Data(b.to_vec())),
    }
}
pub fn first(h: Header) -> Part {
    Part {
        payload: Some(Payload::Header(h)),
    }
}
pub fn bytes(p: Part) -> Result<Vec<u8>, Status> {
    match p.payload {
        Some(Payload::Data(b)) if !b.is_empty() && b.len() <= CHUNK => Ok(b),
        _ => Err(invalid()),
    }
}
impl Hub {
    fn identity<T>(&self, r: &Request<T>) -> Result<String, Status> {
        let certs = r
            .peer_certs()
            .ok_or_else(|| Status::unauthenticated("node certificate required"))?;
        let cert = certs
            .first()
            .ok_or_else(|| Status::unauthenticated("node certificate required"))?;
        let hash = hex::encode(Sha256::digest(cert.as_ref()));
        self.store
            .read()
            .map_err(fault)?
            .nodes
            .into_iter()
            .find(|(_, n)| n.enabled && n.fingerprint == hash)
            .map(|(n, _)| n)
            .ok_or_else(|| Status::permission_denied("unregistered node"))
    }
    fn instance<T>(r: &Request<T>) -> Result<String, Status> {
        let i = r
            .metadata()
            .get("x-atermius-instance")
            .and_then(|v| v.to_str().ok())
            .ok_or_else(invalid)?;
        Uuid::parse_str(i).map_err(|_| invalid())?;
        Ok(i.to_owned())
    }
    fn authenticated<T>(&self, r: &Request<T>) -> Result<String, Status> {
        let id = self.identity(r)?;
        let instance = Self::instance(r)?;
        if !self
            .leases
            .lock()
            .unwrap()
            .get(&id)
            .is_some_and(|(i, t)| i == &instance && t.elapsed() < LEASE)
        {
            return Err(Status::failed_precondition(
                "node must register its live connection",
            ));
        }
        Ok(id)
    }
    async fn listen_routes(self, ip: IpAddr) {
        let mut listeners = HashMap::new();
        loop {
            self.pending
                .lock()
                .unwrap()
                .retain(|_, p| p.expires > Instant::now());
            match self.store.read() {
                Ok(state) => {
                    for (id, c) in state.clusters {
                        if listeners.contains_key(&id) {
                            continue;
                        }
                        match TcpListener::bind((ip, c.port)).await {
                            Ok(l) => {
                                let hub = self.clone();
                                let key = id.clone();
                                listeners.insert(
                                    id,
                                    tokio::spawn(async move {
                                        let limit = Arc::new(Semaphore::new(16));
                                        loop {
                                            match l.accept().await {
                                                Ok((s, _)) => {
                                                    if let (Ok(each), Ok(all)) = (
                                                        limit.clone().try_acquire_owned(),
                                                        hub.sessions.clone().try_acquire_owned(),
                                                    ) {
                                                        hub.offer(&key, s, each, all);
                                                    }
                                                }
                                                Err(e) => {
                                                    eprintln!("workspace SSH accept: {e}");
                                                    sleep(Duration::from_secs(1)).await;
                                                }
                                            }
                                        }
                                    }),
                                );
                            }
                            Err(e) => eprintln!("cannot bind cluster {id} port {}: {e}", c.port),
                        }
                    }
                }
                Err(e) => eprintln!("workspace routes: {e}"),
            }
            sleep(Duration::from_secs(1)).await;
        }
    }
    fn offer(
        &self,
        id: &str,
        socket: TcpStream,
        each: OwnedSemaphorePermit,
        all: OwnedSemaphorePermit,
    ) {
        let Ok(state) = self.store.read() else { return };
        let Some(c) = state.clusters.get(id) else {
            return;
        };
        if c.phase != Phase::Running
            || self
                .leases
                .lock()
                .unwrap()
                .get(&c.owner)
                .is_none_or(|(_, t)| t.elapsed() >= LEASE)
        {
            return;
        }
        let Some(node) = state.nodes.get(&c.owner).filter(|n| n.enabled) else {
            return;
        };
        let ticket = Uuid::new_v4().to_string();
        let open = Open {
            key: Some(Key {
                cluster: id.into(),
                generation: c.generation,
            }),
            ticket: ticket.clone(),
            volume_generation: c.volume,
            host: c.image.is_empty(),
        };
        self.pending.lock().unwrap().insert(
            ticket.clone(),
            Pending {
                node: c.owner.clone(),
                expires: Instant::now() + Duration::from_secs(10),
                revision: node.revision,
                open,
                socket,
                _cluster: each,
                _total: all,
            },
        );
        touch(&self.signal);
    }
}
#[tonic::async_trait]
impl Workspace for Hub {
    async fn poll(&self, req: Request<Hello>) -> Result<Response<Plan>, Status> {
        let id = self.identity(&req)?;
        let instance = Self::instance(&req)?;
        let hello = req.into_inner();
        if hello.node != id || hello.instance != instance {
            return Err(Status::permission_denied("identity mismatch"));
        }
        {
            let mut leases = self.leases.lock().unwrap();
            if leases
                .get(&id)
                .is_some_and(|(i, t)| i != &instance && t.elapsed() < LEASE)
            {
                return Err(Status::already_exists("node identity in use"));
            }
            leases.insert(id.clone(), (instance, Instant::now()));
        }
        let mut changes = self.signal.subscribe();
        if hello.cursor == *changes.borrow_and_update() {
            let _ = timeout(Duration::from_secs(4), changes.changed()).await;
        }
        let cursor = *changes.borrow_and_update();
        let jobs = self.store.read().map_err(fault)?.jobs(&id);
        let sessions = self
            .pending
            .lock()
            .unwrap()
            .values()
            .filter(|p| p.node == id)
            .map(|p| p.open.clone())
            .collect();
        std::fs::write(self.store.0.join(format!("seen-{id}")), b"").map_err(fault)?;
        Ok(Response::new(Plan {
            jobs,
            sessions,
            cursor,
        }))
    }
    async fn ready(&self, req: Request<Completion>) -> Result<Response<Empty>, Status> {
        let node = self.authenticated(&req)?;
        let removed = self
            .store
            .update(|s| s.finish(&node, req.get_ref()))
            .map_err(fault)?;
        if let Some((id, b)) = removed {
            let _ = std::fs::remove_file(self.store.blob(&id, b.generation, &b.digest));
        }
        touch(&self.signal);
        Ok(Response::new(Empty {}))
    }
    async fn upload(&self, req: Request<Streaming<Part>>) -> Result<Response<Empty>, Status> {
        let node = self.authenticated(&req)?;
        let _slot = self
            .transfers
            .clone()
            .try_acquire_owned()
            .map_err(|_| Status::resource_exhausted("transfer limit"))?;
        let mut stream = req.into_inner();
        let h = header(&mut stream).await?;
        let k = h.key.ok_or_else(invalid)?;
        if !state::sha(&h.digest) || h.size == 0 || h.size > state::MAX_SNAPSHOT {
            return Err(invalid());
        }
        let revision = self
            .store
            .read()
            .map_err(fault)?
            .nodes
            .get(&node)
            .filter(|n| n.enabled)
            .ok_or_else(|| Status::permission_denied("node disabled"))?
            .revision;
        let check = |s: &state::State| {
            s.nodes
                .get(&node)
                .is_some_and(|n| n.enabled && n.revision == revision)
                && s.clusters.get(&k.cluster).is_some_and(|c| {
                    c.owner == node && c.phase == Phase::Snapshot && c.generation == k.generation
                })
        };
        if !check(&self.store.read().map_err(fault)?) {
            return Err(Status::permission_denied("snapshot not assigned"));
        }
        let temp = tempfile::Builder::new()
            .prefix(".upload-")
            .tempfile_in(&self.store.0)
            .map_err(fault)?;
        let mut out = tokio::fs::File::from_std(temp.reopen().map_err(fault)?);
        let mut hash = Sha256::new();
        let mut size = 0u64;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1800);
        let mut checked = Instant::now();
        while let Some(p) = tokio::time::timeout_at(deadline, message(&mut stream))
            .await
            .map_err(|_| Status::deadline_exceeded("snapshot transfer deadline"))??
        {
            if checked.elapsed() >= Duration::from_secs(2) {
                if !check(&self.store.read().map_err(fault)?) {
                    return Err(Status::permission_denied("transfer revoked"));
                }
                checked = Instant::now();
            }
            let b = bytes(p)?;
            size += b.len() as u64;
            if size > h.size {
                return Err(invalid());
            }
            out.write_all(&b).await.map_err(fault)?;
            hash.update(&b);
        }
        if size != h.size || hex::encode(hash.finalize()) != h.digest {
            return Err(Status::data_loss("snapshot checksum or length mismatch"));
        }
        out.sync_all().await.map_err(fault)?;
        drop(out);
        self.store
            .update(|s| {
                ensure!(check(s), "snapshot superseded");
                temp.persist(self.store.blob(&k.cluster, k.generation, &h.digest))?;
                let c = s.clusters.get_mut(&k.cluster).unwrap();
                c.snapshot = Some(Blob {
                    digest: h.digest,
                    size,
                    generation: k.generation,
                });
                c.phase = Phase::Restore;
                Ok(())
            })
            .map_err(fault)?;
        touch(&self.signal);
        Ok(Response::new(Empty {}))
    }
    type DownloadStream = Stream;
    async fn download(&self, req: Request<Key>) -> Result<Response<Stream>, Status> {
        let node = self.authenticated(&req)?;
        let k = req.into_inner();
        let s = self.store.read().map_err(fault)?;
        let c = s
            .clusters
            .get(&k.cluster)
            .filter(|c| {
                c.generation == k.generation
                    && c.phase == Phase::Restore
                    && c.target.as_deref() == Some(&node)
            })
            .ok_or_else(|| Status::permission_denied("restore not assigned"))?;
        let b = c.snapshot.as_ref().ok_or_else(invalid)?;
        let slot = self
            .transfers
            .clone()
            .try_acquire_owned()
            .map_err(|_| Status::resource_exhausted("transfer limit"))?;
        let mut f = tokio::fs::File::open(self.store.blob(&k.cluster, b.generation, &b.digest))
            .await
            .map_err(fault)?;
        let store = self.store.clone();
        let revision = s.nodes[&node].revision;
        let (tx, rx) = mpsc::channel(4);
        tokio::spawn(async move {
            let _slot = slot;
            let mut buf = vec![0; CHUNK];
            let mut checked = Instant::now();
            loop {
                if checked.elapsed() >= Duration::from_secs(2) {
                    let granted = store.read().is_ok_and(|s| {
                        s.nodes
                            .get(&node)
                            .is_some_and(|n| n.enabled && n.revision == revision)
                            && s.clusters.get(&k.cluster).is_some_and(|c| {
                                c.phase == Phase::Restore
                                    && c.generation == k.generation
                                    && c.target.as_deref() == Some(&node)
                            })
                    });
                    if !granted {
                        let _ = tx
                            .send(Err(Status::permission_denied("transfer revoked")))
                            .await;
                        break;
                    }
                    checked = Instant::now();
                }
                match f.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        if !matches!(
                            timeout(Duration::from_secs(60), tx.send(Ok(data(&buf[..n])))).await,
                            Ok(Ok(()))
                        ) {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(fault(e))).await;
                        break;
                    }
                }
            }
        });
        Ok(Response::new(ReceiverStream::new(rx)))
    }
    type TunnelStream = Stream;
    async fn tunnel(&self, req: Request<Streaming<Part>>) -> Result<Response<Stream>, Status> {
        let node = self.authenticated(&req)?;
        let mut inbound = req.into_inner();
        let h = header(&mut inbound).await?;
        let k = h.key.ok_or_else(invalid)?;
        let revision = self
            .store
            .read()
            .map_err(fault)?
            .nodes
            .get(&node)
            .filter(|n| n.enabled)
            .ok_or_else(|| Status::permission_denied("node disabled"))?
            .revision;
        let valid = |s: &state::State| {
            s.clusters.get(&k.cluster).is_some_and(|c| {
                c.phase == Phase::Running && c.owner == node && c.generation == k.generation
            })
        };
        if !valid(&self.store.read().map_err(fault)?) {
            return Err(Status::permission_denied("inactive route"));
        }
        let p = {
            let mut waits = self.pending.lock().unwrap();
            match waits.get(&h.ticket) {
                Some(p)
                    if p.revision == revision
                        && p.expires > Instant::now()
                        && p.node == node
                        && p.open.key.as_ref() == Some(&k) =>
                {
                    waits.remove(&h.ticket).unwrap()
                }
                _ => {
                    return Err(Status::permission_denied(
                        "invalid or expired stream ticket",
                    ));
                }
            }
        };
        let (mut rd, mut wr) = p.socket.into_split();
        let (tx, rx) = mpsc::channel(4);
        let store = self.store.clone();
        tokio::spawn(async move {
            let _permits = (p._cluster, p._total);
            let from_tcp = async move {
                let mut buf = vec![0; CHUNK];
                loop {
                    let n = rd.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    tx.send(Ok(data(&buf[..n]))).await?;
                }
                Ok::<_, anyhow::Error>(())
            };
            let to_tcp = async move {
                while let Some(p) = inbound.message().await? {
                    wr.write_all(&bytes(p)?).await?
                }
                wr.shutdown().await?;
                Ok::<_, anyhow::Error>(())
            };
            let revoke = async move {
                loop {
                    sleep(Duration::from_secs(2)).await;
                    if !store.read().is_ok_and(|s| {
                        s.nodes
                            .get(&node)
                            .is_some_and(|n| n.enabled && n.revision == revision)
                            && s.clusters.get(&k.cluster).is_some_and(|c| {
                                c.phase == Phase::Running
                                    && c.owner == node
                                    && c.generation == k.generation
                            })
                    }) {
                        break;
                    }
                }
            };
            tokio::select! {_=async{tokio::try_join!(from_tcp,to_tcp)}=>{},_=revoke=>{},_=sleep(Duration::from_secs(3600))=>{}}
        });
        Ok(Response::new(ReceiverStream::new(rx)))
    }
}
pub async fn serve(dir: &Path, addr: SocketAddr, access: IpAddr) -> Result<()> {
    state::private_dir(dir)?;
    let singleton = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join("hub.lock"))?;
    singleton
        .try_lock()
        .context("another hub owns this state directory")?;
    let tls = ServerTlsConfig::new()
        .identity(Identity::from_pem(
            std::fs::read(dir.join("hub.crt"))?,
            std::fs::read(dir.join("hub.key"))?,
        ))
        .client_ca_root(Certificate::from_pem(std::fs::read(dir.join("ca.crt"))?));
    let store = Store(dir.into());
    let s = store.read()?;
    let keep: std::collections::HashSet<_> = s
        .clusters
        .iter()
        .filter_map(|(id, c)| {
            c.snapshot
                .as_ref()
                .map(|b| store.blob(id, b.generation, &b.digest))
        })
        .collect();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let filename = entry.file_name();
        let filename = filename.to_string_lossy();
        let incomplete = filename.starts_with(".upload-");
        let unreferenced = filename.starts_with("snapshot-")
            && filename.ends_with(".tar")
            && !keep.contains(&path);
        if entry.file_type()?.is_file() && (incomplete || unreferenced) {
            std::fs::remove_file(path)?;
        }
    }
    let hub = Hub {
        store,
        leases: Default::default(),
        pending: Default::default(),
        signal: watch::channel(1).0,
        transfers: Arc::new(Semaphore::new(4)),
        sessions: Arc::new(Semaphore::new(128)),
    };
    let routes = tokio::spawn(hub.clone().listen_routes(access));
    let result = Server::builder()
        .tls_config(tls)?
        .concurrency_limit_per_connection(128)
        .add_service(WorkspaceServer::new(hub).max_decoding_message_size(128 * 1024))
        .serve(addr)
        .await;
    routes.abort();
    result?;
    Ok(())
}
