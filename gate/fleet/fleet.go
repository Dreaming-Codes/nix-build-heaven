// Package fleet is the gate's state machine: a pure reducer from events to
// state changes and effects. It does no I/O and reads no clock; the shell in
// package gate executes the effects and feeds results back as events.
package fleet

import (
	"fmt"
	"time"
)

type Phase int

const (
	Gone Phase = iota
	Requested
	Booting
	Serving
	Draining
	Terminating
)

func (p Phase) String() string {
	return [...]string{"Gone", "Requested", "Booting", "Serving", "Draining", "Terminating"}[p]
}

// Key identifies an instance from before EC2 assigns an id. It is written to
// the nbh:key tag at launch so a restarted gate can match what it finds.
type Key string

type ConnID uint64

type Instance struct {
	Key        Key
	Phase      Phase
	InstanceID string
	Addr       string
	Since      time.Time
	LaunchedAt time.Time
	LastBusyAt time.Time
	LastProbe  time.Time
	LastPoll   time.Time
	LastKill   time.Time
}

type Config struct {
	KeyPrefix      string
	MaxInstances   int
	BootTimeout    time.Duration
	IdleGrace      time.Duration
	DrainRecheck   time.Duration
	MaxSession     time.Duration
	UnavailableFor time.Duration
	TerminateRetry time.Duration
	ProbeEvery     time.Duration
	PollEvery      time.Duration
}

func DefaultConfig(prefix string) Config {
	return Config{
		KeyPrefix:      prefix,
		MaxInstances:   1,
		BootTimeout:    150 * time.Second,
		IdleGrace:      60 * time.Second,
		DrainRecheck:   5 * time.Second,
		MaxSession:     3 * time.Hour,
		UnavailableFor: 5 * time.Minute,
		TerminateRetry: 30 * time.Second,
		ProbeEvery:     2 * time.Second,
		PollEvery:      5 * time.Second,
	}
}

type State struct {
	Cfg              Config
	Instances        map[Key]*Instance
	Live             int
	UnavailableUntil time.Time
	Published        *bool
	// Synced is set by the first reconcile result. Until then a launch could
	// duplicate a builder a previous gate process left running.
	Synced   bool
	launches int
}

func New(cfg Config) *State {
	return &State{Cfg: cfg, Instances: map[Key]*Instance{}}
}

// CloudState is the EC2 instance state name as DescribeInstances reports it.
type CloudState string

const (
	Pending      CloudState = "pending"
	Running      CloudState = "running"
	ShuttingDown CloudState = "shutting-down"
	Stopping     CloudState = "stopping"
	Stopped      CloudState = "stopped"
	Terminated   CloudState = "terminated"
)

type Seen struct {
	Key        Key
	InstanceID string
	State      CloudState
	Addr       string
	LaunchedAt time.Time
}

type Load struct{ Clients, Running, Queued int }

func (l Load) Busy() bool { return l.Clients > 0 || l.Running > 0 || l.Queued > 0 }

type Event interface{ event() }

type (
	Tick        struct{}
	ConnArrived struct{ ID ConnID }
	ConnClosed  struct{ ID ConnID }
	Launched    struct {
		Key        Key
		InstanceID string
	}
	LaunchFailed struct {
		Key Key
		Err string
	}
	// Observed is a full snapshot of the instances tagged with this gate's owner.
	Observed        struct{ Instances []Seen }
	ReconcileFailed struct{ Err string }
	ProbeOK         struct{ Key Key }
	LoadSeen        struct {
		Key  Key
		Load Load
	}
)

func (Tick) event()            {}
func (ConnArrived) event()     {}
func (ConnClosed) event()      {}
func (Launched) event()        {}
func (LaunchFailed) event()    {}
func (Observed) event()        {}
func (ReconcileFailed) event() {}
func (ProbeOK) event()         {}
func (LoadSeen) event()        {}

type Effect interface{ effect() }

type (
	Launch    struct{ Key Key }
	Terminate struct {
		Key        Key
		InstanceID string
	}
	Splice struct {
		Conn ConnID
		Addr string
	}
	// Release closes the connection: no builder is coming, Nix builds locally.
	Release struct{ Conn ConnID }
	// Refuse resets the connection while a builder boots. The plugin retries a
	// reset for connect-timeout but gives up at once on a TLS handshake that
	// stalls past its 2 s connect deadline, so the gate must not hold it.
	Refuse          struct{ Conn ConnID }
	PublishMachines struct{ Available bool }
	Probe           struct {
		Key  Key
		Addr string
	}
	PollLoad struct {
		Key  Key
		Addr string
	}
	SessionEnded struct {
		Key        Key
		InstanceID string
		Billed     time.Duration
	}
)

func (Launch) effect()          {}
func (Terminate) effect()       {}
func (Splice) effect()          {}
func (Release) effect()         {}
func (Refuse) effect()          {}
func (PublishMachines) effect() {}
func (Probe) effect()           {}
func (PollLoad) effect()        {}
func (SessionEnded) effect()    {}

func (s *State) Unavailable(now time.Time) bool { return now.Before(s.UnavailableUntil) }

// Step applies one event at time now and returns the effects to execute, in order.
func (s *State) Step(now time.Time, ev Event) []Effect {
	var fx []Effect
	switch e := ev.(type) {
	case Tick:
		for _, in := range s.sorted() {
			fx = append(fx, s.tick(now, in)...)
		}
	case ConnArrived:
		fx = s.arrive(now, e.ID)
	case ConnClosed:
		s.Live--
		for _, in := range s.Instances {
			if in.Phase == Serving || in.Phase == Draining {
				in.LastBusyAt = now
			}
		}
	case Launched:
		if in := s.Instances[e.Key]; in != nil && in.Phase == Requested {
			in.InstanceID = e.InstanceID
			in.LaunchedAt = now
			in.to(Booting, now)
		}
	case LaunchFailed:
		if in := s.Instances[e.Key]; in != nil && in.Phase == Requested {
			in.to(Gone, now)
			s.UnavailableUntil = now.Add(s.Cfg.UnavailableFor)
		}
	case ProbeOK:
		if in := s.Instances[e.Key]; in != nil && in.Phase == Booting {
			in.to(Serving, now)
			in.LastBusyAt = now
		}
	case LoadSeen:
		if in := s.Instances[e.Key]; in != nil && e.Load.Busy() && (in.Phase == Serving || in.Phase == Draining) {
			in.LastBusyAt = now
			in.to(Serving, now)
		}
	case ReconcileFailed:
		s.Synced = true
		if s.active() == 0 {
			s.UnavailableUntil = now.Add(s.Cfg.UnavailableFor)
		}
	case Observed:
		s.Synced = true
		fx = append(fx, s.observe(now, e.Instances)...)
	default:
		panic(fmt.Sprintf("fleet: unknown event %T", ev))
	}
	return append(fx, s.settle(now)...)
}

func (s *State) tick(now time.Time, in *Instance) []Effect {
	if in.Phase != Terminating && !in.LaunchedAt.IsZero() && now.Sub(in.LaunchedAt) >= s.Cfg.MaxSession {
		return s.kill(now, in)
	}
	switch in.Phase {
	case Booting:
		if now.Sub(in.Since) >= s.Cfg.BootTimeout {
			s.UnavailableUntil = now.Add(s.Cfg.UnavailableFor)
			return s.kill(now, in)
		}
		if in.Addr != "" && now.Sub(in.LastProbe) >= s.Cfg.ProbeEvery {
			in.LastProbe = now
			return []Effect{Probe{in.Key, in.Addr}}
		}
	case Serving:
		if s.Live > 0 {
			in.LastBusyAt = now
		}
		if now.Sub(in.LastBusyAt) >= s.Cfg.IdleGrace {
			in.to(Draining, now)
			return nil
		}
		if now.Sub(in.LastPoll) >= s.Cfg.PollEvery {
			in.LastPoll = now
			return []Effect{PollLoad{in.Key, in.Addr}}
		}
	case Draining:
		if s.Live == 0 && now.Sub(in.Since) >= s.Cfg.DrainRecheck {
			return s.kill(now, in)
		}
		if now.Sub(in.LastPoll) >= s.Cfg.PollEvery {
			in.LastPoll = now
			return []Effect{PollLoad{in.Key, in.Addr}}
		}
	case Terminating:
		if now.Sub(in.LastKill) >= s.Cfg.TerminateRetry {
			return s.kill(now, in)
		}
	}
	return nil
}

func (s *State) kill(now time.Time, in *Instance) []Effect {
	if in.InstanceID == "" {
		// A Requested instance has nothing to terminate yet. Its Launched or
		// the next Observed snapshot brings the id and the kill is retried.
		in.to(Terminating, now)
		return nil
	}
	in.to(Terminating, now)
	in.LastKill = now
	return []Effect{Terminate{in.Key, in.InstanceID}}
}

func (s *State) observe(now time.Time, seen []Seen) []Effect {
	var fx []Effect
	present := map[Key]bool{}
	for _, o := range seen {
		present[o.Key] = true
		in := s.Instances[o.Key]
		if in == nil {
			if o.State == Terminated {
				continue
			}
			in = &Instance{Key: o.Key, Since: now, LastBusyAt: now}
			s.Instances[o.Key] = in
		}
		if in.InstanceID == "" {
			in.InstanceID = o.InstanceID
		}
		if in.LaunchedAt.IsZero() {
			in.LaunchedAt = o.LaunchedAt
		}
		in.Addr = o.Addr
		switch o.State {
		case Terminated:
			fx = append(fx, s.gone(now, in)...)
		case Pending, Running:
			if in.Phase == Gone || in.Phase == Requested {
				in.to(Booting, now)
			}
			if in.Phase == Terminating && now.Sub(in.LastKill) >= s.Cfg.TerminateRetry {
				fx = append(fx, s.kill(now, in)...)
			}
		default:
			if in.Phase != Terminating {
				fx = append(fx, s.kill(now, in)...)
			}
		}
	}
	for _, in := range s.sorted() {
		if !present[in.Key] && in.Phase == Terminating && in.InstanceID != "" {
			fx = append(fx, s.gone(now, in)...)
		}
	}
	return fx
}

func (s *State) gone(now time.Time, in *Instance) []Effect {
	if in.Phase == Gone {
		return nil
	}
	in.to(Gone, now)
	if in.LaunchedAt.IsZero() {
		return nil
	}
	return []Effect{SessionEnded{in.Key, in.InstanceID, now.Sub(in.LaunchedAt)}}
}

// arrive routes a new connection. Every connection attempt is demand: the
// plugin retries a refused one every 0.5 to 4 s, so demand needs no memory.
func (s *State) arrive(now time.Time, id ConnID) []Effect {
	if in := s.serving(); in != nil {
		in.to(Serving, now)
		in.LastBusyAt = now
		s.Live++
		return []Effect{Splice{id, in.Addr}}
	}
	if s.Unavailable(now) {
		return []Effect{Release{id}}
	}
	var fx []Effect
	if s.Synced && s.pending() == 0 && len(s.Instances) < s.Cfg.MaxInstances {
		s.launches++
		k := Key(fmt.Sprintf("%s-%d", s.Cfg.KeyPrefix, s.launches))
		s.Instances[k] = &Instance{Key: k, Phase: Requested, Since: now}
		fx = append(fx, Launch{k})
	}
	return append(fx, Refuse{id})
}

// settle derives what follows from the state alone: dropping finished
// instances and what the machines file should say.
func (s *State) settle(now time.Time) []Effect {
	var fx []Effect
	for k, in := range s.Instances {
		if in.Phase == Gone {
			delete(s.Instances, k)
		}
	}
	avail := !s.Unavailable(now)
	if s.Published == nil || *s.Published != avail {
		s.Published = &avail
		fx = append(fx, PublishMachines{avail})
	}
	return fx
}

func (s *State) serving() *Instance {
	for _, in := range s.sorted() {
		if in.Phase == Serving || in.Phase == Draining {
			return in
		}
	}
	return nil
}

func (s *State) pending() int {
	n := 0
	for _, in := range s.Instances {
		if in.Phase == Requested || in.Phase == Booting {
			n++
		}
	}
	return n
}

func (s *State) active() int {
	n := 0
	for _, in := range s.Instances {
		if in.Phase != Gone && in.Phase != Terminating {
			n++
		}
	}
	return n
}

func (s *State) sorted() []*Instance {
	out := make([]*Instance, 0, len(s.Instances))
	for _, in := range s.Instances {
		out = append(out, in)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Key < out[j-1].Key; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func (in *Instance) to(p Phase, now time.Time) {
	if in.Phase != p {
		in.Phase = p
		in.Since = now
	}
}
