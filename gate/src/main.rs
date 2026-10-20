//! nbh-gate launches an EC2 Spot builder when the nix-daemon first connects,
//! holds the connection while the builder boots, splices it once the builder
//! serves, and terminates the builder when idle.

macro_rules! log {
    ($($arg:tt)*) => {
        eprintln!("nbh-gate: {} {}", humantime::format_rfc3339_micros(std::time::SystemTime::now()), format_args!($($arg)*))
    };
}

mod cloud;
mod ec2;
mod fleet;
mod gate;
mod pki;

use std::error::Error;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use clap::{Args, Parser, ValueEnum};
use tokio::net::TcpListener;
use tokio::signal::unix::{SignalKind, signal};

#[derive(Parser)]
#[command(version, about)]
enum Cli {
    /// Run the gate.
    Run(Box<RunArgs>),
    /// Create the SSH host CA, the client key and ssh_known_hosts in DIR, once.
    PkiInit { dir: PathBuf, comment: String },
    /// Print builder user-data with a fresh host key and certificate.
    Userdata { dir: PathBuf },
}

#[derive(Clone, Copy, ValueEnum)]
enum Backend {
    Aws,
    Fake,
}

fn duration(s: &str) -> std::result::Result<Duration, humantime::DurationError> {
    humantime::parse_duration(s)
}

#[derive(Args)]
struct RunArgs {
    /// Address the nix-daemon connects to as nbh-builder.
    #[arg(long, default_value = "127.0.0.1:2222")]
    listen: SocketAddr,
    /// Machines file Nix reads through `builders = @FILE`.
    #[arg(long, default_value = "/run/nbh/machines")]
    machines_file: PathBuf,
    /// Machines line written while a builder is available.
    #[arg(long)]
    machines_entry: String,
    #[arg(long, value_enum, default_value = "aws")]
    backend: Backend,
    /// Fake backend: address every fake instance serves on.
    #[arg(long, default_value = "127.0.0.1:22")]
    fake_addr: SocketAddr,
    /// Fake backend: time an instance stays pending.
    #[arg(long, default_value = "75s", value_parser = duration)]
    fake_boot_delay: Duration,
    /// Fake backend: every call fails, like an unreachable region.
    #[arg(long)]
    fake_down: bool,
    #[arg(long, default_value = "eu-north-1")]
    region: String,
    #[arg(long, default_value = "nbh-builder")]
    launch_template: String,
    /// Spot instance types in order of preference.
    #[arg(long, value_delimiter = ',', default_value = "m7a.24xlarge,c7a.24xlarge,c7i.24xlarge")]
    instance_types: Vec<String>,
    /// Spot price cap in $/h. Unset means the on-demand price.
    #[arg(long)]
    max_price: Option<String>,
    /// nbh:owner tag, one gate per owner. Defaults to the host name.
    #[arg(long)]
    owner: Option<String>,
    /// Directory with the SSH host CA that certifies builder host keys.
    #[arg(long, default_value = "/var/lib/nbh-gate/pki")]
    pki: PathBuf,
    #[arg(long, default_value_t = 22)]
    builder_port: u16,
    /// Time with no open connection before the builder is terminated [default: 65s].
    #[arg(long, value_parser = duration)]
    idle_grace: Option<Duration>,
    /// Time allowed from launch to serving [default: 150s].
    #[arg(long, value_parser = duration)]
    boot_timeout: Option<Duration>,
    /// Hard cap on one builder's lifetime [default: 3h].
    #[arg(long, value_parser = duration)]
    max_session: Option<Duration>,
}

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

#[tokio::main]
async fn main() -> Result<()> {
    match Cli::parse() {
        Cli::PkiInit { dir, comment } => pki::Dir(dir).init(&comment),
        Cli::Userdata { dir } => {
            let ud = pki::Dir(dir).authority()?.user_data(SystemTime::now())?;
            println!("{}", String::from_utf8(ud)?);
            Ok(())
        }
        Cli::Run(args) => run(args).await,
    }
}

async fn run(a: Box<RunArgs>) -> Result<()> {
    let a = *a;
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")?.trim().to_string();
    let started = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?.as_secs();
    let mut fleet = fleet::Config::new(format!("{host}-{started}"));
    fleet.idle_grace = a.idle_grace.unwrap_or(fleet.idle_grace);
    fleet.boot_timeout = a.boot_timeout.unwrap_or(fleet.boot_timeout);
    fleet.max_session = a.max_session.unwrap_or(fleet.max_session);
    let opt = gate::Options {
        machines_file: a.machines_file,
        machines_entry: a.machines_entry,
        fleet,
        tick: Duration::from_secs(1),
        reconcile_every: Duration::from_secs(30),
        boot_poll: Duration::from_secs(2),
        call_timeout: Duration::from_secs(20),
    };
    let listener = TcpListener::bind(a.listen).await?;
    let gate = async {
        match a.backend {
            Backend::Fake => {
                let fake = cloud::Fake::new(a.fake_addr, a.fake_boot_delay);
                fake.set_down(a.fake_down);
                gate::run(opt, Arc::new(fake), listener).await;
            }
            Backend::Aws => {
                let ec2 = ec2::Ec2 {
                    api: ec2::Api::new(a.region, ec2::Credentials::from_env()?),
                    launch_template: a.launch_template,
                    instance_types: a.instance_types,
                    owner: a.owner.unwrap_or(host),
                    port: a.builder_port,
                    max_price: a.max_price,
                    authority: pki::Dir(a.pki).authority()?,
                };
                gate::run(opt, Arc::new(ec2), listener).await;
            }
        }
        Ok::<(), Box<dyn Error + Send + Sync>>(())
    };
    let mut term = signal(SignalKind::terminate())?;
    tokio::select! {
        r = gate => r,
        _ = tokio::signal::ctrl_c() => Ok(()),
        _ = term.recv() => Ok(()),
    }
}

#[cfg(test)]
mod testutil {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A directory removed on drop.
    pub struct TempDir(PathBuf);

    impl TempDir {
        pub fn new() -> Self {
            static N: AtomicU32 = AtomicU32::new(0);
            let n = N.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!("nbh-gate-test-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }

        pub fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
