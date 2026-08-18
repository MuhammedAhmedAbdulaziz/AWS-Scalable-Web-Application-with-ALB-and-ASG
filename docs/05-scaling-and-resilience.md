# 05 — Scaling and Resilience

How the architecture grows under load, and precisely what happens when each component fails.

---

## The Auto Scaling group

```
min = 2      never fewer than one instance per AZ
desired = 2  steady state
max = 6      cost ceiling — the point at which you want a human to look
```

The ASG spans `subnet-private-app-a` and `subnet-private-app-b` and balances capacity across them automatically.
It rebalances after an AZ recovers, and it will not concentrate all capacity in one AZ unless the
other is unavailable.

### Why `min = 2` is the design's load-bearing number

| | `min = 1` | `min = 2` |
|---|---|---|
| Instance failure | Detected in ~30 s, replacement launches, boots, health-checks — **~3 minutes of downtime** | ALB stops routing to the failed target in ~30 s — **zero downtime** |
| AZ failure | Same 3-minute gap, in the surviving AZ | Surviving instance already warm and serving |
| Monthly cost | ~$7.60 | ~$15.20 |

The extra $7.60 buys the difference between "recovery requires launching a machine" and "recovery
requires changing a routing decision". Every other resilience property in this document depends on
it.

### Health check type

`--health-check-type ELB` rather than the default `EC2`:

| Type | Checks | Misses |
|---|---|---|
| `EC2` (default) | Instance state and hypervisor status checks | A running instance whose web server is hung or returning 500 |
| `ELB` | The target group's HTTP health check | Nothing relevant to serving traffic |

With `ELB`, an instance the target group marks unhealthy is terminated and replaced by the ASG.
With `EC2`, it stays in the group indefinitely, unhealthy but "running".

### Grace period and warmup

- **`health-check-grace-period = 300 s`** — health checks are ignored for the first five minutes
  after launch. Too short and the instance is killed while still installing packages, producing an
  infinite launch/terminate loop; too long and a genuinely broken instance lingers.
- **`default-instance-warmup = 120 s`** — a newly launched instance's metrics are excluded from
  the ASG's aggregate until it has warmed up. Without this, a booting instance reporting 5% CPU
  drags the group average down and the scaling policy immediately scales back in.

---

## Scaling policies

### Target tracking (the one in use)

```json
{
  "PredefinedMetricSpecification": { "PredefinedMetricType": "ASGAverageCPUUtilization" },
  "TargetValue": 50.0,
  "DisableScaleIn": false
}
```

EC2 Auto Scaling creates and manages the CloudWatch alarms behind this policy and computes the
capacity change needed to converge on the target. It is a thermostat: you set the temperature,
not the furnace duty cycle.

Available predefined metrics:

| Metric | Use when |
|---|---|
| `ASGAverageCPUUtilization` | The workload is CPU bound — the common case |
| `ALBRequestCountPerTarget` | Cost per request is stable and CPU is a poor proxy |
| `ASGAverageNetworkIn` / `Out` | The workload is network bound |
| Custom metric | Queue depth, p95 latency, active connections |

**Why 50% and not 80%.** Scaling is not instant:

```
breach persists                ~1 min   (alarm evaluation)
launch + boot + app start      ~2 min
health checks pass             ~30 s
──────────────────────────────────────
total                          ~3.5 min
```

For three and a half minutes, the existing instances carry the entire increase. Starting from 50%
they have 50 points of headroom; starting from 80% they have 20 and will saturate before help
arrives. A lower target costs more in steady state and buys response time — that is the trade,
and it should be made consciously.

**When CPU is the wrong metric.** If the application is I/O or memory bound, CPU stays flat while
latency climbs and the ASG never reacts. Symptom: response times degrade under load but the
scaling policy never fires. Fix: scale on `ALBRequestCountPerTarget` or a custom p95 latency
metric.

### Step scaling (documented alternative)

Useful when the response should be proportional to the size of the breach — a 10-point overshoot
warrants one instance, a 40-point overshoot warrants four:

| Breach above threshold | Add |
|---|---|
| 0 – 10 points | +1 instance |
| 10 – 30 points | +2 instances |
| > 30 points | +4 instances |

Step scaling requires you to design the alarms and adjustments yourself. Both policy types can
coexist on the same ASG; EC2 Auto Scaling applies the most aggressive scale-out and the most
conservative scale-in.

### Scheduled scaling (complementary)

For predictable patterns — pre-warm to 4 instances at 08:00 on weekdays, return to 2 at 20:00.
Scheduled actions change min/max/desired and combine with target tracking, which continues to
handle unpredictable variation on top.

### Scale-in protection

Scale-in terminates instances. Two guards:

- **Termination policy** — the `Default` policy, which first balances across AZs, then prefers
  instances running an older launch template version, then the one closest to the next billing
  hour. `OldestInstance` is a separate opt-in policy if you want strict fleet refresh by age.
- **Instance scale-in protection** — set on instances doing long-running work so they are not
  terminated mid-job. Applies to scaling actions only; it does not prevent manual termination.

---

## Instance refresh — zero-downtime deployment

Deployment is a launch template version bump followed by:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name saa-p1-asg \
  --preferences '{
    "MinHealthyPercentage": 100,
    "InstanceWarmup": 120,
    "CheckpointPercentages": [50, 100],
    "CheckpointDelay": 300
  }'
```

`MinHealthyPercentage: 100` launches replacements before terminating originals, so capacity never
drops. The checkpoints pause the refresh after 50% for five minutes, giving alarms time to fire on
a bad build before it reaches the whole fleet. Roll back by reverting the launch template version
and starting another refresh.

This is only safe because the web tier is stateless — see ADR-010.

---

## The data tier

RDS Multi-AZ DB instance deployment: one primary, one synchronous standby in the other AZ.

**Failover triggers:** AZ outage, primary instance failure, storage failure, network partition,
instance class change, OS patching, or a manual `reboot --force-failover`.

**Failover sequence:**

1. RDS detects the primary is unhealthy.
2. The **writer endpoint DNS record** is updated to point at the standby.
3. The standby is promoted to primary.
4. A new standby is provisioned in the original AZ once it recovers.

Typical completion: **60–120 seconds**. Data loss: **none** — replication is synchronous, so a
transaction is not acknowledged until it is durable in both AZs. RPO = 0.

### What the application must do

The endpoint name does not change; only the address behind it does. Two requirements follow:

1. **Do not cache the DNS resolution beyond its TTL.** A JVM configured with
   `networkaddress.cache.ttl = -1` caches forever and will keep talking to the old primary's IP
   after a failover, failing until the process restarts.
2. **Reconnect on failure.** Every in-flight connection drops during failover. The connection pool
   needs a validation query, a bounded `maxLifetime`, and the application needs retry with
   backoff on transient connection errors.

### The health check trap

If the ALB health check path queries the database, then during a 90-second failover **every**
instance fails its health check simultaneously. The ALB marks them all unhealthy, the ASG (with
`health-check-type ELB`) terminates them all, and the replacements also fail because the database
is still failing over. A 90-second database blip becomes a total outage requiring manual recovery.

**Rule: the ALB health check must be shallow.** It answers "can this instance serve requests?",
not "is the whole system healthy?". Check dependencies on a separate `/health/deep` endpoint that
feeds a CloudWatch alarm — alerting a human, not driving termination.

---

## Failure mode analysis

| Failure | Detection | Recovery | User impact |
|---|---|---|---|
| One EC2 instance dies | ALB health check, 2 × 15 s = 30 s | ALB stops routing; ASG replaces in ~3 min | None — the other instance serves |
| Application hangs (process alive, not responding) | ALB health check | Same as above, because health check type is `ELB` | None |
| Entire AZ fails | ALB + ASG + RDS all detect independently | ALB routes to the surviving AZ; RDS fails over in 60–120 s; ASG launches replacement capacity | Up to ~2 min of write errors; reads continue |
| RDS primary fails | RDS internal monitoring | Automatic failover, 60–120 s | Connection errors during failover; no data loss |
| NAT gateway A fails | CloudWatch metrics | AZ-a instances lose egress; AZ-b unaffected (this is why there are two) | None for inbound traffic |
| ALB node fails | ELB internal | ELB replaces the node; DNS has multiple A records | None |
| Deployment ships a bad build | CloudWatch alarms during the checkpoint pause | Instance refresh paused at 50%; revert the launch template | Half the fleet, briefly |
| Traffic spike 10× | Target tracking alarm, ~1 min | Scale out to `max = 6` over ~7 min | Elevated latency during the ramp; CloudFront absorbs the static share |
| Region fails | — | **Not covered.** Single-region design | Full outage |
| Accidental data deletion | — | Point-in-time recovery to any second in the 7-day window | Restore is a new instance; requires a cutover |

---

## Recovery objectives

| Scenario | RTO | RPO |
|---|---|---|
| Instance failure | 0 (transparent) | 0 |
| AZ failure | ~2 min for writes, 0 for reads | 0 |
| Database failure | 60–120 s | 0 |
| Accidental data deletion | ~30 min (PITR restore + cutover) | 5 min (PITR granularity) |
| Region failure | Not covered | Not covered |

---

## Scaling beyond this design

In the order you would actually hit the limits:

1. **Read-heavy database load** → RDS read replicas; point read queries at the reader endpoint.
2. **Session or query hot spots** → ElastiCache for Redis in a fourth subnet tier; also the right
   place for session state once the database becomes the bottleneck.
3. **Write-heavy database load** → vertical scaling first, then Aurora (up to 15 replicas,
   sub-second replica lag), then sharding.
4. **Slow scale-out** → a golden AMI from EC2 Image Builder; boot time drops from minutes to
   seconds because nothing is installed at launch.
5. **Global users** → CloudFront already helps; add a second region with Route 53 latency-based
   routing and Aurora Global Database.
6. **Cost per request** → containerise onto ECS Fargate or EKS for higher density, or move
   spiky/event-driven components to Lambda.
7. **Predictable diurnal load** → predictive scaling, which uses machine learning on historical
   patterns to scale *before* the load arrives rather than after.
