package cloud

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"

	"nix-build-heaven/gate/fleet"
)

// EC2API is the slice of the EC2 client the gate uses, so tests can fake it.
type EC2API interface {
	RunInstances(context.Context, *ec2.RunInstancesInput, ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error)
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error)
	DescribeSubnets(context.Context, *ec2.DescribeSubnetsInput, ...func(*ec2.Options)) (*ec2.DescribeSubnetsOutput, error)
	DescribeSpotPriceHistory(context.Context, *ec2.DescribeSpotPriceHistoryInput, ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error)
}

// AWS launches one Spot builder per Launch from the nbh-builder launch
// template. It walks InstanceTypes in the given order (first is preferred)
// and, within a type, the tagged subnets from cheapest current Spot price up,
// moving on when EC2 has no capacity there. Every instance carries
// nbh:managed=true, nbh:owner and nbh:key, which is all List needs to rebuild
// the gate's state after a restart.
type AWS struct {
	EC2            EC2API
	LaunchTemplate string
	InstanceTypes  []string
	Owner          string
	Port           int
	// MaxPrice caps the hourly Spot price; empty means the on-demand price.
	MaxPrice string
	// UserData returns fresh per-launch user-data (a new 3 h server certificate).
	UserData func() ([]byte, error)
	Log      *log.Logger
}

const (
	tagManaged = "nbh:managed"
	tagOwner   = "nbh:owner"
	tagKey     = "nbh:key"
)

func (a *AWS) logf(f string, v ...any) {
	if a.Log != nil {
		a.Log.Printf(f, v...)
	}
}

type placement struct {
	itype, subnet, az string
	price             float64
}

// plan orders (type, subnet) pairs: types in configured order, subnets by
// the latest Spot price in their AZ. A failed price lookup keeps the order.
func (a *AWS) plan(ctx context.Context) ([]placement, error) {
	sn, err := a.EC2.DescribeSubnets(ctx, &ec2.DescribeSubnetsInput{
		Filters: []types.Filter{{Name: aws.String("tag:" + tagManaged), Values: []string{"true"}}},
	})
	if err != nil {
		return nil, fmt.Errorf("describe subnets: %w", err)
	}
	if len(sn.Subnets) == 0 {
		return nil, errors.New("no subnet tagged nbh:managed=true")
	}
	prices := map[string]float64{} // type/az -> $/h
	sp, err := a.EC2.DescribeSpotPriceHistory(ctx, &ec2.DescribeSpotPriceHistoryInput{
		InstanceTypes:       toTypes(a.InstanceTypes),
		ProductDescriptions: []string{"Linux/UNIX"},
		StartTime:           aws.Time(time.Now()),
	})
	if err != nil {
		a.logf("spot price lookup failed, keeping configured order: %v", err)
	} else {
		for _, p := range sp.SpotPriceHistory {
			v, _ := strconv.ParseFloat(aws.ToString(p.SpotPrice), 64)
			prices[string(p.InstanceType)+"/"+aws.ToString(p.AvailabilityZone)] = v
		}
	}
	var out []placement
	for _, t := range a.InstanceTypes {
		var row []placement
		for _, s := range sn.Subnets {
			az := aws.ToString(s.AvailabilityZone)
			p, ok := prices[t+"/"+az]
			if !ok && err == nil {
				continue // type not offered as Spot in this AZ
			}
			row = append(row, placement{t, aws.ToString(s.SubnetId), az, p})
		}
		sort.SliceStable(row, func(i, j int) bool { return row[i].price < row[j].price })
		out = append(out, row...)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no Spot offer for %v in the tagged subnets", a.InstanceTypes)
	}
	return out, nil
}

func toTypes(s []string) []types.InstanceType {
	out := make([]types.InstanceType, len(s))
	for i, v := range s {
		out[i] = types.InstanceType(v)
	}
	return out
}

// retryElsewhere says whether another type or AZ could succeed.
func retryElsewhere(err error) bool {
	var ae smithy.APIError
	if !errors.As(err, &ae) {
		return false
	}
	switch ae.ErrorCode() {
	case "InsufficientInstanceCapacity", "SpotMaxPriceTooLow", "InsufficientCapacity",
		"Unsupported", "InstanceLimitExceeded", "MaxSpotInstanceCountExceeded",
		"VcpuLimitExceeded", "InvalidParameterCombination":
		return true
	}
	return false
}

func (a *AWS) Launch(ctx context.Context, key fleet.Key) (string, error) {
	ud, err := a.UserData()
	if err != nil {
		return "", fmt.Errorf("user-data: %w", err)
	}
	plan, err := a.plan(ctx)
	if err != nil {
		return "", err
	}
	tags := []types.Tag{
		{Key: aws.String(tagManaged), Value: aws.String("true")},
		{Key: aws.String(tagOwner), Value: aws.String(a.Owner)},
		{Key: aws.String(tagKey), Value: aws.String(string(key))},
		{Key: aws.String("Name"), Value: aws.String("nbh-builder " + string(key))},
	}
	spec := func(rt types.ResourceType) types.TagSpecification {
		return types.TagSpecification{ResourceType: rt, Tags: tags}
	}
	spot := &types.SpotMarketOptions{
		SpotInstanceType:             types.SpotInstanceTypeOneTime,
		InstanceInterruptionBehavior: types.InstanceInterruptionBehaviorTerminate,
	}
	if a.MaxPrice != "" {
		spot.MaxPrice = aws.String(a.MaxPrice)
	}
	var last error
	for _, p := range plan {
		out, err := a.EC2.RunInstances(ctx, &ec2.RunInstancesInput{
			MinCount:       aws.Int32(1),
			MaxCount:       aws.Int32(1),
			InstanceType:   types.InstanceType(p.itype),
			LaunchTemplate: &types.LaunchTemplateSpecification{LaunchTemplateName: aws.String(a.LaunchTemplate), Version: aws.String("$Default")},
			SubnetId:       aws.String(p.subnet),
			InstanceMarketOptions: &types.InstanceMarketOptionsRequest{
				MarketType:  types.MarketTypeSpot,
				SpotOptions: spot,
			},
			UserData: aws.String(base64.StdEncoding.EncodeToString(ud)),
			TagSpecifications: []types.TagSpecification{
				spec(types.ResourceTypeInstance), spec(types.ResourceTypeVolume),
				spec(types.ResourceTypeNetworkInterface), spec(types.ResourceTypeSpotInstancesRequest),
			},
		})
		if err == nil && len(out.Instances) == 1 {
			id := aws.ToString(out.Instances[0].InstanceId)
			a.logf("launched %s %s in %s at spot $%.4f/h", id, p.itype, p.az, p.price)
			return id, nil
		}
		last = err
		if err != nil && !retryElsewhere(err) {
			return "", err
		}
		a.logf("no %s in %s: %v", p.itype, p.az, err)
	}
	return "", fmt.Errorf("every type and AZ failed, last: %w", last)
}

func (a *AWS) List(ctx context.Context) ([]fleet.Seen, error) {
	in := &ec2.DescribeInstancesInput{Filters: []types.Filter{
		{Name: aws.String("tag:" + tagManaged), Values: []string{"true"}},
		{Name: aws.String("tag:" + tagOwner), Values: []string{a.Owner}},
	}}
	var out []fleet.Seen
	p := ec2.NewDescribeInstancesPaginator(a.EC2, in)
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, r := range page.Reservations {
			for _, i := range r.Instances {
				s := fleet.Seen{
					InstanceID: aws.ToString(i.InstanceId),
					LaunchedAt: aws.ToTime(i.LaunchTime),
				}
				for _, t := range i.Tags {
					if aws.ToString(t.Key) == tagKey {
						s.Key = fleet.Key(aws.ToString(t.Value))
					}
				}
				if i.State != nil {
					s.State = fleet.CloudState(i.State.Name)
				}
				if ip := aws.ToString(i.PublicIpAddress); ip != "" && s.State == fleet.Running {
					s.Addr = net.JoinHostPort(ip, strconv.Itoa(a.Port))
				}
				out = append(out, s)
			}
		}
	}
	return out, nil
}

func (a *AWS) Terminate(ctx context.Context, id string) error {
	_, err := a.EC2.TerminateInstances(ctx, &ec2.TerminateInstancesInput{InstanceIds: []string{id}})
	var ae smithy.APIError
	if errors.As(err, &ae) && strings.HasPrefix(ae.ErrorCode(), "InvalidInstanceID") {
		return nil // already gone
	}
	return err
}
