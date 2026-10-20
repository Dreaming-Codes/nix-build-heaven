package gate

import (
	"testing"
	"time"

	"nix-build-heaven/gate/cloud"
	"nix-build-heaven/gate/fleet"
)

func hold(c *fleet.Config) { c.HoldWhileBooting = true }

// The ssh-ng client connects once and waits for the banner, so in hold mode
// every first attempt must succeed after the boot, with no reset.
func TestHoldColdStartSplicesFirstAttempt(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 1500 * time.Millisecond, Addr: echoServer(t)}
	h := start(t, fake, hold)
	waitFor(t, "machines entry published", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	type result struct {
		ok    bool
		reset bool
		took  time.Duration
		err   error
	}
	results := make(chan result, 3)
	for i := 0; i < 3; i++ {
		go func() {
			t0 := time.Now()
			c, reset, err := h.attempt()
			if c != nil {
				c.Close()
			}
			results <- result{c != nil, reset, time.Since(t0), err}
		}()
	}
	for i := 0; i < 3; i++ {
		r := <-results
		if !r.ok {
			t.Fatalf("first attempt failed after %v (reset=%v): %v", r.took, r.reset, r.err)
		}
		if r.took < 1500*time.Millisecond {
			t.Fatalf("answered after %v, before the builder booted", r.took)
		}
		t.Logf("held, then spliced after %v", r.took)
	}
	if n := fake.CallCount("Launch"); n != 1 {
		t.Fatalf("Launch called %d times for 3 concurrent connections, want 1", n)
	}
}

// A builder that never serves: the held connection gets a FIN at the boot
// timeout, which the ssh client treats as a failed machine, so Nix goes local.
func TestHoldBootTimeoutReleasesWithFIN(t *testing.T) {
	fake := &cloud.Fake{BootDelay: time.Hour, Addr: echoServer(t)}
	h := start(t, fake, func(c *fleet.Config) { hold(c); c.BootTimeout = 700 * time.Millisecond })
	t0 := time.Now()
	c, reset, _ := h.attempt()
	d := time.Since(t0)
	if c != nil {
		t.Fatal("spliced to a builder that never booted")
	}
	if reset {
		t.Fatal("got a reset, want a FIN")
	}
	if d < 700*time.Millisecond || d > 3*time.Second {
		t.Fatalf("released after %v, want just after the 700 ms boot timeout", d)
	}
	waitFor(t, "stuck builder terminated", 2*time.Second, func() bool { return fake.Running() == 0 })
}
