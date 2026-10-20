// Package gate is the I/O shell around fleet: it accepts the nix-daemon's
// connections, executes fleet effects against the cloud and the builder, and
// owns the machines file.
package gate

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"nix-build-heaven/gate/cloud"
	"nix-build-heaven/gate/fleet"
)

type Options struct {
	Listen         string
	MachinesFile   string
	MachinesEntry  string
	MetricsPort    int
	Fleet          fleet.Config
	Tick           time.Duration
	ReconcileEvery time.Duration
	CallTimeout    time.Duration
	Log            *log.Logger
}

type arrival struct {
	id    fleet.ConnID
	reply chan verdict
}

// verdict is the fleet's answer for one connection: splice it to addr, or
// close it, with a reset when the client should retry.
type verdict struct {
	addr  string
	reset bool
}

type Gate struct {
	opt     Options
	cloud   cloud.Cloud
	ln      net.Listener
	events  chan any
	replies map[fleet.ConnID]chan verdict
}

func Listen(opt Options, cl cloud.Cloud) (*Gate, error) {
	ln, err := net.Listen("tcp", opt.Listen)
	if err != nil {
		return nil, err
	}
	if opt.Log == nil {
		opt.Log = log.New(os.Stderr, "nbh-gate: ", log.LstdFlags|log.Lmicroseconds)
	}
	return &Gate{opt: opt, cloud: cl, ln: ln, events: make(chan any, 256), replies: map[fleet.ConnID]chan verdict{}}, nil
}

func (g *Gate) Addr() string { return g.ln.Addr().String() }

func (g *Gate) Run(ctx context.Context) error {
	defer g.ln.Close()
	go g.accept(ctx)
	go g.every(ctx, g.opt.Tick, func() { g.post(fleet.Tick{}) })
	go g.every(ctx, g.opt.ReconcileEvery, g.reconcile)
	st := fleet.New(g.opt.Fleet)
	for {
		select {
		case <-ctx.Done():
			return nil
		case ev := <-g.events:
			var fx []fleet.Effect
			switch e := ev.(type) {
			case arrival:
				g.replies[e.id] = e.reply
				fx = st.Step(time.Now(), fleet.ConnArrived{ID: e.id})
			case fleet.Event:
				fx = st.Step(time.Now(), e)
			}
			for _, f := range fx {
				g.exec(ctx, f)
			}
		}
	}
}

func (g *Gate) post(ev any) { g.events <- ev }

func (g *Gate) every(ctx context.Context, d time.Duration, f func()) {
	f()
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			f()
		}
	}
}

func (g *Gate) reconcile() {
	ctx, cancel := context.WithTimeout(context.Background(), g.opt.CallTimeout)
	defer cancel()
	seen, err := g.cloud.List(ctx)
	if err != nil {
		g.post(fleet.ReconcileFailed{Err: err.Error()})
		return
	}
	g.post(fleet.Observed{Instances: seen})
}

func (g *Gate) exec(ctx context.Context, f fleet.Effect) {
	l := g.opt.Log
	switch e := f.(type) {
	case fleet.Launch:
		l.Printf("launch %s", e.Key)
		go func() {
			c, cancel := context.WithTimeout(ctx, g.opt.CallTimeout)
			defer cancel()
			id, err := g.cloud.Launch(c, e.Key)
			if err != nil {
				l.Printf("launch %s failed: %v", e.Key, err)
				g.post(fleet.LaunchFailed{Key: e.Key, Err: err.Error()})
				return
			}
			l.Printf("launched %s as %s", e.Key, id)
			g.post(fleet.Launched{Key: e.Key, InstanceID: id})
			g.reconcile()
		}()
	case fleet.Terminate:
		l.Printf("terminate %s (%s)", e.Key, e.InstanceID)
		go func() {
			c, cancel := context.WithTimeout(ctx, g.opt.CallTimeout)
			defer cancel()
			if err := g.cloud.Terminate(c, e.InstanceID); err != nil {
				l.Printf("terminate %s failed, will retry: %v", e.InstanceID, err)
				return
			}
			g.reconcile()
		}()
	case fleet.Splice:
		l.Printf("splice connection %d to %s", e.Conn, e.Addr)
		g.answer(e.Conn, verdict{addr: e.Addr})
	case fleet.Release:
		l.Printf("release connection %d, nix builds locally", e.Conn)
		g.answer(e.Conn, verdict{})
	case fleet.Refuse:
		l.Printf("refuse connection %d while the builder boots", e.Conn)
		g.answer(e.Conn, verdict{reset: true})
	case fleet.PublishMachines:
		if err := g.writeMachines(e.Available); err != nil {
			l.Printf("machines file: %v", err)
		} else {
			l.Printf("machines file: builder available=%v", e.Available)
		}
	case fleet.Probe:
		go func() {
			c, err := net.DialTimeout("tcp", e.Addr, 2*time.Second)
			if err == nil {
				c.Close()
				g.post(fleet.ProbeOK{Key: e.Key})
			}
		}()
	case fleet.PollLoad:
		if g.opt.MetricsPort == 0 {
			return
		}
		go func() {
			if load, err := g.load(e.Addr); err == nil {
				g.post(fleet.LoadSeen{Key: e.Key, Load: load})
			}
		}()
	case fleet.SessionEnded:
		l.Printf("session %s %s ended, billed %.0f s", e.Key, e.InstanceID, e.Billed.Seconds())
	}
}

func (g *Gate) answer(id fleet.ConnID, v verdict) {
	g.replies[id] <- v
	delete(g.replies, id)
}

func (g *Gate) writeMachines(available bool) error {
	content := ""
	if available {
		content = g.opt.MachinesEntry + "\n"
	}
	dir := filepath.Dir(g.opt.MachinesFile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".machines-*")
	if err != nil {
		return err
	}
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), g.opt.MachinesFile)
}

func (g *Gate) load(addr string) (fleet.Load, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fleet.Load{}, err
	}
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(fmt.Sprintf("http://%s/metrics", net.JoinHostPort(host, strconv.Itoa(g.opt.MetricsPort))))
	if err != nil {
		return fleet.Load{}, err
	}
	defer resp.Body.Close()
	return ParseLoad(resp.Body)
}

// ParseLoad reads the nix-grpc-daemon scheduler gauges from Prometheus text.
func ParseLoad(r io.Reader) (fleet.Load, error) {
	var l fleet.Load
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		i := strings.LastIndexByte(line, ' ')
		if i < 0 || strings.HasPrefix(line, "#") {
			continue
		}
		v, err := strconv.ParseFloat(line[i+1:], 64)
		if err != nil {
			continue
		}
		name := line[:i]
		switch {
		case name == `nix_grpc_sched{kind="clients"}`:
			l.Clients = int(v)
		case name == `nix_grpc_sched{kind="queued"}`:
			l.Queued = int(v)
		case strings.HasPrefix(name, "nix_grpc_sched_system{") && strings.Contains(name, `kind="running"`):
			l.Running += int(v)
		}
	}
	return l, sc.Err()
}

func (g *Gate) accept(ctx context.Context) {
	var next fleet.ConnID
	for {
		c, err := g.ln.Accept()
		if err != nil {
			if ctx.Err() == nil {
				g.opt.Log.Printf("accept: %v", err)
			}
			return
		}
		next++
		reply := make(chan verdict, 1)
		g.post(arrival{next, reply})
		go g.handle(c, next, reply)
	}
}

func (g *Gate) handle(c net.Conn, id fleet.ConnID, reply chan verdict) {
	defer c.Close()
	v := <-reply
	if v.reset {
		if tc, ok := c.(*net.TCPConn); ok {
			tc.SetLinger(0)
		}
		return
	}
	if v.addr == "" {
		// Closing with the client's unread TLS hello in the buffer sends a
		// reset, which the plugin retries; a FIN makes it give up at once.
		if tc, ok := c.(*net.TCPConn); ok {
			tc.CloseWrite()
			tc.SetReadDeadline(time.Now().Add(2 * time.Second))
			io.Copy(io.Discard, tc)
		}
		return
	}
	defer g.post(fleet.ConnClosed{ID: id})
	b, err := net.DialTimeout("tcp", v.addr, 10*time.Second)
	if err != nil {
		g.opt.Log.Printf("dial builder %s: %v", v.addr, err)
		return
	}
	defer b.Close()
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if tc, ok := dst.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
		done <- struct{}{}
	}
	go pipe(b, c)
	go pipe(c, b)
	<-done
	<-done
}
