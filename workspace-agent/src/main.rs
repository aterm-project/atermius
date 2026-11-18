mod wire {
    tonic::include_proto!("atermius.workspace.v1");
}
mod admin;
mod hub;
mod node;
mod runtime;
mod state;
use anyhow::{Context, Result, bail};
use state::{Node, Store};
use std::{env, fs, path::Path};

const HELP: &str = "atermius-agent hub STATE MTLS_LISTEN SSH_BIND_IP
atermius-agent run CONFIG_DIR LOCAL_STATE
atermius-agent register STATE NODE CERT_SHA256 IMAGE_ID|- NETWORK HOST_SSH_BOOL [CLUSTER PORT KEYS_FILE]
atermius-agent disable|enable STATE NODE
atermius-agent create STATE CLUSTER NODE STABLE_SSH_PORT PUBLIC_KEYS_FILE
atermius-agent publish-host STATE NAME NODE STABLE_SSH_PORT
atermius-agent migrate STATE CLUSTER DESTINATION_NODE
atermius-agent abort STATE CLUSTER
atermius-agent status STATE
atermius-agent check-registration FILE";
#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    if a.is_empty() || a == ["--help"] {
        println!("{HELP}");
        return Ok(());
    }
    let path = Path::new(*a.get(1).context("missing state/config directory")?);
    let store = Store(path.into());
    match a.as_slice() {
        ["check-registration", _] => {
            use atermius_workspace_admin::{Command, MAX_COMMAND, Registration};
            anyhow::ensure!(
                fs::metadata(path)?.len() <= MAX_COMMAND as u64,
                "descriptor too large"
            );
            let registration: Registration = serde_json::from_slice(&fs::read(path)?)?;
            Command::RegisterNode { registration }.validate()?;
        }
        ["hub", _, addr, access] => hub::serve(path, addr.parse()?, access.parse()?).await?,
        ["run", _, dir] => node::run(path, Path::new(dir)).await?,
        ["register", _, id, fp, image, network, host, rest @ ..] => {
            let node = Node {
                enabled: true,
                revision: 1,
                fingerprint: fp.to_string(),
                host_ssh: host.parse()?,
                network: network.to_string(),
                image: if *image == "-" {
                    String::new()
                } else {
                    image.to_string()
                },
            };
            let initial = match rest {
                [] => None,
                [cluster, port, file] => Some((*cluster, port.parse()?, fs::read_to_string(file)?)),
                _ => bail!("{HELP}"),
            };
            store.update(|s| {
                s.register(id, node)?;
                if let Some((cluster, port, keys)) = initial {
                    s.create(cluster, id, port, keys.trim(), false)?;
                }
                Ok(())
            })?;
        }
        [op @ ("disable" | "enable"), _, id] => {
            store.update(|s| s.set_enabled(id, *op == "enable", None))?
        }
        ["create", _, id, node, port, file] => {
            let keys = fs::read_to_string(file)?;
            store.update(|s| s.create(id, node, port.parse()?, keys.trim(), false))?;
        }
        ["publish-host", _, id, node, port] => {
            store.update(|s| s.create(id, node, port.parse()?, "", true))?
        }
        ["migrate", _, id, to] => store.update(|s| s.migrate(id, to))?,
        ["abort", _, id] => store.update(|s| s.abort(id))?,
        ["status", _] => println!("{}", serde_json::to_string_pretty(&store.overview()?)?),
        _ => bail!("{HELP}"),
    }
    Ok(())
}
