use std::collections::BTreeMap;
use std::future::Future;
use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use crate::fleet::{CloudState, InstanceId, Key, Seen};

pub type Error = Box<dyn std::error::Error + Send + Sync>;

pub trait Cloud: Send + Sync + 'static {
    fn launch(&self, key: &Key) -> impl Future<Output = Result<InstanceId, Error>> + Send;
    /// Every instance tagged with this gate's owner, in any state.
    fn list(&self) -> impl Future<Output = Result<Vec<Seen>, Error>> + Send;
    fn terminate(&self, id: &InstanceId) -> impl Future<Output = Result<(), Error>> + Send;
}

pub struct Fake {
    pub boot_delay: Duration,
    pub addr: SocketAddr,
    pub latency: Duration,
    inner: Mutex<FakeInner>,
}

#[derive(Default)]
struct FakeInner {
    down: bool,
    launches: usize,
    instances: BTreeMap<String, FakeInstance>,
}

struct FakeInstance {
    key: Key,
    launched_at: SystemTime,
    terminated: bool,
}

impl Fake {
    pub fn new(addr: SocketAddr, boot_delay: Duration) -> Self {
        Fake { boot_delay, addr, latency: Duration::ZERO, inner: Mutex::default() }
    }

    pub fn set_down(&self, down: bool) {
        self.inner.lock().unwrap().down = down;
    }

    async fn call(&self) -> Result<(), Error> {
        let down = self.inner.lock().unwrap().down;
        tokio::time::sleep(self.latency).await;
        if down { Err("fake ec2: dial tcp: network is unreachable".into()) } else { Ok(()) }
    }

    pub fn adopt(&self, key: Key, launched_at: SystemTime) -> InstanceId {
        let mut inner = self.inner.lock().unwrap();
        let id = format!("i-fake{:04}", inner.instances.len() + 1);
        inner.instances.insert(id.clone(), FakeInstance { key, launched_at, terminated: false });
        InstanceId(id)
    }

    #[cfg(test)]
    pub fn launches(&self) -> usize {
        self.inner.lock().unwrap().launches
    }

    #[cfg(test)]
    pub fn running(&self) -> usize {
        self.inner.lock().unwrap().instances.values().filter(|i| !i.terminated).count()
    }
}

impl Cloud for Fake {
    async fn launch(&self, key: &Key) -> Result<InstanceId, Error> {
        self.call().await?;
        self.inner.lock().unwrap().launches += 1;
        Ok(self.adopt(key.clone(), SystemTime::now()))
    }

    async fn list(&self) -> Result<Vec<Seen>, Error> {
        self.call().await?;
        let inner = self.inner.lock().unwrap();
        Ok(inner
            .instances
            .iter()
            .map(|(id, i)| {
                let booted = i.launched_at.elapsed().unwrap_or_default() >= self.boot_delay;
                let state = match (i.terminated, booted) {
                    (true, _) => CloudState::Terminated,
                    (false, false) => CloudState::Pending,
                    (false, true) => CloudState::Running,
                };
                let addr = (state == CloudState::Running).then_some(self.addr);
                Seen { key: i.key.clone(), id: InstanceId(id.clone()), state, addr, launched_at: i.launched_at }
            })
            .collect())
    }

    async fn terminate(&self, id: &InstanceId) -> Result<(), Error> {
        self.call().await?;
        if let Some(i) = self.inner.lock().unwrap().instances.get_mut(&id.0) {
            i.terminated = true;
        }
        Ok(())
    }
}
