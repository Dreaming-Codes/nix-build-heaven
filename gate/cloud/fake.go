package cloud

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"nix-build-heaven/gate/fleet"
)

// Fake is an in-memory EC2. An instance is pending for BootDelay, then
// running at Addr. Down makes every call fail after Latency, like a blocked
// network or revoked credentials.
type Fake struct {
	mu        sync.Mutex
	BootDelay time.Duration
	Addr      string
	Latency   time.Duration
	Down      bool
	n         int
	insts     map[string]*fakeInst
	calls     []string
}

type fakeInst struct {
	key        fleet.Key
	launchedAt time.Time
	terminated bool
}

var ErrUnreachable = errors.New("fake ec2: dial tcp: network is unreachable")

func (f *Fake) call(name string) error {
	f.mu.Lock()
	f.calls = append(f.calls, name)
	down, lat := f.Down, f.Latency
	f.mu.Unlock()
	time.Sleep(lat)
	if down {
		return ErrUnreachable
	}
	return nil
}

func (f *Fake) SetDown(v bool) { f.mu.Lock(); f.Down = v; f.mu.Unlock() }

func (f *Fake) Launch(ctx context.Context, key fleet.Key) (string, error) {
	if err := f.call("Launch"); err != nil {
		return "", err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.insts == nil {
		f.insts = map[string]*fakeInst{}
	}
	f.n++
	id := fmt.Sprintf("i-fake%04d", f.n)
	f.insts[id] = &fakeInst{key: key, launchedAt: time.Now()}
	return id, nil
}

func (f *Fake) List(ctx context.Context) ([]fleet.Seen, error) {
	if err := f.call("List"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fleet.Seen
	for id, in := range f.insts {
		seen := fleet.Seen{Key: in.key, InstanceID: id, LaunchedAt: in.launchedAt}
		switch {
		case in.terminated:
			seen.State = fleet.Terminated
		case time.Since(in.launchedAt) < f.BootDelay:
			seen.State = fleet.Pending
		default:
			seen.State, seen.Addr = fleet.Running, f.Addr
		}
		out = append(out, seen)
	}
	return out, nil
}

func (f *Fake) Terminate(ctx context.Context, id string) error {
	if err := f.call("Terminate"); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if in := f.insts[id]; in != nil {
		in.terminated = true
	}
	return nil
}

func (f *Fake) CallCount(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if c == name {
			n++
		}
	}
	return n
}

// Running counts instances that are not terminated, as a billing check would.
func (f *Fake) Running() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, in := range f.insts {
		if !in.terminated {
			n++
		}
	}
	return n
}

// Adopt plants an instance as if a previous gate process had launched it.
func (f *Fake) Adopt(key fleet.Key, launchedAt time.Time) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.insts == nil {
		f.insts = map[string]*fakeInst{}
	}
	f.n++
	id := fmt.Sprintf("i-fake%04d", f.n)
	f.insts[id] = &fakeInst{key: key, launchedAt: launchedAt}
	return id
}
