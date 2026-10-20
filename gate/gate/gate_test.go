package gate

import (
	"context"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"nix-build-heaven/gate/cloud"
	"nix-build-heaven/gate/fleet"
)

const entry = "grpc://nbh-builder:50051 x86_64-linux - 192 1 big-parallel"

func echoServer(t *testing.T) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().String()
}

type harness struct {
	t        *testing.T
	gate     *Gate
	fake     *cloud.Fake
	machines string
}

func start(t *testing.T, fake *cloud.Fake, mut func(*fleet.Config)) *harness {
	cfg := fleet.DefaultConfig("test")
	cfg.IdleGrace = 1 * time.Second
	cfg.DrainRecheck = 300 * time.Millisecond
	cfg.ProbeEvery = 100 * time.Millisecond
	cfg.TerminateRetry = time.Second
	if mut != nil {
		mut(&cfg)
	}
	machines := filepath.Join(t.TempDir(), "machines")
	g, err := Listen(Options{
		Listen: "127.0.0.1:0", MachinesFile: machines, MachinesEntry: entry, Fleet: cfg,
		Tick: 50 * time.Millisecond, ReconcileEvery: 200 * time.Millisecond, CallTimeout: 2 * time.Second,
		Log: log.New(testWriter{t}, "", log.Lmicroseconds),
	}, fake)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go g.Run(ctx)
	return &harness{t, g, fake, machines}
}

type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) {
	w.t.Log(strings.TrimSpace(string(p)))
	return len(p), nil
}

// roundTrip connects through the gate and reports whether bytes came back, and how long it took.
func (h *harness) roundTrip() (bool, time.Duration, net.Conn) {
	t0 := time.Now()
	c, err := net.Dial("tcp", h.gate.Addr())
	if err != nil {
		h.t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := c.Write([]byte("ping")); err != nil {
		return false, time.Since(t0), c
	}
	buf := make([]byte, 4)
	_, err = io.ReadFull(c, buf)
	return err == nil && string(buf) == "ping", time.Since(t0), c
}

func (h *harness) machinesContent() string {
	b, _ := os.ReadFile(h.machines)
	return string(b)
}

func waitFor(t *testing.T, what string, limit time.Duration, cond func() bool) time.Duration {
	t0 := time.Now()
	for time.Since(t0) < limit {
		if cond() {
			return time.Since(t0)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out after %v waiting for %s", limit, what)
	return 0
}

func TestColdStartHoldsConnectionsUntilBuilderServes(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 1500 * time.Millisecond, Addr: echoServer(t)}
	h := start(t, fake, nil)
	waitFor(t, "machines entry published", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	results := make(chan time.Duration, 3)
	for i := 0; i < 3; i++ {
		go func() {
			ok, d, c := h.roundTrip()
			c.Close()
			if !ok {
				d = -1
			}
			results <- d
		}()
	}
	for i := 0; i < 3; i++ {
		d := <-results
		if d < 0 {
			t.Fatal("held connection was not spliced to the builder")
		}
		if d < 1500*time.Millisecond {
			t.Fatalf("connection answered after %v, before the builder booted", d)
		}
		t.Logf("held connection spliced after %v", d)
	}
	if n := fake.CallCount("Launch"); n != 1 {
		t.Fatalf("Launch called %d times for 3 concurrent connections, want 1", n)
	}
}

func TestFallbackWhenCloudUnreachable(t *testing.T) {
	fake := &cloud.Fake{Addr: echoServer(t), Down: true, Latency: 200 * time.Millisecond}
	h := start(t, fake, nil)
	waitFor(t, "machines entry removed after failed reconcile", 2*time.Second, func() bool { return h.machinesContent() == "" && fileExists(h.machines) })
	ok, d, c := h.roundTrip()
	c.Close()
	if ok {
		t.Fatal("connection reached a builder while the cloud is down")
	}
	if d > time.Second {
		t.Fatalf("held connection released after %v, want under 1 s so nix falls back fast", d)
	}
	if n := fake.CallCount("Launch"); n != 0 {
		t.Fatalf("Launch called %d times while unavailable", n)
	}
	t.Logf("connection refused through gate after %v; machines file empty", d)
}

func TestFallbackWhenLaunchFails(t *testing.T) {
	fake := &cloud.Fake{Addr: echoServer(t), Latency: 100 * time.Millisecond}
	h := start(t, fake, nil)
	waitFor(t, "machines entry", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	fake.SetDown(true)
	ok, d, c := h.roundTrip()
	c.Close()
	if ok || d > 2*time.Second {
		t.Fatalf("ok=%v after %v, want released within 2 s", ok, d)
	}
	waitFor(t, "machines entry removed", time.Second, func() bool { return h.machinesContent() == "" })
	t.Logf("launch failure released the held connection after %v", d)
}

func TestTerminateAfterDrain(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 300 * time.Millisecond, Addr: echoServer(t)}
	h := start(t, fake, nil)
	ok, _, c := h.roundTrip()
	if !ok {
		t.Fatal("no splice")
	}
	time.Sleep(1500 * time.Millisecond)
	if fake.Running() != 1 {
		t.Fatal("builder terminated while a connection was still open")
	}
	c.Close()
	closed := time.Now()
	waitFor(t, "builder terminated", 5*time.Second, func() bool { return fake.Running() == 0 })
	d := time.Since(closed)
	min, max := time.Second+300*time.Millisecond, 2*time.Second
	if d < min || d > max {
		t.Fatalf("terminated %v after the last connection closed, want between %v and %v", d, min, max)
	}
	t.Logf("terminated %v after the last connection closed (idleGrace 1s + drainRecheck 0.3s)", d)
}

func TestRestartAdoptsRunningBuilder(t *testing.T) {
	fake := &cloud.Fake{Addr: echoServer(t)}
	fake.Adopt("previous-run-7", time.Now().Add(-20*time.Minute))
	h := start(t, fake, nil)
	ok, _, c := h.roundTrip()
	c.Close()
	if !ok {
		t.Fatal("connection not spliced to the adopted builder")
	}
	if n := fake.CallCount("Launch"); n != 0 {
		t.Fatalf("restarted gate launched %d new builders instead of adopting", n)
	}
	waitFor(t, "adopted builder terminated when idle", 5*time.Second, func() bool { return fake.Running() == 0 })
}

func TestBootTimeoutTerminatesAndFallsBack(t *testing.T) {
	fake := &cloud.Fake{BootDelay: time.Hour, Addr: echoServer(t)}
	h := start(t, fake, func(c *fleet.Config) { c.BootTimeout = 700 * time.Millisecond })
	ok, d, c := h.roundTrip()
	c.Close()
	if ok {
		t.Fatal("spliced to a builder that never booted")
	}
	if d < 700*time.Millisecond || d > 2*time.Second {
		t.Fatalf("released after %v, want just after the 700 ms boot timeout", d)
	}
	waitFor(t, "stuck builder terminated", 2*time.Second, func() bool { return fake.Running() == 0 })
	if h.machinesContent() != "" {
		t.Fatal("machines entry still present after boot timeout")
	}
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestParseLoad(t *testing.T) {
	text := `# HELP nix_grpc_sched Scheduler state
nix_grpc_sched{kind="clients"} 2
nix_grpc_sched{kind="queued"} 5
nix_grpc_sched{kind="workers"} 1
nix_grpc_sched_system{features="",kind="running",system="x86_64-linux"} 3
nix_grpc_sched_system{features="big-parallel",kind="running",system="x86_64-linux"} 1
nix_grpc_sched_system{features="",kind="free",system="x86_64-linux"} 4
`
	l, err := ParseLoad(strings.NewReader(text))
	if err != nil || l != (fleet.Load{Clients: 2, Running: 4, Queued: 5}) {
		t.Fatalf("got %+v, %v", l, err)
	}
}
