package fleet

import (
	"reflect"
	"testing"
)

func holdCfg() Config {
	c := DefaultConfig("desk")
	c.HoldWhileBooting = true
	return c
}

func expect(t *testing.T, what string, got, want []Effect) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %#v, want %#v", what, got, want)
	}
}

// The ssh-ng path: connections are held through the boot and all spliced on
// the first good probe, with exactly one launch and no refusal.
func TestHoldSplicesEveryHeldConnectionOnServing(t *testing.T) {
	st := New(holdCfg())
	st.Step(at(0), Observed{})
	expect(t, "first arrival", st.Step(at(1*s), ConnArrived{1}), []Effect{Launch{"desk-1"}})
	expect(t, "second arrival", st.Step(at(2*s), ConnArrived{2}), nil)
	st.Step(at(3*s), Launched{"desk-1", "i-1"})
	st.Step(at(4*s), Observed{[]Seen{{Key: "desk-1", InstanceID: "i-1", State: Running, Addr: "10.0.0.1:22", LaunchedAt: at(3 * s)}}})
	expect(t, "probe ok", st.Step(at(30*s), ProbeOK{"desk-1"}), []Effect{Splice{1, "10.0.0.1:22"}, Splice{2, "10.0.0.1:22"}})
	if st.Live != 2 || len(st.Held) != 0 || !st.LastRefused.IsZero() {
		t.Fatalf("live %d held %v lastRefused %v", st.Live, st.Held, st.LastRefused)
	}
	expect(t, "warm arrival", st.Step(at(31*s), ConnArrived{3}), []Effect{Splice{3, "10.0.0.1:22"}})
}

// A connection that arrives before the first reconcile is held, and the launch
// follows the reconcile instead of a client retry, which ssh-ng never makes.
func TestHoldLaunchesAfterFirstReconcile(t *testing.T) {
	st := New(holdCfg())
	expect(t, "arrival before sync", st.Step(at(0), ConnArrived{1}), []Effect{PublishMachines{true}})
	expect(t, "first reconcile", st.Step(at(1*s), Observed{}), []Effect{Launch{"desk-1"}})
}

// A boot that never serves releases the held connection with a FIN, so the
// hook gives up on the machine and Nix builds locally.
func TestHoldReleasesOnBootTimeout(t *testing.T) {
	st := New(holdCfg())
	st.Step(at(0), Observed{})
	st.Step(at(0), ConnArrived{1})
	st.Step(at(1*s), Launched{"desk-1", "i-1"})
	fx := st.Step(at(1*s+st.Cfg.BootTimeout), Tick{})
	expect(t, "boot timeout", fx, []Effect{Terminate{"desk-1", "i-1"}, Release{1}, PublishMachines{false}})
}

func TestHoldReleasesOnLaunchFailure(t *testing.T) {
	st := New(holdCfg())
	st.Step(at(0), Observed{})
	st.Step(at(0), ConnArrived{1})
	fx := st.Step(at(1*s), LaunchFailed{"desk-1", "InsufficientInstanceCapacity"})
	expect(t, "launch failed", fx, []Effect{Release{1}, PublishMachines{false}})
}

// A held connection that arrives while the previous builder is still
// terminating launches the next one as soon as the old one is gone.
func TestHoldRelaunchesWhenPreviousIsGone(t *testing.T) {
	st := New(holdCfg())
	st.Step(at(0), Observed{})
	st.Instances["desk-0"] = &Instance{Key: "desk-0", Phase: Terminating, InstanceID: "i-0", LaunchedAt: at(0), LastKill: at(0)}
	expect(t, "arrival at capacity", st.Step(at(1*s), ConnArrived{1}), nil)
	fx := st.Step(at(2*s), Observed{})
	if len(fx) != 2 {
		t.Fatalf("want SessionEnded and Launch, got %#v", fx)
	}
	if _, ok := fx[1].(Launch); !ok {
		t.Fatalf("want Launch last, got %#v", fx)
	}
}
