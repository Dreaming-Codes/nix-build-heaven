// Package cloud is the boundary between the gate and EC2. The gate only needs
// three calls; everything EC2-specific (fleet request shape, user-data, tags)
// lives in the implementation.
package cloud

import (
	"context"

	"nix-build-heaven/gate/fleet"
)

type Cloud interface {
	// Launch starts one builder tagged with key and returns its instance id.
	Launch(ctx context.Context, key fleet.Key) (instanceID string, err error)
	// List returns every instance tagged with this gate's owner, in any state.
	List(ctx context.Context) ([]fleet.Seen, error)
	Terminate(ctx context.Context, instanceID string) error
}
