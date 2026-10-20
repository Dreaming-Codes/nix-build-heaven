// nbh-gate holds the nix-daemon's first connection to the remote builder while
// it launches one, splices traffic once it serves, and terminates it when idle.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"nix-build-heaven/gate/cloud"
	"nix-build-heaven/gate/fleet"
	"nix-build-heaven/gate/gate"
)

func main() {
	host, _ := os.Hostname()
	cfg := fleet.DefaultConfig(fmt.Sprintf("%s-%d", host, time.Now().Unix()))
	listen := flag.String("listen", "127.0.0.1:50051", "address the nix-daemon connects to")
	machines := flag.String("machines-file", "/run/nbh/machines", "machines file nix reads via builders = @FILE")
	entry := flag.String("machines-entry", "", "machines line written while the builder is available")
	metricsPort := flag.Int("metrics-port", 0, "builder Prometheus port, 0 to rely on connection counts only")
	backend := flag.String("backend", "aws", "cloud backend: aws or fake")
	fakeAddr := flag.String("fake-addr", "127.0.0.1:50052", "fake backend: address every fake instance serves on")
	fakeBoot := flag.Duration("fake-boot-delay", 75*time.Second, "fake backend: pending time before running")
	fakeDown := flag.Bool("fake-down", false, "fake backend: every call fails, like an unreachable region")
	flag.DurationVar(&cfg.IdleGrace, "idle-grace", cfg.IdleGrace, "idle time before draining")
	flag.DurationVar(&cfg.BootTimeout, "boot-timeout", cfg.BootTimeout, "time allowed from launch to serving")
	flag.DurationVar(&cfg.MaxSession, "max-session", cfg.MaxSession, "hard cap on one builder's lifetime")
	flag.Parse()
	if *entry == "" {
		log.Fatal("-machines-entry is required")
	}
	var cl cloud.Cloud
	switch *backend {
	case "fake":
		cl = &cloud.Fake{Addr: *fakeAddr, BootDelay: *fakeBoot, Down: *fakeDown}
	case "aws":
		log.Fatal(errors.New("aws backend lands in Phase 4; use -backend fake"))
	default:
		log.Fatalf("unknown backend %q", *backend)
	}
	g, err := gate.Listen(gate.Options{
		Listen: *listen, MachinesFile: *machines, MachinesEntry: *entry, MetricsPort: *metricsPort,
		Fleet: cfg, Tick: time.Second, ReconcileEvery: 30 * time.Second, CallTimeout: 20 * time.Second,
	}, cl)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := g.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
