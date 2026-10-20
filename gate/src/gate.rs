use std::collections::HashMap;
use std::fs;
use std::io;
use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Instant, sleep, timeout};

use crate::cloud::Cloud;
use crate::fleet::{CloudState, ConnId, Effect, Event, Key, Seen, State};

pub struct Options {
    pub machines_file: PathBuf,
    pub machines_entry: String,
    pub fleet: crate::fleet::Config,
    pub tick: Duration,
    pub reconcile_every: Duration,
    pub reconcile_while_booting: Duration,
    pub call_timeout: Duration,
}

enum Input {
    Arrival(ConnId, oneshot::Sender<Verdict>),
    Event(Event),
}

enum Verdict {
    Splice(SocketAddr),
    Release,
}

struct Shell<C> {
    opt: Options,
    cloud: Arc<C>,
    tx: mpsc::UnboundedSender<Input>,
}

pub async fn run<C: Cloud>(opt: Options, cloud: Arc<C>, listener: TcpListener) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let shell = Arc::new(Shell { opt, cloud, tx });
    tokio::spawn(accept(listener, shell.tx.clone()));
    let s = shell.clone();
    tokio::spawn(async move {
        let mut every = tokio::time::interval(s.opt.tick);
        loop {
            every.tick().await;
            s.post(Event::Tick);
        }
    });
    let s = shell.clone();
    tokio::spawn(async move {
        let mut every = tokio::time::interval(s.opt.reconcile_every);
        loop {
            every.tick().await;
            s.reconcile().await;
        }
    });
    let mut st = State::new(shell.opt.fleet.clone());
    let mut replies = HashMap::new();
    while let Some(input) = rx.recv().await {
        let event = match input {
            Input::Arrival(conn, reply) => {
                replies.insert(conn.0, reply);
                Event::ConnArrived(conn)
            }
            Input::Event(e) => e,
        };
        for effect in st.step(SystemTime::now(), event) {
            shell.exec(effect, &mut replies);
        }
    }
}

impl<C: Cloud> Shell<C> {
    fn post(&self, ev: Event) {
        let _ = self.tx.send(Input::Event(ev));
    }

    async fn reconcile(&self) -> Option<Vec<Seen>> {
        match timeout(self.opt.call_timeout, self.cloud.list()).await {
            Ok(Ok(seen)) => {
                self.post(Event::Observed(seen.clone()));
                Some(seen)
            }
            Ok(Err(e)) => {
                log!("reconcile failed: {e}");
                self.post(Event::ReconcileFailed);
                None
            }
            Err(_) => {
                log!("reconcile timed out");
                self.post(Event::ReconcileFailed);
                None
            }
        }
    }

    async fn await_running(&self, key: &Key) {
        let deadline = Instant::now() + self.opt.fleet.boot_timeout;
        while Instant::now() < deadline {
            let seen = self.reconcile().await.unwrap_or_default();
            if seen.iter().any(|s| &s.key == key && s.state != CloudState::Pending) {
                return;
            }
            sleep(self.opt.reconcile_while_booting).await;
        }
    }

    fn exec(self: &Arc<Self>, effect: Effect, replies: &mut HashMap<u64, oneshot::Sender<Verdict>>) {
        let mut answer = |conn: ConnId, v| {
            if let Some(reply) = replies.remove(&conn.0) {
                let _ = reply.send(v);
            }
        };
        match effect {
            Effect::Launch(key) => {
                log!("launch {key}");
                let s = self.clone();
                tokio::spawn(async move {
                    match timeout(s.opt.call_timeout, s.cloud.launch(&key)).await {
                        Ok(Ok(id)) => {
                            log!("launched {key} as {id}");
                            s.post(Event::Launched(key.clone(), id));
                            s.await_running(&key).await;
                        }
                        Ok(Err(e)) => {
                            log!("launch {key} failed: {e}");
                            s.post(Event::LaunchFailed(key));
                        }
                        Err(_) => {
                            log!("launch {key} timed out");
                            s.post(Event::LaunchFailed(key));
                        }
                    }
                });
            }
            Effect::Terminate(key, id) => {
                log!("terminate {key} ({id})");
                let s = self.clone();
                tokio::spawn(async move {
                    match timeout(s.opt.call_timeout, s.cloud.terminate(&id)).await {
                        Ok(Ok(())) => {
                            s.reconcile().await;
                        }
                        Ok(Err(e)) => log!("terminate {id} failed, will retry: {e}"),
                        Err(_) => log!("terminate {id} timed out, will retry"),
                    }
                });
            }
            Effect::Splice(conn, addr) => {
                log!("splice connection {} to {addr}", conn.0);
                answer(conn, Verdict::Splice(addr));
            }
            Effect::Release(conn) => {
                log!("release connection {}, nix builds locally", conn.0);
                answer(conn, Verdict::Release);
            }
            Effect::PublishMachines { available } => match self.write_machines(available) {
                Ok(()) => log!("machines file: builder available={available}"),
                Err(e) => log!("machines file: {e}"),
            },
            Effect::Probe(key, addr) => {
                let s = self.clone();
                tokio::spawn(async move {
                    if let Ok(Ok(_)) = timeout(Duration::from_secs(2), TcpStream::connect(addr)).await {
                        log!("probe {key} ok, {addr} is listening");
                        s.post(Event::ProbeOk(key));
                    }
                });
            }
            Effect::SessionEnded { key, id, billed } => {
                log!("session {key} {id} ended, billed {} s", billed.as_secs());
            }
        }
    }

    fn write_machines(&self, available: bool) -> io::Result<()> {
        let path = &self.opt.machines_file;
        let content = if available { format!("{}\n", self.opt.machines_entry) } else { String::new() };
        let dir = path.parent().unwrap_or(".".as_ref());
        fs::create_dir_all(dir)?;
        let tmp = dir.join(format!(".machines-{}", std::process::id()));
        fs::write(&tmp, content)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644))?;
        fs::rename(&tmp, path)
    }
}

async fn accept(listener: TcpListener, tx: mpsc::UnboundedSender<Input>) {
    let mut next = 0;
    loop {
        let conn = match listener.accept().await {
            Ok((conn, _)) => conn,
            Err(e) => {
                log!("accept: {e}");
                continue;
            }
        };
        next += 1;
        let (reply, verdict) = oneshot::channel();
        if tx.send(Input::Arrival(ConnId(next), reply)).is_err() {
            return;
        }
        let tx = tx.clone();
        tokio::spawn(handle(conn, verdict, tx));
    }
}

async fn handle(mut conn: TcpStream, verdict: oneshot::Receiver<Verdict>, tx: mpsc::UnboundedSender<Input>) {
    match verdict.await {
        Err(_) => {}
        Ok(Verdict::Release) => {
            // Closing with the client's unread banner in the buffer would send
            // a reset; a FIN, then draining, closes cleanly.
            let _ = conn.shutdown().await;
            let _ = timeout(Duration::from_secs(2), tokio::io::copy(&mut conn, &mut tokio::io::sink())).await;
        }
        Ok(Verdict::Splice(addr)) => {
            match timeout(Duration::from_secs(10), TcpStream::connect(addr)).await {
                Ok(Ok(mut builder)) => {
                    let _ = tokio::io::copy_bidirectional(&mut conn, &mut builder).await;
                }
                Ok(Err(e)) => log!("dial builder {addr}: {e}"),
                Err(_) => log!("dial builder {addr}: timed out"),
            }
            let _ = tx.send(Input::Event(Event::ConnClosed));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::Fake;
    use crate::fleet::Config;
    use crate::testutil::TempDir;
    use tokio::io::AsyncReadExt;

    const ENTRY: &str = "ssh-ng://nbh@nbh-builder:2222 x86_64-linux /pki/ssh_client 4 1 big-parallel - -";

    async fn echo_server() -> SocketAddr {
        let ln = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = ln.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = ln.accept().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = c.split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                });
            }
        });
        addr
    }

    struct Harness {
        addr: SocketAddr,
        machines: PathBuf,
        fake: Arc<Fake>,
        _dir: TempDir,
    }

    async fn start(fake: Fake, cfg: impl FnOnce(&mut Config), reconcile_every: Duration) -> Harness {
        let mut fleet = Config::new("test".into());
        fleet.idle_grace = Duration::from_millis(1300);
        fleet.probe_every = Duration::from_millis(100);
        fleet.terminate_retry = Duration::from_secs(1);
        cfg(&mut fleet);
        let dir = TempDir::new();
        let machines = dir.path().join("machines");
        let opt = Options {
            machines_file: machines.clone(),
            machines_entry: ENTRY.into(),
            fleet,
            tick: Duration::from_millis(50),
            reconcile_every,
            reconcile_while_booting: Duration::from_millis(50),
            call_timeout: Duration::from_secs(2),
        };
        let ln = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = ln.local_addr().unwrap();
        let fake = Arc::new(fake);
        tokio::spawn(run(opt, fake.clone(), ln));
        Harness { addr, machines, fake, _dir: dir }
    }

    enum Outcome {
        Spliced,
        Reset,
        Closed,
    }

    impl Harness {
        fn fake(&self) -> &Fake {
            &self.fake
        }

        fn machines(&self) -> Option<String> {
            fs::read_to_string(&self.machines).ok()
        }

        async fn attempt(&self) -> (Outcome, Duration, Option<TcpStream>) {
            let t0 = Instant::now();
            let mut c = TcpStream::connect(self.addr).await.unwrap();
            let mut buf = [0; 4];
            let r = timeout(Duration::from_secs(10), async {
                c.write_all(b"ping").await?;
                c.read_exact(&mut buf).await
            })
            .await
            .expect("gate answered within 10 s");
            let took = t0.elapsed();
            match r {
                Ok(_) if &buf == b"ping" => (Outcome::Spliced, took, Some(c)),
                Err(e) if e.kind() == io::ErrorKind::ConnectionReset => (Outcome::Reset, took, None),
                _ => (Outcome::Closed, took, None),
            }
        }
    }

    async fn wait_for(what: &str, limit: Duration, cond: impl Fn() -> bool) -> Duration {
        let t0 = Instant::now();
        while t0.elapsed() < limit {
            if cond() {
                return t0.elapsed();
            }
            sleep(Duration::from_millis(10)).await;
        }
        panic!("timed out after {limit:?} waiting for {what}");
    }

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn entry() -> Option<String> {
        Some(format!("{ENTRY}\n"))
    }

    #[tokio::test]
    async fn cold_start_holds_every_connection_and_splices_its_first_attempt() {
        let h = start(Fake::new(echo_server().await, ms(1500)), |_| {}, ms(200)).await;
        wait_for("machines entry", ms(1000), || h.machines() == entry()).await;
        let (a, b, c) = tokio::join!(h.attempt(), h.attempt(), h.attempt());
        for (outcome, took, _) in [a, b, c] {
            assert!(matches!(outcome, Outcome::Spliced), "first attempt failed after {took:?}");
            assert!(took >= ms(1500), "answered after {took:?}, before the builder booted");
        }
        assert_eq!(h.fake().launches(), 1, "one launch for three concurrent connections");
    }

    #[tokio::test]
    async fn boot_timeout_releases_with_a_fin_and_terminates() {
        let h = start(Fake::new(echo_server().await, Duration::from_secs(3600)), |c| c.boot_timeout = ms(700), ms(200))
            .await;
        let (outcome, took, _) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Closed), "want a FIN, not a splice or a reset");
        assert!(took >= ms(700) && took <= ms(3000), "released after {took:?}");
        wait_for("stuck builder terminated", ms(2000), || h.fake().running() == 0).await;
        assert_eq!(h.machines(), Some(String::new()));
    }

    #[tokio::test]
    async fn cloud_unreachable_empties_machines_and_closes_at_once() {
        let mut fake = Fake::new(echo_server().await, ms(0));
        fake.latency = ms(200);
        fake.set_down(true);
        let h = start(fake, |_| {}, ms(200)).await;
        wait_for("machines emptied", ms(2000), || h.machines() == Some(String::new())).await;
        let (outcome, took, _) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Closed));
        assert!(took < ms(1000), "closed after {took:?}, want under 1 s so nix falls back fast");
        assert_eq!(h.fake().launches(), 0);
    }

    #[tokio::test]
    async fn launch_failure_releases_the_held_connection() {
        let mut fake = Fake::new(echo_server().await, ms(0));
        fake.latency = ms(100);
        let h = start(fake, |_| {}, ms(200)).await;
        wait_for("machines entry", ms(1000), || h.machines() == entry()).await;
        h.fake().set_down(true);
        let (outcome, took, _) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Closed));
        assert!(took < ms(2000), "released after {took:?}");
        wait_for("machines emptied", ms(1000), || h.machines() == Some(String::new())).await;
    }

    #[tokio::test]
    async fn terminates_idle_grace_after_the_last_connection_closes() {
        let h = start(Fake::new(echo_server().await, ms(300)), |_| {}, ms(200)).await;
        let (outcome, _, conn) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Spliced));
        sleep(ms(1500)).await;
        assert_eq!(h.fake().running(), 1, "terminated while a connection was open");
        drop(conn);
        let d = wait_for("builder terminated", ms(5000), || h.fake().running() == 0).await;
        assert!(d >= ms(1300) && d <= ms(2000), "terminated {d:?} after the last close, idle grace 1.3 s");
    }

    #[tokio::test]
    async fn restart_adopts_a_running_builder() {
        let fake = Fake::new(echo_server().await, ms(0));
        fake.adopt(Key("previous-run-7".into()), SystemTime::now() - Duration::from_secs(20 * 60));
        let h = start(fake, |_| {}, ms(200)).await;
        let (outcome, _, conn) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Spliced));
        drop(conn);
        assert_eq!(h.fake().launches(), 0, "launched instead of adopting");
        wait_for("adopted builder terminated when idle", ms(5000), || h.fake().running() == 0).await;
    }

    #[tokio::test]
    async fn cold_start_does_not_wait_for_the_periodic_reconcile() {
        let h = start(Fake::new(echo_server().await, ms(500)), |_| {}, Duration::from_secs(3600)).await;
        wait_for("machines entry", ms(1000), || h.machines() == entry()).await;
        let (outcome, took, _) = h.attempt().await;
        assert!(matches!(outcome, Outcome::Spliced));
        assert!(took < ms(2000), "spliced after {took:?} for a 500 ms boot");
    }
}
