//! Bounded local IPC between the authenticated Server Admin API and its Workspace Hub.
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_COMMAND: usize = 32 * 1024;
pub const MAX_REPLY: usize = 512 * 1024;
pub const PROTOCOL: u8 = 1;

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub enum Phase {
    Provisioning,
    Running,
    Snapshot,
    Restore,
    Fence,
    Resume,
}
pub fn name(s: &str) -> Result<()> {
    ensure!(
        !s.is_empty()
            && s.len() <= 40
            && s.as_bytes()[0].is_ascii_lowercase()
            && s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
        "invalid node or cluster name"
    );
    Ok(())
}
pub fn valid_network(s: &str) -> bool {
    name(s).is_ok() && !matches!(s, "host" | "bridge" | "none" | "default")
}
pub fn sha(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn image_id(s: &str) -> bool {
    s.strip_prefix("sha256:").is_some_and(sha)
}
pub fn validate_keys(s: &str) -> Result<()> {
    ensure!(
        !s.is_empty() && s.len() <= 16384 && s.lines().count() <= 32,
        "supply 1 to 32 SSH public keys"
    );
    for line in s.lines() {
        let mut words = line.split_ascii_whitespace();
        let alg = words.next().unwrap_or("");
        let key = words.next().unwrap_or("");
        ensure!(
            matches!(
                alg,
                "ssh-ed25519" | "ssh-rsa" | "ecdsa-sha2-nistp256" | "sk-ssh-ed25519@openssh.com"
            ) && key.len() >= 32
                && key
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
                && !line.chars().any(char::is_control),
            "invalid public key"
        );
        use base64::Engine as _;
        let blob = base64::engine::general_purpose::STANDARD
            .decode(key)
            .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(key))?;
        let mut fields = blob.as_slice();
        let mut field = || -> Result<&[u8]> {
            let (len, rest) = fields
                .split_at_checked(4)
                .ok_or_else(|| anyhow::anyhow!("invalid SSH key"))?;
            let len = u32::from_be_bytes(len.try_into()?) as usize;
            let (value, tail) = rest
                .split_at_checked(len)
                .ok_or_else(|| anyhow::anyhow!("invalid SSH key"))?;
            fields = tail;
            Ok(value)
        };
        ensure!(field()? == alg.as_bytes(), "SSH key algorithm mismatch");
        match alg {
            "ssh-ed25519" => ensure!(field()?.len() == 32, "invalid Ed25519 key"),
            "ssh-rsa" => ensure!(
                !field()?.is_empty() && !field()?.is_empty(),
                "invalid RSA key"
            ),
            "ecdsa-sha2-nistp256" => ensure!(
                field()? == b"nistp256" && !field()?.is_empty(),
                "invalid ECDSA key"
            ),
            _ => ensure!(
                field()?.len() == 32 && !field()?.is_empty(),
                "invalid security key"
            ),
        }
        ensure!(fields.is_empty(), "unexpected SSH key data");
    }
    Ok(())
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitialWorkspace {
    pub cluster: String,
    pub port: u16,
    pub authorized_keys: String,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub node: String,
    pub fingerprint: String,
    #[serde(default)]
    pub image: String,
    pub network: String,
    pub host_ssh: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_workspace: Option<InitialWorkspace>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    RegisterNode {
        registration: Registration,
    },
    SetNodeEnabled {
        node: String,
        enabled: bool,
        expected_revision: u64,
    },
    CreateWorkspace {
        cluster: String,
        node: String,
        port: u16,
        authorized_keys: String,
    },
    PublishHost {
        cluster: String,
        node: String,
        port: u16,
    },
    Migrate {
        cluster: String,
        destination: String,
        expected_generation: u64,
    },
    Abort {
        cluster: String,
        expected_generation: u64,
    },
}
impl Command {
    pub fn resource(&self) -> (&'static str, &str, &'static str) {
        match self {
            Self::RegisterNode { registration } => {
                ("workspace_node", &registration.node, "register")
            }
            Self::SetNodeEnabled { node, enabled, .. } => (
                "workspace_node",
                node,
                if *enabled { "enable" } else { "disable" },
            ),
            Self::CreateWorkspace { cluster, .. } => ("workspace_cluster", cluster, "create"),
            Self::PublishHost { cluster, .. } => ("workspace_cluster", cluster, "publish_host"),
            Self::Migrate { cluster, .. } => ("workspace_cluster", cluster, "migrate"),
            Self::Abort { cluster, .. } => ("workspace_cluster", cluster, "abort"),
        }
    }
    pub fn validate(&self) -> Result<()> {
        name(self.resource().1)?;
        match self {
            Self::RegisterNode { registration: r } => {
                ensure!(
                    sha(&r.fingerprint) && (r.image.is_empty() || image_id(&r.image)),
                    "invalid node identity or image"
                );
                ensure!(
                    r.network == "none" || valid_network(&r.network),
                    "invalid network"
                );
                ensure!(
                    r.host_ssh || !r.image.is_empty(),
                    "select at least one capability"
                );
                if let Some(initial) = &r.initial_workspace {
                    name(&initial.cluster)?;
                    ensure!(
                        !r.image.is_empty() && initial.port >= 1024,
                        "invalid initial workspace"
                    );
                    validate_keys(initial.authorized_keys.trim())?;
                }
            }
            Self::SetNodeEnabled {
                expected_revision, ..
            } => ensure!(*expected_revision > 0, "invalid revision"),
            Self::CreateWorkspace {
                node,
                port,
                authorized_keys,
                ..
            } => {
                name(node)?;
                ensure!(*port >= 1024, "invalid port");
                validate_keys(authorized_keys.trim())?;
            }
            Self::PublishHost { node, port, .. } => {
                name(node)?;
                ensure!(*port >= 1024, "invalid port");
            }
            Self::Migrate {
                destination,
                expected_generation,
                ..
            } => {
                name(destination)?;
                ensure!(*expected_generation > 0, "invalid generation");
            }
            Self::Abort {
                expected_generation,
                ..
            } => ensure!(*expected_generation > 0, "invalid generation"),
        }
        Ok(())
    }
}
#[derive(Debug, Serialize, Deserialize)]
pub struct NodeStatus {
    pub name: String,
    pub enabled: bool,
    pub revision: u64,
    pub online: bool,
    pub last_seen_seconds_ago: Option<u64>,
    pub network: String,
    pub host_ssh: bool,
    pub image: String,
    pub fingerprint: String,
}
#[derive(Debug, Serialize, Deserialize)]
pub struct ClusterStatus {
    pub cluster: String,
    pub node: String,
    pub target: Option<String>,
    pub phase: Phase,
    pub generation: u64,
    pub volume_generation: u64,
    pub port: u16,
    pub pending_cleanup: usize,
    #[serde(rename = "type")]
    pub kind: String,
    pub snapshot_bytes: Option<u64>,
    pub transfer: Option<TransferStatus>,
    pub retrying_on: Option<String>,
}
#[derive(Debug, Serialize, Deserialize)]
pub struct TransferStatus {
    pub bytes: u64,
    pub total: u64,
}
#[derive(Default, Debug, Serialize, Deserialize)]
pub struct Overview {
    pub nodes: Vec<NodeStatus>,
    pub clusters: Vec<ClusterStatus>,
}
#[derive(Serialize, Deserialize)]
pub struct Request {
    pub version: u8,
    pub command: Option<Command>,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum Reply {
    Status {
        overview: Overview,
        ssh_host: String,
    },
    Accepted,
    Invalid,
    Conflict,
    Unavailable,
}

pub async fn send<T: Serialize>(
    stream: &mut (impl AsyncWrite + Unpin),
    value: &T,
    limit: usize,
) -> Result<()> {
    let data = serde_json::to_vec(value)?;
    ensure!(data.len() <= limit, "oversized workspace message");
    stream.write_u32(data.len().try_into()?).await?;
    stream.write_all(&data).await?;
    stream.flush().await?;
    Ok(())
}
pub async fn receive<T: serde::de::DeserializeOwned>(
    stream: &mut (impl AsyncRead + Unpin),
    limit: usize,
) -> Result<T> {
    let len = stream.read_u32().await? as usize;
    ensure!(len > 0 && len <= limit, "invalid workspace frame");
    let mut data = vec![0; len];
    stream.read_exact(&mut data).await?;
    Ok(serde_json::from_slice(&data)?)
}
