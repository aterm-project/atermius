use crate::{
    hub::{CHUNK, bytes, data, first, message},
    runtime::Runtime,
    state::{self, MAX_SNAPSHOT},
    wire::{workspace_client::WorkspaceClient, *},
};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    sync::mpsc,
    task::JoinSet,
    time::{sleep, timeout},
};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{
    Request,
    transport::{Certificate, Channel, ClientTlsConfig, Endpoint, Identity},
};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    node: String,
    endpoint: String,
    realm: String,
    #[serde(default)]
    image: String,
    host_ssh_port: Option<u16>,
    network: String,
}
#[derive(Clone)]
struct Node {
    cfg: Arc<Config>,
    dir: PathBuf,
    instance: String,
    client: WorkspaceClient<Channel>,
}
impl Node {
    fn request<T>(&self, msg: T) -> Request<T> {
        let mut r = Request::new(msg);
        r.metadata_mut()
            .insert("x-atermius-instance", self.instance.parse().unwrap());
        r
    }
    fn runtime(&self, id: &str, volume: u64) -> Result<Runtime> {
        Runtime::new(
            &self.cfg.node,
            &self.cfg.realm,
            &self.dir,
            id,
            volume,
            &self.cfg.image,
            &self.cfg.network,
        )
    }
    async fn job(&self, j: Job) -> Result<()> {
        let k = j.key.clone().context("job key missing")?;
        ensure!(
            j.image == self.cfg.image && state::image_id(&j.image),
            "workspace image is not the approved image"
        );
        let rt = self.runtime(&k.cluster, j.volume_generation)?;
        match Task::try_from(j.task)? {
            Task::Start => {
                rt.start(&j).await?;
                if !j.acknowledge {
                    return Ok(());
                }
            }
            Task::Retire => rt.retire().await?,
            Task::Fence => rt.fence(k.generation).await?,
            Task::Snapshot => {
                rt.fence(k.generation).await?;
                let tmp = tempfile::Builder::new()
                    .prefix(".transfer-")
                    .tempfile_in(&self.dir)?;
                let (digest, size) = rt.export(tmp.path()).await?;
                let (tx, rx) = mpsc::channel(4);
                tx.send(first(Header {
                    key: Some(k),
                    digest,
                    size,
                    ticket: String::new(),
                }))
                .await?;
                let mut file = tokio::fs::File::open(tmp.path()).await?;
                let mut client = self.client.clone();
                let read = async move {
                    let mut buf = vec![0; CHUNK];
                    loop {
                        let n = file.read(&mut buf).await?;
                        if n == 0 {
                            break;
                        }
                        tx.send(data(&buf[..n])).await?;
                    }
                    Ok::<_, anyhow::Error>(())
                };
                tokio::try_join!(read, async {
                    client.upload(self.request(ReceiverStream::new(rx))).await?;
                    Ok(())
                })?;
                return Ok(());
            }
            Task::Restore => {
                rt.allowed(k.generation)?;
                ensure!(
                    j.size > 0 && j.size <= MAX_SNAPSHOT && state::sha(&j.digest),
                    "invalid snapshot metadata"
                );
                if !rt.restored(&j.digest)? {
                    let mut inbound = self
                        .client
                        .clone()
                        .download(self.request(k.clone()))
                        .await?
                        .into_inner();
                    let tmp = tempfile::Builder::new()
                        .prefix(".transfer-")
                        .tempfile_in(&self.dir)?;
                    let mut out = tokio::fs::File::from_std(tmp.reopen()?);
                    let mut hash = Sha256::new();
                    let mut size = 0;
                    while let Some(p) = message(&mut inbound).await? {
                        let b = bytes(p)?;
                        size += b.len() as u64;
                        ensure!(size <= j.size, "snapshot too large");
                        hash.update(&b);
                        out.write_all(&b).await?
                    }
                    ensure!(
                        size == j.size && hex::encode(hash.finalize()) == j.digest,
                        "snapshot verification failed"
                    );
                    out.flush().await?;
                    drop(out);
                    rt.import(tmp.path(), &j.digest).await?;
                }
                rt.start(&j).await?;
            }
        }
        let mut req = self.request(Completion {
            key: Some(k),
            task: j.task,
            volume_generation: j.volume_generation,
        });
        req.set_timeout(Duration::from_secs(10));
        self.client.clone().ready(req).await?;
        Ok(())
    }
    async fn session(&self, o: Open) -> Result<()> {
        let k = o.key.as_ref().context("missing session key")?;
        state::name(&k.cluster)?;
        Uuid::parse_str(&o.ticket)?;
        if o.host {
            let port = self
                .cfg
                .host_ssh_port
                .context("host SSH access is disabled")?;
            let sock = timeout(
                Duration::from_secs(5),
                TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)),
            )
            .await??;
            let (rd, wr) = sock.into_split();
            return self.bridge(o, rd, wr).await;
        }
        let mut child = self
            .runtime(&k.cluster, o.volume_generation)?
            .ssh(k.generation)
            .await?;
        let result = self
            .bridge(o, child.stdout.take().unwrap(), child.stdin.take().unwrap())
            .await;
        let _ = child.kill().await;
        result
    }
    async fn bridge(
        &self,
        o: Open,
        mut rd: impl AsyncRead + Unpin,
        mut wr: impl AsyncWrite + Unpin,
    ) -> Result<()> {
        let (tx, rx) = mpsc::channel(4);
        tx.send(first(Header {
            key: o.key,
            ticket: o.ticket,
            ..Default::default()
        }))
        .await?;
        let upload = async move {
            let mut buf = vec![0; CHUNK];
            loop {
                let n = rd.read(&mut buf).await?;
                if n == 0 {
                    break;
                }
                tx.send(data(&buf[..n])).await?;
            }
            Ok::<_, anyhow::Error>(())
        };
        let download = async {
            let mut stream = timeout(
                Duration::from_secs(10),
                self.client
                    .clone()
                    .tunnel(self.request(ReceiverStream::new(rx))),
            )
            .await??
            .into_inner();
            while let Some(p) = stream.message().await? {
                wr.write_all(&bytes(p)?).await?
            }
            wr.shutdown().await?;
            Ok(())
        };
        tokio::try_join!(upload, download)?;
        Ok(())
    }
    async fn run(self) -> Result<()> {
        let mut cursor = 0;
        let mut delay = 1u64;
        let mut jobs = JoinSet::new();
        let mut sessions = JoinSet::new();
        let mut busy = HashSet::new();
        let mut tickets = HashSet::new();
        let mut next = HashMap::new();
        let mut failures = HashSet::new();
        let mut connected = false;
        loop {
            while let Some(result) = jobs.try_join_next() {
                let (id, generation, task, result): (String, u64, i32, Result<()>) = result?;
                busy.remove(&id);
                let stamp = (id, generation, task);
                let pause = if let Err(e) = result {
                    eprintln!("cluster {}: {e:#}", stamp.0);
                    failures.insert(stamp.clone());
                    8
                } else {
                    failures.remove(&stamp);
                    30
                };
                next.insert(stamp, Instant::now() + Duration::from_secs(pause));
            }
            while let Some(result) = sessions.try_join_next() {
                let (ticket, result): (String, Result<()>) = result?;
                tickets.remove(&ticket);
                if let Err(e) = result {
                    eprintln!("SSH stream: {e}");
                }
            }
            let mut request = self.request(Hello {
                node: self.cfg.node.clone(),
                instance: self.instance.clone(),
                cursor,
                failures: failures
                    .iter()
                    .take(crate::state::MAX_CLUSTERS)
                    .map(|(id, g, t)| FailedJob {
                        key: Some(Key {
                            cluster: id.clone(),
                            generation: *g,
                        }),
                        task: *t,
                    })
                    .collect(),
            });
            request.set_timeout(Duration::from_secs(12));
            let mut plan = match self.client.clone().poll(request).await {
                Ok(v) => {
                    delay = 1;
                    v.into_inner()
                }
                Err(e) => {
                    eprintln!("node control: {} ({})", e.message(), e.code());
                    connected = false;
                    cursor = 0;
                    sleep(Duration::from_secs(delay)).await;
                    delay = (delay * 2).min(20);
                    continue;
                }
            };
            if !connected {
                state::write_atomic(
                    &self.dir.join("connected"),
                    std::process::id().to_string().as_bytes(),
                )?;
                eprintln!("authenticated to workspace hub as {}", self.cfg.node);
                connected = true;
            }
            cursor = plan.cursor;
            // A slow retired volume must not delay cutover or suppress a newer
            // generation's desired state. Age health checks across busy nodes.
            let job_stamp = |j: &Job| {
                j.key
                    .as_ref()
                    .map(|k| (k.cluster.clone(), k.generation, j.task))
            };
            let current: HashSet<_> = plan.jobs.iter().filter_map(job_stamp).collect();
            next.retain(|stamp, _| current.contains(stamp));
            failures.retain(|stamp| current.contains(stamp));
            plan.jobs.sort_by_key(|j| {
                let checked = job_stamp(j).and_then(|stamp| next.get(&stamp).copied());
                let priority = if j.task == Task::Start as i32 && !j.acknowledge {
                    2
                } else if j.task == Task::Retire as i32 {
                    1
                } else {
                    0
                };
                (priority, checked)
            });
            for j in plan.jobs {
                let Some(k) = j.key.as_ref() else { continue };
                if jobs.len() >= 4
                    || busy.contains(&k.cluster)
                    || job_stamp(&j)
                        .and_then(|stamp| next.get(&stamp))
                        .is_some_and(|at| Instant::now() < *at)
                {
                    continue;
                }
                let id = k.cluster.clone();
                let gen_id = k.generation;
                let task = j.task;
                busy.insert(id.clone());
                let node = self.clone();
                jobs.spawn(async move {
                    let result = timeout(Duration::from_secs(1800), node.job(j))
                        .await
                        .map_err(anyhow::Error::from)
                        .and_then(|r| r);
                    (id, gen_id, task, result)
                });
            }
            for o in plan.sessions {
                if sessions.len() >= 128 || !tickets.insert(o.ticket.clone()) {
                    continue;
                }
                let ticket = o.ticket.clone();
                let node = self.clone();
                sessions.spawn(async move { (ticket, node.session(o).await) });
            }
        }
    }
}
pub async fn run(config: &Path, state_dir: &Path) -> Result<()> {
    let cfg: Config = serde_json::from_slice(&fs::read(config.join("agent.json"))?)?;
    state::name(&cfg.node)?;
    Uuid::parse_str(&cfg.realm)?;
    ensure!(
        cfg.endpoint.starts_with("https://"),
        "agent endpoint must use https"
    );
    ensure!(
        cfg.image.is_empty() || state::image_id(&cfg.image),
        "pin the local workspace image ID"
    );
    ensure!(cfg.host_ssh_port != Some(0), "invalid host SSH port");
    ensure!(
        cfg.network == "none" || state::valid_network(&cfg.network),
        "invalid workspace network"
    );
    state::private_dir(state_dir)?;
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(state_dir.join("agent.lock"))?;
    lock.try_lock()
        .context("another agent owns this state directory")?;
    for entry in fs::read_dir(state_dir)? {
        let entry = entry?;
        if entry.file_type()?.is_file()
            && entry
                .file_name()
                .to_string_lossy()
                .starts_with(".transfer-")
        {
            fs::remove_file(entry.path())?;
        }
    }
    let tls = ClientTlsConfig::new()
        .ca_certificate(Certificate::from_pem(fs::read(config.join("ca.crt"))?))
        .identity(Identity::from_pem(
            fs::read(config.join("node.crt"))?,
            fs::read(config.join("node.key"))?,
        ));
    let channel = Endpoint::from_shared(cfg.endpoint.clone())?
        .tls_config(tls)?
        .connect_timeout(Duration::from_secs(8))
        .http2_keep_alive_interval(Duration::from_secs(15))
        .keep_alive_while_idle(true)
        .connect_lazy();
    Node {
        cfg: Arc::new(cfg),
        dir: state_dir.into(),
        instance: Uuid::new_v4().to_string(),
        client: WorkspaceClient::new(channel).max_decoding_message_size(8 * 1024 * 1024),
    }
    .run()
    .await
}
