package gate

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
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
	return startWith(t, fake, mut, 200*time.Millisecond)
}

func startWith(t *testing.T, fake *cloud.Fake, mut func(*fleet.Config), reconcileEvery time.Duration) *harness {
	cfg := fleet.DefaultConfig("test")
	cfg.IdleGrace = 1 * time.Second
	cfg.RetryHold = 2 * time.Second
	cfg.DrainRecheck = 300 * time.Millisecond
	cfg.ProbeEvery = 100 * time.Millisecond
	cfg.TerminateRetry = time.Second
	if mut != nil {
		mut(&cfg)
	}
	machines := filepath.Join(t.TempDir(), "machines")
	g, err := Listen(Options{
		Listen: "127.0.0.1:0", MachinesFile: machines, MachinesEntry: entry, Fleet: cfg,
		Tick: 50 * time.Millisecond, ReconcileEvery: reconcileEvery, BootPoll: 50 * time.Millisecond, CallTimeout: 2 * time.Second,
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

// attempt connects through the gate once. It returns the open connection if
// bytes came back, and whether the gate reset it otherwise.
func (h *harness) attempt() (net.Conn, bool, error) {
	c, err := net.Dial("tcp", h.gate.Addr())
	if err != nil {
		return nil, errors.Is(err, syscall.ECONNRESET), err
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err = c.Write([]byte("ping")); err == nil {
		buf := make([]byte, 4)
		if _, err = io.ReadFull(c, buf); err == nil && string(buf) == "ping" {
			return c, false, nil
		}
	}
	c.Close()
	return nil, errors.Is(err, syscall.ECONNRESET), err
}

// dial behaves like the nix-grpc-store client: it retries a reset every
// 500 ms until connect-timeout and gives up at once on anything else.
func (h *harness) dial(connectTimeout time.Duration) (c net.Conn, resets int, took time.Duration, err error) {
	t0 := time.Now()
	for {
		c, reset, err := h.attempt()
		if c != nil || !reset || time.Since(t0)+500*time.Millisecond > connectTimeout {
			return c, resets, time.Since(t0), err
		}
		resets++
		time.Sleep(500 * time.Millisecond)
	}
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

func TestColdStartRefusesUntilBuilderServes(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 1500 * time.Millisecond, Addr: echoServer(t)}
	h := start(t, fake, nil)
	waitFor(t, "machines entry published", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	type result struct {
		ok     bool
		resets int
		took   time.Duration
		err    error
	}
	results := make(chan result, 3)
	for i := 0; i < 3; i++ {
		go func() {
			c, resets, took, err := h.dial(10 * time.Second)
			if c != nil {
				c.Close()
			}
			results <- result{c != nil, resets, took, err}
		}()
	}
	for i := 0; i < 3; i++ {
		r := <-results
		if !r.ok {
			t.Fatalf("client gave up after %v and %d resets: %v", r.took, r.resets, r.err)
		}
		if r.resets == 0 || r.took < 1500*time.Millisecond {
			t.Fatalf("answered after %v with %d resets, before the builder booted", r.took, r.resets)
		}
		t.Logf("spliced after %v and %d resets", r.took, r.resets)
	}
	if n := fake.CallCount("Launch"); n != 1 {
		t.Fatalf("Launch called %d times for 3 concurrent connections, want 1", n)
	}
}

func TestFallbackWhenCloudUnreachable(t *testing.T) {
	fake := &cloud.Fake{Addr: echoServer(t), Down: true, Latency: 200 * time.Millisecond}
	h := start(t, fake, nil)
	waitFor(t, "machines entry removed after failed reconcile", 2*time.Second, func() bool { return h.machinesContent() == "" && fileExists(h.machines) })
	c, resets, d, _ := h.dial(10 * time.Second)
	if ok := c != nil; ok || resets != 0 {
		t.Fatalf("ok=%v resets=%d while the cloud is down, want a plain close", ok, resets)
	}
	if d > time.Second {
		t.Fatalf("connection closed after %v, want under 1 s so nix falls back fast", d)
	}
	if n := fake.CallCount("Launch"); n != 0 {
		t.Fatalf("Launch called %d times while unavailable", n)
	}
	t.Logf("connection closed by the gate after %v; machines file empty", d)
}

func TestFallbackWhenLaunchFails(t *testing.T) {
	fake := &cloud.Fake{Addr: echoServer(t), Latency: 100 * time.Millisecond}
	h := start(t, fake, nil)
	waitFor(t, "machines entry", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	fake.SetDown(true)
	c, resets, d, _ := h.dial(10 * time.Second)
	if ok := c != nil; ok || d > 2*time.Second {
		t.Fatalf("ok=%v after %v, want the client to stop retrying within 2 s", ok, d)
	}
	waitFor(t, "machines entry removed", time.Second, func() bool { return h.machinesContent() == "" })
	t.Logf("launch failure ended the client's retries after %v and %d resets", d, resets)
}

func TestTerminateAfterDrain(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 300 * time.Millisecond, Addr: echoServer(t)}
	h := start(t, fake, nil)
	c, _, _, err := h.dial(10 * time.Second)
	if c == nil {
		t.Fatalf("no splice: %v", err)
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
	c, _, _, err := h.dial(10 * time.Second)
	if c == nil {
		t.Fatalf("connection not spliced to the adopted builder: %v", err)
	}
	c.Close()
	if n := fake.CallCount("Launch"); n != 0 {
		t.Fatalf("restarted gate launched %d new builders instead of adopting", n)
	}
	waitFor(t, "adopted builder terminated when idle", 5*time.Second, func() bool { return fake.Running() == 0 })
}

func TestBootTimeoutTerminatesAndFallsBack(t *testing.T) {
	fake := &cloud.Fake{BootDelay: time.Hour, Addr: echoServer(t)}
	h := start(t, fake, func(c *fleet.Config) { c.BootTimeout = 700 * time.Millisecond })
	c, _, d, _ := h.dial(10 * time.Second)
	if c != nil {
		t.Fatal("spliced to a builder that never booted")
	}
	if d < 700*time.Millisecond || d > 2*time.Second {
		t.Fatalf("client stopped after %v, want just after the 700 ms boot timeout", d)
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

// Phase 3 cold starts took 42 s for a 20 s boot: the gate only learned the
// address at the next 30 s reconcile. A launch must poll until running.
func TestColdStartDoesNotWaitForPeriodicReconcile(t *testing.T) {
	fake := &cloud.Fake{BootDelay: 500 * time.Millisecond, Addr: echoServer(t)}
	h := startWith(t, fake, nil, time.Hour)
	waitFor(t, "machines entry published", time.Second, func() bool { return h.machinesContent() == entry+"\n" })
	c, resets, took, err := h.dial(10 * time.Second)
	if c == nil {
		t.Fatalf("client gave up after %v and %d resets: %v", took, resets, err)
	}
	c.Close()
	if took > 2*time.Second {
		t.Fatalf("spliced after %v for a 500 ms boot, want under 2 s", took)
	}
	t.Logf("spliced after %v and %d resets", took, resets)
}
