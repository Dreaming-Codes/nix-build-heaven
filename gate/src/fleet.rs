//! A pure reducer from events to effects: no I/O, no clock.

use std::collections::BTreeMap;
use std::fmt;
use std::net::SocketAddr;
use std::time::{Duration, SystemTime};

/// Names an instance before EC2 assigns an id. Written to the `nbh:key` tag at
/// launch so a restarted gate can match what it finds.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Key(pub String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstanceId(pub String);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnId(pub u64);

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Display for InstanceId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub key_prefix: String,
    pub boot_timeout: Duration,
    pub idle_grace: Duration,
    pub max_session: Duration,
    /// How long a failed launch or reconcile keeps the machines file empty.
    pub unavailable_for: Duration,
    pub terminate_retry: Duration,
    pub probe_every: Duration,
}

impl Config {
    pub const BOOT_TIMEOUT: Duration = Duration::from_secs(150);
    pub const IDLE_GRACE: Duration = Duration::from_secs(65);
    pub const MAX_SESSION: Duration = Duration::from_secs(3 * 3600);

    pub fn new(key_prefix: String) -> Self {
        Config {
            key_prefix,
            boot_timeout: Self::BOOT_TIMEOUT,
            idle_grace: Self::IDLE_GRACE,
            max_session: Self::MAX_SESSION,
            unavailable_for: Duration::from_secs(300),
            terminate_retry: Duration::from_secs(30),
            probe_every: Duration::from_secs(2),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloudState {
    Pending,
    Running,
    ShuttingDown,
    Stopping,
    Stopped,
    Terminated,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Seen {
    pub key: Key,
    pub id: InstanceId,
    pub state: CloudState,
    pub addr: Option<SocketAddr>,
    pub launched_at: SystemTime,
}

#[derive(Debug)]
pub enum Event {
    Tick,
    ConnArrived(ConnId),
    ConnClosed,
    Launched(Key, InstanceId),
    LaunchFailed(Key),
    /// A full snapshot of the instances tagged with this gate's owner.
    Observed(Vec<Seen>),
    ReconcileFailed,
    ProbeOk(Key),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Launch(Key),
    Terminate(Key, InstanceId),
    Splice(ConnId, SocketAddr),
    /// Close the connection: no builder is coming and Nix builds locally.
    Release(ConnId),
    PublishMachines {
        available: bool,
    },
    Probe(Key, SocketAddr),
    SessionEnded {
        key: Key,
        id: InstanceId,
        billed: Duration,
    },
}

#[derive(Debug)]
enum Phase {
    Requested,
    Booting { id: InstanceId, addr: Option<SocketAddr>, last_probe: Option<SystemTime> },
    Serving { id: InstanceId, addr: SocketAddr, last_busy: SystemTime },
    Terminating { id: InstanceId, last_kill: SystemTime },
}

#[derive(Debug)]
struct Instance {
    phase: Phase,
    since: SystemTime,
    launched_at: Option<SystemTime>,
}

impl Instance {
    fn to(&mut self, phase: Phase, now: SystemTime) {
        self.phase = phase;
        self.since = now;
    }
}

#[derive(Debug)]
pub struct State {
    cfg: Config,
    instances: BTreeMap<Key, Instance>,
    spliced: usize,
    /// Connections kept open and silent while a builder boots. ssh-ng waits for
    /// the server banner with no deadline and does not retry a reset or a FIN.
    held: Vec<ConnId>,
    unavailable_until: Option<SystemTime>,
    published: Option<bool>,
    /// Until the first reconcile, a launch could duplicate a previous gate's builder.
    synced: bool,
    launches: u64,
}

fn elapsed(now: SystemTime, then: SystemTime) -> Duration {
    now.duration_since(then).unwrap_or_default()
}

impl State {
    pub fn new(cfg: Config) -> Self {
        State {
            cfg,
            instances: BTreeMap::new(),
            spliced: 0,
            held: Vec::new(),
            unavailable_until: None,
            published: None,
            synced: false,
            launches: 0,
        }
    }

    fn unavailable(&self, now: SystemTime) -> bool {
        self.unavailable_until.is_some_and(|t| now < t)
    }

    fn mark_unavailable(&mut self, now: SystemTime) {
        self.unavailable_until = Some(now + self.cfg.unavailable_for);
    }

    pub fn step(&mut self, now: SystemTime, ev: Event) -> Vec<Effect> {
        let mut fx = Vec::new();
        match ev {
            Event::Tick => {
                let keys: Vec<Key> = self.instances.keys().cloned().collect();
                for k in keys {
                    self.tick(now, &k, &mut fx);
                }
            }
            Event::ConnArrived(conn) => self.arrive(now, conn, &mut fx),
            Event::ConnClosed => {
                self.spliced = self.spliced.saturating_sub(1);
                for inst in self.instances.values_mut() {
                    if let Phase::Serving { last_busy, .. } = &mut inst.phase {
                        *last_busy = now;
                    }
                }
            }
            Event::Launched(key, id) => {
                if let Some(inst) = self.instances.get_mut(&key)
                    && matches!(inst.phase, Phase::Requested)
                {
                    inst.launched_at = Some(now);
                    inst.to(Phase::Booting { id, addr: None, last_probe: None }, now);
                }
            }
            Event::LaunchFailed(key) => {
                if self.instances.get(&key).is_some_and(|i| matches!(i.phase, Phase::Requested)) {
                    self.instances.remove(&key);
                    self.mark_unavailable(now);
                }
            }
            Event::ProbeOk(key) => {
                if let Some(inst) = self.instances.get_mut(&key)
                    && let Phase::Booting { id, addr: Some(addr), .. } = &inst.phase
                {
                    let phase = Phase::Serving { id: id.clone(), addr: *addr, last_busy: now };
                    inst.to(phase, now);
                }
            }
            Event::ReconcileFailed => {
                self.synced = true;
                if !self.instances.values().any(|i| !matches!(i.phase, Phase::Terminating { .. })) {
                    self.mark_unavailable(now);
                }
            }
            Event::Observed(seen) => {
                self.synced = true;
                self.observe(now, seen, &mut fx);
            }
        }
        self.settle(now, &mut fx);
        fx
    }

    fn tick(&mut self, now: SystemTime, key: &Key, fx: &mut Vec<Effect>) {
        let cfg = &self.cfg;
        let spliced = self.spliced;
        let inst = self.instances.get_mut(key).expect("tick on a known key");
        let terminating = matches!(inst.phase, Phase::Terminating { .. });
        if !terminating && inst.launched_at.is_some_and(|t| elapsed(now, t) >= cfg.max_session) {
            kill(now, key, inst, fx);
            return;
        }
        match &mut inst.phase {
            Phase::Requested => {}
            Phase::Booting { addr, last_probe, .. } => {
                if elapsed(now, inst.since) >= cfg.boot_timeout {
                    self.unavailable_until = Some(now + cfg.unavailable_for);
                    kill(now, key, inst, fx);
                } else if let Some(addr) = addr
                    && last_probe.is_none_or(|t| elapsed(now, t) >= cfg.probe_every)
                {
                    *last_probe = Some(now);
                    fx.push(Effect::Probe(key.clone(), *addr));
                }
            }
            Phase::Serving { last_busy, .. } => {
                if spliced > 0 {
                    *last_busy = now;
                }
                if elapsed(now, *last_busy) >= cfg.idle_grace {
                    kill(now, key, inst, fx);
                }
            }
            Phase::Terminating { last_kill, .. } => {
                if elapsed(now, *last_kill) >= cfg.terminate_retry {
                    kill(now, key, inst, fx);
                }
            }
        }
    }

    fn observe(&mut self, now: SystemTime, seen: Vec<Seen>, fx: &mut Vec<Effect>) {
        let present: Vec<Key> = seen.iter().map(|s| s.key.clone()).collect();
        for s in seen {
            if s.state == CloudState::Terminated {
                self.gone(now, &s.key, Some(&s), fx);
                continue;
            }
            let inst = self.instances.entry(s.key.clone()).or_insert_with(|| Instance {
                phase: Phase::Requested,
                since: now,
                launched_at: None,
            });
            inst.launched_at.get_or_insert(s.launched_at);
            let running = matches!(s.state, CloudState::Pending | CloudState::Running);
            match &mut inst.phase {
                Phase::Requested if running => {
                    let phase = Phase::Booting { id: s.id, addr: s.addr, last_probe: None };
                    inst.to(phase, now);
                }
                Phase::Requested => {
                    let phase = Phase::Terminating { id: s.id, last_kill: now };
                    inst.to(phase, now);
                    kill(now, &s.key, inst, fx);
                }
                Phase::Booting { addr, .. } if running => *addr = s.addr,
                Phase::Serving { addr, .. } if running => {
                    if let Some(a) = s.addr {
                        *addr = a;
                    }
                }
                Phase::Terminating { last_kill, .. } => {
                    if running && elapsed(now, *last_kill) >= self.cfg.terminate_retry {
                        kill(now, &s.key, inst, fx);
                    }
                }
                Phase::Booting { .. } | Phase::Serving { .. } => kill(now, &s.key, inst, fx),
            }
        }
        let vanished: Vec<Key> = self
            .instances
            .iter()
            .filter(|(k, i)| matches!(i.phase, Phase::Terminating { .. }) && !present.contains(k))
            .map(|(k, _)| k.clone())
            .collect();
        for k in vanished {
            self.gone(now, &k, None, fx);
        }
    }

    /// Forgets an instance. `seen` fills in what a Requested one never learned.
    fn gone(&mut self, now: SystemTime, key: &Key, seen: Option<&Seen>, fx: &mut Vec<Effect>) {
        let Some(inst) = self.instances.remove(key) else { return };
        let id = match inst.phase {
            Phase::Booting { id, .. } | Phase::Serving { id, .. } | Phase::Terminating { id, .. } => Some(id),
            Phase::Requested => seen.map(|s| s.id.clone()),
        };
        let launched_at = inst.launched_at.or(seen.map(|s| s.launched_at));
        if let (Some(id), Some(t)) = (id, launched_at) {
            fx.push(Effect::SessionEnded { key: key.clone(), id, billed: elapsed(now, t) });
        }
    }

    /// The serving builder's address, marking it busy now.
    fn use_serving(&mut self, now: SystemTime) -> Option<SocketAddr> {
        self.instances.values_mut().find_map(|i| match &mut i.phase {
            Phase::Serving { addr, last_busy, .. } => {
                *last_busy = now;
                Some(*addr)
            }
            _ => None,
        })
    }

    fn arrive(&mut self, now: SystemTime, conn: ConnId, fx: &mut Vec<Effect>) {
        if let Some(addr) = self.use_serving(now) {
            self.spliced += 1;
            fx.push(Effect::Splice(conn, addr));
        } else if self.unavailable(now) {
            fx.push(Effect::Release(conn));
        } else {
            self.held.push(conn);
        }
    }

    fn settle_held(&mut self, now: SystemTime, fx: &mut Vec<Effect>) {
        if self.held.is_empty() {
            return;
        }
        if let Some(addr) = self.use_serving(now) {
            for conn in self.held.drain(..) {
                self.spliced += 1;
                fx.push(Effect::Splice(conn, addr));
            }
        } else if self.unavailable(now) {
            fx.extend(self.held.drain(..).map(Effect::Release));
        } else if self.synced && self.instances.is_empty() {
            self.launches += 1;
            let key = Key(format!("{}-{}", self.cfg.key_prefix, self.launches));
            self.instances.insert(key.clone(), Instance { phase: Phase::Requested, since: now, launched_at: None });
            fx.push(Effect::Launch(key));
        }
    }

    fn settle(&mut self, now: SystemTime, fx: &mut Vec<Effect>) {
        self.settle_held(now, fx);
        let available = !self.unavailable(now);
        if self.published != Some(available) {
            self.published = Some(available);
            fx.push(Effect::PublishMachines { available });
        }
    }
}

fn kill(now: SystemTime, key: &Key, inst: &mut Instance, fx: &mut Vec<Effect>) {
    let id = match &inst.phase {
        Phase::Requested => return,
        Phase::Booting { id, .. } | Phase::Serving { id, .. } | Phase::Terminating { id, .. } => id.clone(),
    };
    fx.push(Effect::Terminate(key.clone(), id.clone()));
    if let Phase::Terminating { last_kill, .. } = &mut inst.phase {
        *last_kill = now;
    } else {
        inst.to(Phase::Terminating { id, last_kill: now }, now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use CloudState::*;
    use Effect::*;

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000 + secs)
    }

    fn before(secs: u64) -> SystemTime {
        at(0) - Duration::from_secs(secs)
    }

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn key(k: &str) -> Key {
        Key(k.into())
    }

    fn id(i: &str) -> InstanceId {
        InstanceId(i.into())
    }

    fn addr(a: &str) -> SocketAddr {
        a.parse().unwrap()
    }

    const ADDR: &str = "10.0.0.1:22";

    fn seen(k: &str, i: &str, state: CloudState, launched_at: SystemTime) -> Seen {
        let addr = matches!(state, Running).then(|| addr(ADDR));
        Seen { key: key(k), id: id(i), state, addr, launched_at }
    }

    fn launch(k: &str) -> Effect {
        Launch(key(k))
    }

    fn terminate(k: &str, i: &str) -> Effect {
        Terminate(key(k), id(i))
    }

    fn splice(c: u64) -> Effect {
        Splice(ConnId(c), addr(ADDR))
    }

    fn ended(k: &str, i: &str, billed: Duration) -> Effect {
        SessionEnded { key: key(k), id: id(i), billed }
    }

    const MACHINES_ON: Effect = PublishMachines { available: true };
    const MACHINES_OFF: Effect = PublishMachines { available: false };

    fn synced() -> State {
        let mut st = State::new(Config::new("desk".into()));
        assert_eq!(st.step(at(0), Event::Observed(vec![])), vec![MACHINES_ON]);
        st
    }

    fn requested() -> State {
        let mut st = synced();
        assert_eq!(st.step(at(0), Event::ConnArrived(ConnId(1))), vec![launch("desk-1")]);
        st
    }

    fn booting() -> State {
        let mut st = synced();
        st.step(at(0), Event::Observed(vec![seen("desk-1", "i-1", Running, at(0))]));
        st
    }

    fn serving() -> State {
        let mut st = booting();
        assert_eq!(st.step(at(0), Event::ProbeOk(key("desk-1"))), vec![]);
        st
    }

    fn terminating() -> State {
        let mut st = serving();
        let fx = st.step(at(0), Event::Observed(vec![seen("desk-1", "i-1", ShuttingDown, at(0))]));
        assert_eq!(fx, vec![terminate("desk-1", "i-1")]);
        st
    }

    #[test]
    fn demand_with_nothing_running_launches_and_holds() {
        assert_eq!(synced().step(at(0), Event::ConnArrived(ConnId(1))), vec![launch("desk-1")]);
    }

    #[test]
    fn demand_while_unavailable_releases_without_launch() {
        let mut st = synced();
        assert_eq!(st.step(at(0), Event::ReconcileFailed), vec![MACHINES_OFF]);
        assert_eq!(st.step(at(1), Event::ConnArrived(ConnId(1))), vec![Release(ConnId(1))]);
    }

    #[test]
    fn second_demand_while_requested_or_booting_does_not_launch_again() {
        let mut st = requested();
        assert_eq!(st.step(at(1), Event::ConnArrived(ConnId(2))), vec![]);
        st.step(at(2), Event::Launched(key("desk-1"), id("i-9")));
        assert_eq!(st.step(at(3), Event::ConnArrived(ConnId(3))), vec![]);
    }

    #[test]
    fn launch_failure_releases_held_and_empties_machines() {
        let fx = requested().step(at(3), Event::LaunchFailed(key("desk-1")));
        assert_eq!(fx, vec![Release(ConnId(1)), MACHINES_OFF]);
    }

    #[test]
    fn booting_with_an_address_is_probed_every_probe_interval() {
        let mut st = booting();
        assert_eq!(st.step(at(0), Event::Tick), vec![Probe(key("desk-1"), addr(ADDR))]);
        assert_eq!(st.step(at(1), Event::Tick), vec![]);
        assert_eq!(st.step(at(2), Event::Tick), vec![Probe(key("desk-1"), addr(ADDR))]);
    }

    #[test]
    fn booting_without_an_address_is_not_probed() {
        let mut st = requested();
        st.step(at(1), Event::Launched(key("desk-1"), id("i-1")));
        assert_eq!(st.step(at(5), Event::Tick), vec![]);
    }

    #[test]
    fn probe_ok_splices_every_held_connection_once() {
        let mut st = requested();
        assert_eq!(st.step(at(2), Event::ConnArrived(ConnId(2))), vec![]);
        st.step(at(3), Event::Launched(key("desk-1"), id("i-1")));
        st.step(at(4), Event::Observed(vec![seen("desk-1", "i-1", Running, at(3))]));
        assert_eq!(st.step(at(30), Event::ProbeOk(key("desk-1"))), vec![splice(1), splice(2)]);
        assert_eq!(st.spliced, 2);
        assert_eq!(st.step(at(31), Event::ConnArrived(ConnId(3))), vec![splice(3)]);
    }

    #[test]
    fn boot_timeout_terminates_releases_and_empties_machines() {
        let mut st = requested();
        st.step(at(1), Event::Launched(key("desk-1"), id("i-1")));
        let fx = st.step(at(1) + st.cfg.boot_timeout, Event::Tick);
        assert_eq!(fx, vec![terminate("desk-1", "i-1"), Release(ConnId(1)), MACHINES_OFF]);
    }

    #[test]
    fn boot_timeout_counts_from_booting_not_launch() {
        let mut st = synced();
        st.step(at(0), Event::Observed(vec![seen("desk-1", "i-1", Pending, before(3600))]));
        assert_eq!(st.step(at(149), Event::Tick), vec![]);
        assert_eq!(st.step(at(150), Event::Tick)[0], terminate("desk-1", "i-1"));
    }

    #[test]
    fn serving_splices_new_connections_at_once() {
        let mut st = serving();
        assert_eq!(st.step(at(10), Event::ConnArrived(ConnId(7))), vec![splice(7)]);
        assert_eq!(st.spliced, 1);
    }

    #[test]
    fn serving_idle_for_idle_grace_terminates() {
        let mut st = serving();
        assert_eq!(st.step(at(64), Event::Tick), vec![]);
        assert_eq!(st.step(at(65), Event::Tick), vec![terminate("desk-1", "i-1")]);
    }

    #[test]
    fn serving_with_an_open_connection_never_idles() {
        let mut st = serving();
        st.step(at(1), Event::ConnArrived(ConnId(1)));
        assert_eq!(st.step(at(600), Event::Tick), vec![]);
    }

    #[test]
    fn idle_grace_runs_from_the_last_close() {
        let mut st = serving();
        st.step(at(1), Event::ConnArrived(ConnId(1)));
        st.step(at(1), Event::ConnArrived(ConnId(2)));
        st.step(at(20), Event::ConnClosed);
        assert_eq!(st.spliced, 1);
        st.step(at(100), Event::ConnClosed);
        let killed = (101..300).find(|&d| !st.step(at(d), Event::Tick).is_empty());
        assert_eq!(killed, Some(165));
    }

    #[test]
    fn spot_interruption_terminates_then_ends_the_session() {
        let mut st = serving();
        let fx = st.step(at(30), Event::Observed(vec![seen("desk-1", "i-1", ShuttingDown, at(0))]));
        assert_eq!(fx, vec![terminate("desk-1", "i-1")]);
        let fx = st.step(at(40), Event::Observed(vec![seen("desk-1", "i-1", Terminated, at(0))]));
        assert_eq!(fx, vec![ended("desk-1", "i-1", secs(40))]);
    }

    #[test]
    fn serving_instance_seen_terminated_ends_the_session() {
        let fx = serving().step(at(30), Event::Observed(vec![seen("desk-1", "i-1", Terminated, at(0))]));
        assert_eq!(fx, vec![ended("desk-1", "i-1", secs(30))]);
    }

    #[test]
    fn terminating_retries_after_the_retry_interval() {
        let mut st = terminating();
        assert_eq!(st.step(at(29), Event::Tick), vec![]);
        assert_eq!(st.step(at(30), Event::Tick), vec![terminate("desk-1", "i-1")]);
    }

    #[test]
    fn terminating_instance_that_vanished_ends_the_session() {
        assert_eq!(terminating().step(at(40), Event::Observed(vec![])), vec![ended("desk-1", "i-1", secs(40))]);
    }

    #[test]
    fn max_session_terminates_even_while_busy() {
        let mut st = serving();
        st.step(at(1), Event::ConnArrived(ConnId(1)));
        assert_eq!(st.step(at(3 * 3600 - 1), Event::Tick), vec![]);
        assert_eq!(st.step(at(3 * 3600), Event::Tick), vec![terminate("desk-1", "i-1")]);
    }

    #[test]
    fn tagged_instance_seen_before_launched_returns_boots() {
        let mut st = requested();
        st.step(at(2), Event::Observed(vec![seen("desk-1", "i-5", Running, at(1))]));
        assert_eq!(st.step(at(2), Event::Tick), vec![Probe(key("desk-1"), addr(ADDR))]);
        assert_eq!(st.step(at(3), Event::Launched(key("desk-1"), id("i-5"))), vec![]);
        assert_eq!(st.step(at(4), Event::ProbeOk(key("desk-1"))), vec![splice(1)]);
    }

    #[test]
    fn reconcile_failure_while_serving_keeps_machines_on() {
        let mut st = serving();
        assert_eq!(st.step(at(1), Event::ReconcileFailed), vec![]);
        assert_eq!(st.step(at(2), Event::ConnArrived(ConnId(1))), vec![splice(1)]);
    }

    #[test]
    fn machines_come_back_when_unavailability_expires() {
        let mut st = synced();
        st.step(at(0), Event::ReconcileFailed);
        assert_eq!(st.step(at(299), Event::Tick), vec![]);
        assert_eq!(st.step(at(300), Event::Tick), vec![MACHINES_ON]);
    }

    #[test]
    fn first_event_publishes_machines() {
        let mut st = State::new(Config::new("desk".into()));
        assert_eq!(st.step(at(0), Event::Tick), vec![MACHINES_ON]);
    }

    #[test]
    fn no_launch_before_first_reconcile() {
        let mut st = State::new(Config::new("desk".into()));
        assert_eq!(st.step(at(0), Event::ConnArrived(ConnId(1))), vec![MACHINES_ON]);
        assert_eq!(st.step(at(1), Event::Observed(vec![])), vec![launch("desk-1")]);
    }

    #[test]
    fn restart_adopts_running_kills_stopped_and_skips_terminated() {
        let mut st = State::new(Config::new("desk".into()));
        let old = before(20 * 60);
        let fx = st.step(
            at(0),
            Event::Observed(vec![
                seen("desk-old-3", "i-3", Running, old),
                seen("desk-old-2", "i-2", Terminated, old),
                seen("desk-old-4", "i-4", Stopped, old),
            ]),
        );
        assert_eq!(fx, vec![terminate("desk-old-4", "i-4"), MACHINES_ON]);
        assert!(!st.instances.contains_key(&key("desk-old-2")));
        let probe = Probe(key("desk-old-3"), addr(ADDR));
        assert_eq!(st.step(at(2), Event::Tick), vec![probe], "probed, not killed for its age");
        st.step(at(3), Event::ProbeOk(key("desk-old-3")));
        assert_eq!(st.step(at(4), Event::ConnArrived(ConnId(1))), vec![splice(1)]);
    }

    #[test]
    fn reconcile_is_idempotent() {
        let snap = || Event::Observed(vec![seen("desk-1", "i-1", Running, at(0))]);
        let mut a = State::new(Config::new("desk".into()));
        a.step(at(0), snap());
        let mut b = State::new(Config::new("desk".into()));
        b.step(at(0), snap());
        b.step(at(0), snap());
        assert_eq!(format!("{:?}", a.instances), format!("{:?}", b.instances));
    }

    #[test]
    fn demand_while_previous_terminates_launches_once_it_is_gone() {
        let mut st = terminating();
        assert_eq!(st.step(at(1), Event::ConnArrived(ConnId(1))), vec![]);
        let fx = st.step(at(2), Event::Observed(vec![]));
        assert_eq!(fx, vec![ended("desk-1", "i-1", secs(2)), launch("desk-1")]);
    }
}
