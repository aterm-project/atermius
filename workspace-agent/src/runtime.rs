use crate::{
    state::{self, write_atomic},
    wire::Job,
};
use anyhow::{Context, Result, bail, ensure};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, Command},
    time::{sleep, timeout},
};
pub struct Runtime {
    pub volume: String,
    pub container: String,
    label: String,
    pub image: String,
    network: String,
    state: PathBuf,
    cluster: String,
}
fn cmd() -> Command {
    let mut c = Command::new("docker");
    c.env_remove("DOCKER_CONTEXT")
        .env_remove("DOCKER_HOST")
        .arg("--host=unix:///var/run/docker.sock")
        .kill_on_drop(true);
    c
}
async fn docker(args: &[&str]) -> Result<String> {
    let out = timeout(Duration::from_secs(90), cmd().args(args).output()).await??;
    ensure!(
        out.status.success(),
        "docker {}: {}",
        args[0],
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(String::from_utf8(out.stdout)?.trim().into())
}
impl Runtime {
    pub fn new(
        node: &str,
        realm: &str,
        dir: &Path,
        id: &str,
        vol: u64,
        image: &str,
        network: &str,
    ) -> Result<Self> {
        state::name(id)?;
        ensure!(vol > 0 && state::image_id(image), "invalid volume or image");
        let label = format!("{realm}/{node}/{id}/{vol}");
        let container = format!(
            "atermius-ws-{}",
            &hex::encode(Sha256::digest(label.as_bytes()))[..32]
        );
        Ok(Self {
            volume: format!("{container}-home"),
            container,
            label,
            image: image.into(),
            network: network.into(),
            state: dir.into(),
            cluster: id.into(),
        })
    }
    fn owner(&self) -> String {
        format!("com.atermius.workspace={}", self.label)
    }
    async fn owned(&self, kind: &str, name: &str) -> Result<bool> {
        let out = timeout(
            Duration::from_secs(20),
            cmd()
                .args([kind, "inspect", "--format", "{{json .}}", name])
                .output(),
        )
        .await??;
        if !out.status.success() {
            let msg = String::from_utf8_lossy(&out.stderr).to_lowercase();
            if msg.contains("no such container")
                || msg.contains("no such volume")
                || msg.contains("no such object")
            {
                return Ok(false);
            }
            bail!("docker {kind} inspect: {msg}");
        }
        let meta: serde_json::Value = serde_json::from_slice(&out.stdout)?;
        let labels = if kind == "volume" {
            &meta["Labels"]
        } else {
            &meta["Config"]["Labels"]
        };
        ensure!(
            labels["com.atermius.workspace"].as_str() == Some(&self.label),
            "resource ownership mismatch"
        );
        Ok(true)
    }
    fn fence_file(&self) -> PathBuf {
        self.state.join(format!("{}.fence", self.cluster))
    }
    fn fence_generation(&self) -> Result<u64> {
        match fs::read_to_string(self.fence_file()) {
            Ok(s) => Ok(s.parse()?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
            Err(e) => Err(e.into()),
        }
    }
    pub fn allowed(&self, g: u64) -> Result<()> {
        ensure!(g > self.fence_generation()?, "generation fenced");
        Ok(())
    }
    async fn volume(&self, create: bool) -> Result<()> {
        if self.owned("volume", &self.volume).await? {
            return Ok(());
        }
        ensure!(create, "required workspace volume is missing");
        docker(&["volume", "create", "--label", &self.owner(), &self.volume]).await?;
        ensure!(
            self.owned("volume", &self.volume).await?,
            "volume missing after create"
        );
        Ok(())
    }
    pub async fn start(&self, job: &Job) -> Result<()> {
        let key = job.key.as_ref().context("missing key")?;
        self.allowed(key.generation)?;
        state::validate_keys(&job.authorized_key)?;
        self.volume(job.create).await?;
        if !self.owned("container", &self.container).await? {
            if self.network != "none" {
                let json = docker(&[
                    "network",
                    "inspect",
                    "--format",
                    "{{json .}}",
                    &self.network,
                ])
                .await?;
                let network: serde_json::Value = serde_json::from_str(&json)?;
                ensure!(
                    network["Driver"] == "bridge"
                        && network["Labels"]["com.atermius.workspace.egress"] == "true"
                        && network["Options"]["com.docker.network.bridge.enable_icc"] == "false",
                    "workspace egress network must be a dedicated, labeled bridge with inter-container communication disabled"
                );
            }
            docker(&[
                "run",
                "-d",
                "--pull=never",
                "--restart=no",
                "--name",
                &self.container,
                "--label",
                &self.owner(),
                "--network",
                &self.network,
                "--read-only",
                "--security-opt",
                "no-new-privileges",
                "--cap-drop",
                "ALL",
                "--cap-add",
                "CHOWN",
                "--cap-add",
                "DAC_OVERRIDE",
                "--cap-add",
                "FOWNER",
                "--cap-add",
                "SETUID",
                "--cap-add",
                "SETGID",
                "--cap-add",
                "SYS_CHROOT",
                "--cap-add",
                "KILL",
                "--memory",
                "512m",
                "--cpus",
                "1",
                "--pids-limit",
                "128",
                "--log-opt",
                "max-size=2m",
                "--log-opt",
                "max-file=2",
                "--tmpfs",
                "/tmp:rw,nosuid,nodev,mode=1777,size=64m",
                "--tmpfs",
                "/run:rw,nosuid,nodev,mode=0755,size=8m",
                "--mount",
                &format!("type=volume,src={},dst=/workspace", self.volume),
                "--env",
                &format!("WORKSPACE_AUTHORIZED_KEYS={}", job.authorized_key),
                &self.image,
            ])
            .await?;
        } else if docker(&["inspect", "--format", "{{.State.Running}}", &self.container]).await?
            != "true"
        {
            docker(&["start", &self.container]).await?;
        }
        for _ in 0..20 {
            if docker(&[
                "exec",
                &self.container,
                "test",
                "-s",
                "/run/sshd/workspace.pid",
            ])
            .await
            .is_ok()
            {
                return Ok(());
            }
            sleep(Duration::from_millis(250)).await;
        }
        bail!("workspace sshd did not become ready")
    }
    pub async fn fence(&self, g: u64) -> Result<()> {
        let old = self.fence_generation()?;
        if g > old {
            write_atomic(&self.fence_file(), g.to_string().as_bytes())?;
        }
        if self.owned("container", &self.container).await? {
            docker(&["stop", "--time", "10", &self.container]).await?;
            ensure!(
                docker(&["inspect", "--format", "{{.State.Running}}", &self.container]).await?
                    == "false",
                "workspace still running"
            );
        }
        Ok(())
    }
    async fn remove_container(&self, name: &str) -> Result<()> {
        if self.owned("container", name).await? {
            docker(&["rm", "-f", name]).await?;
        }
        Ok(())
    }
    fn marker(&self) -> PathBuf {
        self.state.join(format!("{}.restored", self.volume))
    }
    pub async fn retire(&self) -> Result<()> {
        self.remove_container(&format!("{}-copy", self.container))
            .await?;
        self.remove_container(&self.container).await?;
        if self.owned("volume", &self.volume).await? {
            docker(&["volume", "rm", &self.volume]).await?;
        }
        match fs::remove_file(self.marker()) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }
    pub fn restored(&self, digest: &str) -> Result<bool> {
        match fs::read_to_string(self.marker()) {
            Ok(s) => {
                ensure!(s == digest, "snapshot identity mismatch");
                Ok(true)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
    async fn copy_process(&self, import: bool) -> Result<Child> {
        let helper = format!("{}-copy", self.container);
        self.remove_container(&helper).await?;
        let mut c = cmd();
        c.args([
            "run",
            "--rm",
            "--name",
            &helper,
            "--label",
            &self.owner(),
            "--pull=never",
            "--network",
            "none",
            "--read-only",
            "--security-opt",
            "no-new-privileges",
            "--cap-drop",
            "ALL",
            "--cap-add",
            "DAC_OVERRIDE",
            "--pids-limit",
            "16",
            "--memory",
            "96m",
        ]);
        let mount = format!(
            "type=volume,src={},dst=/workspace{}",
            self.volume,
            if import { "" } else { ",readonly" }
        );
        c.args(["--mount", &mount]);
        if import {
            c.args([
                "-i",
                "--cap-add",
                "CHOWN",
                "--cap-add",
                "FOWNER",
                "--entrypoint",
                "/bin/sh",
                &self.image,
                "-ec",
                "tar --numeric-owner -xf - -C /workspace && sync -f /workspace",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null());
        } else {
            c.args([
                "--entrypoint",
                "tar",
                &self.image,
                "--numeric-owner",
                "--one-file-system",
                "-cf",
                "-",
                "-C",
                "/workspace",
                ".",
            ])
            .stdout(Stdio::piped())
            .stdin(Stdio::null());
        }
        Ok(c.spawn()?)
    }
    pub async fn export(&self, dest: &Path) -> Result<(String, u64)> {
        self.volume(false).await?;
        let mut proc = self.copy_process(false).await?;
        let mut reader = proc.stdout.take().unwrap();
        let mut f = tokio::fs::File::create(dest).await?;
        let mut hash = Sha256::new();
        let mut size = 0;
        let mut buf = vec![0; crate::hub::CHUNK];
        loop {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            size += n as u64;
            ensure!(
                size <= state::MAX_SNAPSHOT,
                "snapshot exceeds configured transfer ceiling"
            );
            hash.update(&buf[..n]);
            f.write_all(&buf[..n]).await?;
        }
        ensure!(
            proc.wait().await?.success() && size > 0,
            "snapshot export failed"
        );
        f.flush().await?;
        Ok((hex::encode(hash.finalize()), size))
    }
    pub async fn import(&self, path: &Path, digest: &str) -> Result<()> {
        // The generation-specific volume has never been published. Discard a partial import on retry.
        self.retire().await?;
        self.volume(true).await?;
        let mut proc = self.copy_process(true).await?;
        let mut writer = proc.stdin.take().unwrap();
        let mut f = tokio::fs::File::open(path).await?;
        tokio::io::copy(&mut f, &mut writer).await?;
        writer.shutdown().await?;
        drop(writer);
        ensure!(proc.wait().await?.success(), "snapshot extraction failed");
        write_atomic(&self.marker(), digest.as_bytes())
    }
    pub async fn ssh(&self, g: u64) -> Result<Child> {
        self.allowed(g)?;
        ensure!(
            self.owned("container", &self.container).await?,
            "missing workspace"
        );
        Ok(cmd()
            .args([
                "exec",
                "-i",
                "--user",
                "1000:1000",
                &self.container,
                "/usr/bin/socat",
                "STDIO",
                "TCP4:127.0.0.1:2222",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?)
    }
}
