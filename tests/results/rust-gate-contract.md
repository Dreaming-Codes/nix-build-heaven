# nbh-gate behaviour contract, Go to Rust

The Go tests at a43385e (`go test -race ./...` green, `tests/results/go-test-race.log`)
pinned what the gate does. ssh-ng is now the only transport, so the contract is
hold mode: a connection that arrives while no builder serves is held, then
spliced or released. Each row names the Go test, the behaviour it pins, and the
Rust test that asserts the same thing. "grpc only" rows are dropped with the
transport.

## fleet (pure reducer), Go `fleet/fleet_test.go` and `fleet/hold_test.go`

| Go test or case | Behaviour | Rust test (`src/fleet.rs`) |
|---|---|---|
| Gone, demand: launch and refuse | demand with nothing running launches one builder; in hold mode the connection is held, not refused | `demand_with_nothing_running_launches_and_holds` |
| Gone, demand while unavailable | release at once, no launch | `demand_while_unavailable_releases_without_launch` |
| Gone, demand at capacity (previous terminating) / TestHoldRelaunchesWhenPreviousIsGone | no launch until the old builder is gone, then one launch | `demand_while_previous_terminates_launches_once_it_is_gone` |
| Requested, second demand / Booting, demand | no second launch | `second_demand_while_requested_or_booting_does_not_launch_again` |
| Requested, fleet returned instance: Booting | Launched moves to Booting | covered by the two tests below and `tagged_instance_seen_before_launched_returns_boots` |
| Requested, fleet error / TestHoldReleasesOnLaunchFailure | release held, machines off, unavailable | `launch_failure_releases_held_and_empties_machines` |
| Booting, address known: probe | probe every ProbeEvery once the address is known | `booting_with_an_address_is_probed_every_probe_interval`, `booting_without_an_address_is_not_probed` |
| Booting, probe ok / TestHoldSplicesEveryHeldConnectionOnServing | Serving; every held connection spliced once; warm arrival spliced | `probe_ok_splices_every_held_connection_once` |
| Booting, 150 s / TestHoldReleasesOnBootTimeout | terminate, release held, machines off | `boot_timeout_terminates_releases_and_empties_machines` |
| TestBootTimeoutCountsFromBootingNotLaunch | timeout counts from entering Booting | `boot_timeout_counts_from_booting_not_launch` |
| Serving, new connection | splice at once | `serving_splices_new_connections_at_once` |
| Serving idle for idleGrace: Draining; Draining idle after recheck: Terminating; TestTerminateAfterDrainTiming | terminate IdleGrace + DrainRecheck after the last close (60 + 5 s). Draining only existed to poll grpc scheduler load, so it is now one idle grace of 65 s | `serving_idle_for_idle_grace_terminates`, `idle_grace_runs_from_the_last_close` |
| Serving, idle just under idleGrace: poll load; builder reports load; Draining load cases | grpc only (nix-grpc-daemon Prometheus gauges) | dropped |
| Serving with a live connection never drains | open connection keeps it up | `serving_with_an_open_connection_never_idles` |
| connection closed: live drops, busy now | close restarts the idle clock | `idle_grace_runs_from_the_last_close` |
| Serving, shutting down (Spot interruption) | terminate | `spot_interruption_terminates_then_ends_the_session` |
| Serving, terminated / Terminating, terminated / vanished | Gone with SessionEnded and billed time | `serving_instance_seen_terminated_ends_the_session`, `terminating_instance_that_vanished_ends_the_session` |
| Terminating, retry | terminate again after TerminateRetry | `terminating_retries_after_the_retry_interval` |
| any phase, max session | terminate even while busy | `max_session_terminates_even_while_busy` |
| Requested, tagged instance seen before Launched | Booting from the snapshot | `tagged_instance_seen_before_launched_returns_boots` |
| reconcile fails with nothing running / while serving | machines off / stay on | `demand_while_unavailable_releases_without_launch`, `reconcile_failure_while_serving_keeps_machines_on` |
| unavailability expires | machines back on | `machines_come_back_when_unavailability_expires` |
| first event publishes machines file | | `first_event_publishes_machines` |
| TestNoLaunchBeforeFirstReconcile / TestHoldLaunchesAfterFirstReconcile | held until the first reconcile, then launch | `no_launch_before_first_reconcile` |
| TestCrashRecoveryAdoptsRunningInstanceWithoutKillingIt | adopt running as Booting, skip terminated, kill stopped, probe not kill for age, splice | `restart_adopts_running_kills_stopped_and_skips_terminated` |
| TestReconcileIsIdempotent | | `reconcile_is_idempotent` |
| TestBuilderOutlivesRetryGapAfterRefusal | grpc only (RetryHold after a refusal) | dropped |

## gate (sockets, fake cloud), Go `gate/gate_test.go` and `gate/hold_test.go`

| Go test | Behaviour | Rust test (`src/gate.rs`) |
|---|---|---|
| TestHoldColdStartSplicesFirstAttempt | 3 concurrent first attempts held through a 1.5 s boot and spliced, one launch | `cold_start_holds_every_connection_and_splices_its_first_attempt` |
| TestHoldBootTimeoutReleasesWithFIN, TestBootTimeoutTerminatesAndFallsBack | FIN not reset, 0.7 to 3 s, builder terminated, machines empty | `boot_timeout_releases_with_a_fin_and_terminates` |
| TestFallbackWhenCloudUnreachable | machines empty, plain close under 1 s, no launch | `cloud_unreachable_empties_machines_and_closes_at_once` |
| TestFallbackWhenLaunchFails | released within 2 s, machines empty | `launch_failure_releases_the_held_connection` |
| TestTerminateAfterDrain | up while a connection is open; terminated 1.3 to 2 s after the last close | `terminates_idle_grace_after_the_last_connection_closes` |
| TestRestartAdoptsRunningBuilder | spliced to the adopted builder, no launch, terminated when idle | `restart_adopts_a_running_builder` |
| TestColdStartDoesNotWaitForPeriodicReconcile | 500 ms boot, hourly reconcile, spliced under 2 s | `cold_start_does_not_wait_for_the_periodic_reconcile` |
| TestColdStartRefusesUntilBuilderServes | grpc only (reset and client retry) | dropped |
| TestParseLoad | grpc only (scheduler gauges) | dropped |

## cloud and certs

| Go test | Behaviour | Rust test |
|---|---|---|
| TestLaunchPrefersTypeOrderThenCheapestAZ | type order, then cheapest AZ, skip AZs without a Spot offer, move on for capacity errors | `ec2::launch_prefers_type_order_then_cheapest_az_and_moves_on_for_capacity`, `ec2::without_prices_every_subnet_is_tried_in_order` |
| TestLaunchStopsOnNonCapacityError | one attempt and an error | `ec2::launch_stops_on_an_error_no_placement_avoids` |
| TestListMapsTagsStateAndAddress | nbh:key, state, public IP and port, launch time from DescribeInstances | `ec2::list_maps_tags_state_and_address` (parses EC2 XML) |
| (new) | SigV4 signature equals botocore's for the same request | `ec2::signature_matches_botocore` |
| TestSSHHostCertTrustedOnlyViaOurCA | host cert validates only against our CA, only while valid; principal nbh-builder; known_hosts line. The stranger-client-key and root refusals are sshd's job and stay in the ssh-coldstart VM test | `pki::host_cert_is_trusted_only_through_our_ca_and_only_while_valid`, `pki::init_writes_known_hosts_for_the_ca_and_keeps_existing_keys` |
| certs_test.go (TLS CA, server cert, user-data TLS fields) | grpc only | dropped; `pki::user_data_carries_host_key_cert_and_client_key` covers the ssh-ng user-data |

Mutation spot checks (measured, 2026-10-21 00:13 UTC+2): releasing with a
plain drop instead of FIN and drain fails 3 gate tests; launching before the
first reconcile fails 2; a close that does not restart the idle clock fails 1.
