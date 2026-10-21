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
    PkiInit {
        dir: PathBuf,
        #[arg(default_value = "nbh-gate")]
        comment: String,
    },
    /// Print builder user-data with a fresh host key and certificate.
    Userdata { dir: PathBuf },
}

#[derive(Clone, Copy, ValueEnum)]
enum Backend {
    Aws,
    Fake,
}

/// EX_CONFIG. The NixOS unit does not restart on it, since a key of the wrong
/// account stays wrong.
const EXIT_WRONG_ACCOUNT: i32 = 78;

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
    /// AWS account the credentials must belong to, checked with STS before
    /// anything launches. Required with --backend aws.
    #[arg(long)]
    aws_account: Option<ec2::AccountId>,
    /// AWS shared credentials file. The only source of AWS credentials: the
    /// environment and ~/.aws are never read. Required with --backend aws.
    #[arg(long)]
    credentials_file: Option<PathBuf>,
    /// Profile in --credentials-file.
    #[arg(long, default_value = "nbh-gate")]
    profile: String,
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
    /// Time with no open connection before the builder is terminated.
    #[arg(long, default_value_t = fleet::Config::IDLE_GRACE.into())]
    idle_grace: humantime::Duration,
    /// Time allowed from launch to serving.
    #[arg(long, default_value_t = fleet::Config::BOOT_TIMEOUT.into())]
    boot_timeout: humantime::Duration,
    /// Hard cap on one builder's lifetime.
    #[arg(long, default_value_t = fleet::Config::MAX_SESSION.into())]
    max_session: humantime::Duration,
}

impl RunArgs {
    fn fleet(&self, key_prefix: String) -> fleet::Config {
        fleet::Config {
            idle_grace: self.idle_grace.into(),
            boot_timeout: self.boot_timeout.into(),
            max_session: self.max_session.into(),
            ..fleet::Config::new(key_prefix)
        }
    }
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
    let fleet = a.fleet(format!("{host}-{started}"));
    let opt = gate::Options {
        machines_file: a.machines_file,
        machines_entry: a.machines_entry,
        fleet,
        tick: Duration::from_secs(1),
        reconcile_every: Duration::from_secs(30),
        reconcile_while_booting: Duration::from_secs(2),
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
                let (Some(expected), Some(file)) = (&a.aws_account, &a.credentials_file) else {
                    return Err("--backend aws needs --aws-account and --credentials-file".into());
                };
                let api = ec2::Api::new(a.region, ec2::Credentials::from_file(file, &a.profile)?);
                match ec2::guard_account(expected, api.caller_account()).await {
                    Ok(account) => log!("aws account {account} matches --aws-account, profile {}", a.profile),
                    Err(e) if e.is::<ec2::WrongAccount>() => {
                        log!("{e}");
                        std::process::exit(EXIT_WRONG_ACCOUNT);
                    }
                    Err(e) => return Err(format!("aws account check: {e}").into()),
                }
                let ec2 = ec2::Ec2 {
                    api,
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
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn run_args(extra: &[&str]) -> RunArgs {
        let argv = ["nbh-gate", "run", "--machines-entry", "e"].iter().chain(extra);
        match Cli::try_parse_from(argv).unwrap() {
            Cli::Run(a) => *a,
            _ => unreachable!(),
        }
    }

    #[test]
    fn unset_timing_flags_keep_the_fleet_defaults() {
        let got = run_args(&[]).fleet("k".into());
        let want = fleet::Config::new("k".into());
        assert_eq!(
            (got.idle_grace, got.boot_timeout, got.max_session),
            (want.idle_grace, want.boot_timeout, want.max_session)
        );
        let set = run_args(&["--idle-grace", "15s"]).fleet("k".into());
        assert_eq!(set.idle_grace, Duration::from_secs(15));
    }

    #[test]
    fn aws_account_is_validated_at_the_cli() {
        assert!(run_args(&["--aws-account", "845087560967"]).aws_account.is_some());
        let argv = ["nbh-gate", "run", "--machines-entry", "e", "--aws-account", "8450875609"];
        assert!(Cli::try_parse_from(argv).is_err());
    }

    #[test]
    fn help_shows_the_fleet_defaults() {
        let mut cli = Cli::command();
        let run = cli.find_subcommand_mut("run").unwrap();
        for (id, want) in [
            ("idle_grace", fleet::Config::IDLE_GRACE),
            ("boot_timeout", fleet::Config::BOOT_TIMEOUT),
            ("max_session", fleet::Config::MAX_SESSION),
        ] {
            let arg = run.get_arguments().find(|a| a.get_id() == id).unwrap();
            let shown = arg.get_default_values()[0].to_str().unwrap();
            assert_eq!(humantime::parse_duration(shown).unwrap(), want, "--{id} help shows {shown}");
        }
    }
}

#[cfg(test)]
mod testutil {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

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
