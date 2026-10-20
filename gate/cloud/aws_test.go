package cloud

import (
	"context"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"

	"nix-build-heaven/gate/fleet"
)

type fakeEC2 struct {
	EC2API
	runs     []string // type/subnet per RunInstances call
	fail     map[string]string
	instance types.Instance
}

func (f *fakeEC2) DescribeSubnets(context.Context, *ec2.DescribeSubnetsInput, ...func(*ec2.Options)) (*ec2.DescribeSubnetsOutput, error) {
	return &ec2.DescribeSubnetsOutput{Subnets: []types.Subnet{
		{SubnetId: aws.String("s-a"), AvailabilityZone: aws.String("az-a")},
		{SubnetId: aws.String("s-b"), AvailabilityZone: aws.String("az-b")},
	}}, nil
}

func (f *fakeEC2) DescribeSpotPriceHistory(context.Context, *ec2.DescribeSpotPriceHistoryInput, ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error) {
	p := func(t, az, v string) types.SpotPrice {
		return types.SpotPrice{InstanceType: types.InstanceType(t), AvailabilityZone: aws.String(az), SpotPrice: aws.String(v)}
	}
	// big.2 is not offered in az-a.
	return &ec2.DescribeSpotPriceHistoryOutput{SpotPriceHistory: []types.SpotPrice{
		p("big.1", "az-a", "0.90"), p("big.1", "az-b", "0.80"), p("big.2", "az-b", "0.50"),
	}}, nil
}

func (f *fakeEC2) RunInstances(_ context.Context, in *ec2.RunInstancesInput, _ ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error) {
	k := string(in.InstanceType) + "/" + aws.ToString(in.SubnetId)
	f.runs = append(f.runs, k)
	if code, ok := f.fail[k]; ok {
		return nil, &smithy.GenericAPIError{Code: code}
	}
	return &ec2.RunInstancesOutput{Instances: []types.Instance{{InstanceId: aws.String("i-1")}}}, nil
}

func (f *fakeEC2) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	return &ec2.DescribeInstancesOutput{Reservations: []types.Reservation{{Instances: []types.Instance{f.instance}}}}, nil
}

func newAWS(f *fakeEC2) *AWS {
	return &AWS{EC2: f, InstanceTypes: []string{"big.1", "big.2"}, Owner: "o", Port: 50051,
		UserData: func() ([]byte, error) { return []byte("{}"), nil }}
}

func TestLaunchPrefersTypeOrderThenCheapestAZ(t *testing.T) {
	f := &fakeEC2{fail: map[string]string{"big.1/s-b": "InsufficientInstanceCapacity", "big.1/s-a": "InsufficientInstanceCapacity"}}
	if _, err := newAWS(f).Launch(context.Background(), "k"); err != nil {
		t.Fatal(err)
	}
	want := []string{"big.1/s-b", "big.1/s-a", "big.2/s-b"}
	if len(f.runs) != len(want) {
		t.Fatalf("runs %v, want %v", f.runs, want)
	}
	for i := range want {
		if f.runs[i] != want[i] {
			t.Fatalf("runs %v, want %v", f.runs, want)
		}
	}
}

func TestLaunchStopsOnNonCapacityError(t *testing.T) {
	f := &fakeEC2{fail: map[string]string{"big.1/s-b": "UnauthorizedOperation"}}
	if _, err := newAWS(f).Launch(context.Background(), "k"); err == nil || len(f.runs) != 1 {
		t.Fatalf("err %v after %v; want one attempt and an error", err, f.runs)
	}
}

func TestListMapsTagsStateAndAddress(t *testing.T) {
	at := time.Unix(1000, 0)
	f := &fakeEC2{instance: types.Instance{
		InstanceId: aws.String("i-9"), LaunchTime: &at, PublicIpAddress: aws.String("203.0.113.7"),
		State: &types.InstanceState{Name: types.InstanceStateNameRunning},
		Tags:  []types.Tag{{Key: aws.String("nbh:key"), Value: aws.String("k1")}},
	}}
	seen, err := newAWS(f).List(context.Background())
	if err != nil || len(seen) != 1 {
		t.Fatal(seen, err)
	}
	s := seen[0]
	if s.Key != "k1" || s.State != fleet.Running || s.Addr != "203.0.113.7:50051" || !s.LaunchedAt.Equal(at) {
		t.Fatalf("%+v", s)
	}
}
