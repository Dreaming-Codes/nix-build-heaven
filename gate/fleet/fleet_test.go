package fleet

import (
	"reflect"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 20, 3, 0, 0, 0, time.UTC)

func at(d time.Duration) time.Time { return t0.Add(d) }

const s = time.Second

func cfg() Config { return DefaultConfig("desk") }

func with(phase Phase, mut ...func(*Instance)) func(*State) {
	return func(st *State) {
		in := &Instance{Key: "desk-1", Phase: phase, InstanceID: "i-1", Addr: "10.0.0.1:50051", Since: t0, LaunchedAt: t0, LastBusyAt: t0}
		if phase == Requested {
			in.InstanceID, in.Addr, in.LaunchedAt = "", "", time.Time{}
		}
		for _, m := range mut {
			m(in)
		}
		st.Instances[in.Key] = in
		st.launches = 1
	}
}

func published(v bool) func(*State) { return func(st *State) { st.Published = &v } }
func live(n int) func(*State)       { return func(st *State) { st.Live = n } }
func unavailableUntil(t time.Time) func(*State) {
	return func(st *State) { st.UnavailableUntil = t }
}

type want struct {
	phase   Phase // of desk-1, Gone if absent
	effects []Effect
	live    int
	unavail bool
}

func TestTransitions(t *testing.T) {
	cases := []struct {
		name  string
		setup []func(*State)
		now   time.Time
		ev    Event
		want  want
	}{
		{"Gone, demand: launch and refuse", []func(*State){published(true)}, at(0), ConnArrived{1},
			want{phase: Requested, effects: []Effect{Launch{"desk-1"}, Refuse{1}}}},
		{"Gone, demand while unavailable: release, no launch", []func(*State){published(false), unavailableUntil(at(60 * s))}, at(0), ConnArrived{1},
			want{phase: Gone, effects: []Effect{Release{1}}, unavail: true}},
		{"Gone, demand at capacity (previous still terminating): refuse, no launch", []func(*State){published(true), with(Terminating)}, at(0), ConnArrived{1},
			want{phase: Terminating, effects: []Effect{Refuse{1}}}},
		{"Requested, second demand: refuse, no second launch", []func(*State){published(true), with(Requested)}, at(1 * s), ConnArrived{2},
			want{phase: Requested, effects: []Effect{Refuse{2}}}},
		{"Booting, demand: refuse, no second launch", []func(*State){published(true), with(Booting, func(i *Instance) { i.LastProbe = at(30 * s) })}, at(30 * s), ConnArrived{3},
			want{phase: Booting, effects: []Effect{Refuse{3}}}},
		{"Requested, fleet returned instance: Booting", []func(*State){published(true), with(Requested)}, at(3 * s), Launched{"desk-1", "i-9"},
			want{phase: Booting}},
		{"Requested, fleet error: Gone, unavailable, machines off", []func(*State){published(true), with(Requested)}, at(3 * s), LaunchFailed{"desk-1", "no capacity"},
			want{phase: Gone, effects: []Effect{PublishMachines{false}}, unavail: true}},
		{"Booting, address known: probe", []func(*State){published(true), with(Booting)}, at(2 * s), Tick{},
			want{phase: Booting, effects: []Effect{Probe{"desk-1", "10.0.0.1:50051"}}}},
		{"Booting, probe ok: Serving", []func(*State){published(true), with(Booting)}, at(40 * s), ProbeOK{"desk-1"},
			want{phase: Serving}},
		{"Booting, 150 s: Terminating, unavailable", []func(*State){published(true), with(Booting)}, at(150 * s), Tick{},
			want{phase: Terminating, effects: []Effect{Terminate{"desk-1", "i-1"}, PublishMachines{false}}, unavail: true}},
		{"Serving, new connection: splice at once", []func(*State){published(true), with(Serving)}, at(10 * s), ConnArrived{7},
			want{phase: Serving, effects: []Effect{Splice{7, "10.0.0.1:50051"}}, live: 1}},
		{"Serving, idle for idleGrace: Draining", []func(*State){published(true), with(Serving)}, at(60 * s), Tick{},
			want{phase: Draining}},
		{"Serving, idle just under idleGrace: poll load", []func(*State){published(true), with(Serving)}, at(59 * s), Tick{},
			want{phase: Serving, effects: []Effect{PollLoad{"desk-1", "10.0.0.1:50051"}}}},
		{"Serving with a live connection never drains", []func(*State){published(true), with(Serving, func(i *Instance) { i.LastPoll = at(600 * s) }), live(1)}, at(600 * s), Tick{},
			want{phase: Serving, live: 1}},
		{"Serving, builder reports load: stays Serving", []func(*State){published(true), with(Serving)}, at(59 * s), LoadSeen{"desk-1", Load{Running: 1}},
			want{phase: Serving}},
		{"Serving, instance shutting down (spot interruption): Terminating", []func(*State){published(true), with(Serving)}, at(30 * s), Observed{[]Seen{{"desk-1", "i-1", ShuttingDown, "10.0.0.1:50051", t0}}},
			want{phase: Terminating, effects: []Effect{Terminate{"desk-1", "i-1"}}}},
		{"Serving, instance terminated: Gone, session logged", []func(*State){published(true), with(Serving)}, at(30 * s), Observed{[]Seen{{"desk-1", "i-1", Terminated, "", t0}}},
			want{phase: Gone, effects: []Effect{SessionEnded{"desk-1", "i-1", 30 * s}}}},
		{"Draining, new connection: Serving, splice", []func(*State){published(true), with(Draining)}, at(2 * s), ConnArrived{3},
			want{phase: Serving, effects: []Effect{Splice{3, "10.0.0.1:50051"}}, live: 1}},
		{"Draining, builder reports load: Serving", []func(*State){published(true), with(Draining)}, at(2 * s), LoadSeen{"desk-1", Load{Queued: 4}},
			want{phase: Serving}},
		{"Draining, idle load report: stays Draining", []func(*State){published(true), with(Draining)}, at(2 * s), LoadSeen{"desk-1", Load{}},
			want{phase: Draining}},
		{"Draining, still idle after recheck: Terminating", []func(*State){published(true), with(Draining)}, at(5 * s), Tick{},
			want{phase: Terminating, effects: []Effect{Terminate{"desk-1", "i-1"}}}},
		{"Terminating, still running after retry interval: terminate again", []func(*State){published(true), with(Terminating, func(i *Instance) { i.LastKill = t0 })}, at(30 * s), Tick{},
			want{phase: Terminating, effects: []Effect{Terminate{"desk-1", "i-1"}}}},
		{"Terminating, describe shows terminated: Gone", []func(*State){published(true), with(Terminating)}, at(40 * s), Observed{[]Seen{{"desk-1", "i-1", Terminated, "", t0}}},
			want{phase: Gone, effects: []Effect{SessionEnded{"desk-1", "i-1", 40 * s}}}},
		{"Terminating, vanished from describe: Gone", []func(*State){published(true), with(Terminating)}, at(40 * s), Observed{},
			want{phase: Gone, effects: []Effect{SessionEnded{"desk-1", "i-1", 40 * s}}}},
		{"any phase, max session: Terminating", []func(*State){published(true), with(Serving, func(i *Instance) { i.LastBusyAt = at(3 * time.Hour) }), live(1)}, at(3 * time.Hour), Tick{},
			want{phase: Terminating, effects: []Effect{Terminate{"desk-1", "i-1"}}, live: 1}},
		{"Requested, tagged instance seen before Launched returns: Booting", []func(*State){published(true), with(Requested)}, at(2 * s), Observed{[]Seen{{"desk-1", "i-5", Pending, "", at(1 * s)}}},
			want{phase: Booting}},
		{"connection closed: live count drops, instance marked busy now", []func(*State){published(true), with(Serving), live(2)}, at(20 * s), ConnClosed{1},
			want{phase: Serving, live: 1}},
		{"reconcile fails with nothing running: unavailable, machines off", []func(*State){published(true)}, at(0), ReconcileFailed{"dial tcp: no route"},
			want{phase: Gone, effects: []Effect{PublishMachines{false}}, unavail: true}},
		{"reconcile fails while serving: keep serving and machines on", []func(*State){published(true), with(Serving)}, at(1 * s), ReconcileFailed{"timeout"},
			want{phase: Serving}},
		{"unavailability expires: machines back on", []func(*State){published(false), unavailableUntil(at(300 * s))}, at(300 * s), Tick{},
			want{phase: Gone, effects: []Effect{PublishMachines{true}}}},
		{"first event publishes machines file", nil, at(0), Tick{},
			want{phase: Gone, effects: []Effect{PublishMachines{true}}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			st := New(cfg())
			st.Synced = true
			for _, f := range c.setup {
				f(st)
			}
			fx := st.Step(c.now, c.ev)
			got := Gone
			if in := st.Instances["desk-1"]; in != nil {
				got = in.Phase
			}
			if got != c.want.phase {
				t.Errorf("phase = %v, want %v", got, c.want.phase)
			}
			if !reflect.DeepEqual(fx, c.want.effects) {
				t.Errorf("effects =\n  %#v\nwant\n  %#v", fx, c.want.effects)
			}
			if st.Live != c.want.live {
				t.Errorf("live = %d, want %d", st.Live, c.want.live)
			}
			if st.Unavailable(c.now) != c.want.unavail {
				t.Errorf("unavailable = %v, want %v", st.Unavailable(c.now), c.want.unavail)
			}
		})
	}
}

// drive runs one event per second from..to and returns the effects with the
// second they were emitted.
func drive(st *State, from, to time.Duration) map[time.Duration][]Effect {
	out := map[time.Duration][]Effect{}
	for d := from; d <= to; d += s {
		if fx := st.Step(at(d), Tick{}); len(fx) > 0 {
			out[d] = fx
		}
	}
	return out
}

func TestTerminateAfterDrainTiming(t *testing.T) {
	st := New(cfg())
	st.Synced = true
	st.Step(at(0), ConnArrived{1})
	st.Step(at(1*s), Launched{"desk-1", "i-1"})
	st.Step(at(2*s), Observed{[]Seen{{"desk-1", "i-1", Running, "10.0.0.1:50051", at(1 * s)}}})
	st.Step(at(40*s), ProbeOK{"desk-1"})
	st.Step(at(41*s), ConnArrived{2})
	st.Step(at(100*s), ConnClosed{2})
	var killedAt time.Duration = -1
	for d, fx := range drive(st, 101*s, 300*s) {
		for _, e := range fx {
			if _, ok := e.(Terminate); ok && (killedAt < 0 || d < killedAt) {
				killedAt = d
			}
		}
	}
	want := 100*s + cfg().IdleGrace + cfg().DrainRecheck
	if killedAt != want {
		t.Fatalf("terminate at %v, want %v (last connection closed at 100s + idleGrace + drainRecheck)", killedAt, want)
	}
}

func TestCrashRecoveryAdoptsRunningInstanceWithoutKillingIt(t *testing.T) {
	st := New(DefaultConfig("desk"))
	twentyMinAgo := at(-20 * time.Minute)
	fx := st.Step(at(0), Observed{[]Seen{
		{"desk-old-3", "i-3", Running, "10.0.0.3:50051", twentyMinAgo},
		{"desk-old-2", "i-2", Terminated, "", twentyMinAgo},
		{"desk-old-4", "i-4", Stopped, "", twentyMinAgo},
	}})
	if got := st.Instances["desk-old-3"].Phase; got != Booting {
		t.Fatalf("running instance adopted as %v, want Booting", got)
	}
	if _, ok := st.Instances["desk-old-2"]; ok {
		t.Fatalf("terminated instance must not be adopted")
	}
	if !reflect.DeepEqual(fx, []Effect{Terminate{"desk-old-4", "i-4"}, PublishMachines{true}}) {
		t.Fatalf("effects = %#v", fx)
	}
	fx = st.Step(at(2*s), Tick{})
	if !reflect.DeepEqual(fx, []Effect{Probe{"desk-old-3", "10.0.0.3:50051"}}) {
		t.Fatalf("adopted instance must be probed, not killed for its age: %#v", fx)
	}
	st.Step(at(3*s), ProbeOK{"desk-old-3"})
	fx = st.Step(at(4*s), ConnArrived{1})
	if !reflect.DeepEqual(fx, []Effect{Splice{1, "10.0.0.3:50051"}}) {
		t.Fatalf("new demand must reuse the adopted builder: %#v", fx)
	}
}

func TestReconcileIsIdempotent(t *testing.T) {
	snap := Observed{[]Seen{{"desk-1", "i-1", Running, "10.0.0.1:50051", t0}}}
	a := New(cfg())
	a.Step(at(0), snap)
	b := New(cfg())
	b.Step(at(0), snap)
	b.Step(at(0), snap)
	if !reflect.DeepEqual(a.Instances, b.Instances) {
		t.Fatalf("second identical snapshot changed state:\n%#v\n%#v", a.Instances, b.Instances)
	}
}

func TestBootTimeoutCountsFromBootingNotLaunch(t *testing.T) {
	st := New(cfg())
	with(Booting, func(i *Instance) { i.LaunchedAt = at(-time.Hour); i.Since = t0; i.LastProbe = at(149 * s) })(st)
	st.Published = new(bool)
	*st.Published = true
	if fx := st.Step(at(149*s), Tick{}); len(fx) != 0 {
		t.Fatalf("killed before 150 s in Booting: %#v", fx)
	}
}

func TestNoLaunchBeforeFirstReconcile(t *testing.T) {
	st := New(cfg())
	if fx := st.Step(at(0), ConnArrived{1}); !reflect.DeepEqual(fx, []Effect{Refuse{1}, PublishMachines{true}}) {
		t.Fatalf("launched before knowing what a previous run left behind: %#v", fx)
	}
	st.Step(at(1*s), Observed{})
	if fx := st.Step(at(2*s), ConnArrived{2}); !reflect.DeepEqual(fx, []Effect{Launch{"desk-1"}, Refuse{2}}) {
		t.Fatalf("the client's retry after the first reconcile must launch: %#v", fx)
	}
}
