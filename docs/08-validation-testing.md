# 08 — Validation and Testing

The architecture makes four claims. An untested claim is an assumption, and assumptions about
failure behaviour are wrong more often than not. Each test below states the hypothesis, the
procedure, the expected result, and the evidence to capture for the submission.

Run them in order — each builds on the previous one being green.

---

## Setup: a traffic generator

Every test measures *user-visible impact*, so traffic must be flowing while you break things.

```bash
# Continuous requests, one per second, logging any non-200
while true; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 https://example.com/)
  TS=$(date -u +%H:%M:%S)
  [ "$CODE" = "200" ] && printf '.' || printf '\n%s FAIL %s\n' "$TS" "$CODE"
  sleep 1
done | tee test-run.log
```

For a more rigorous measurement, use `hey` or `k6` and record error rate and p95 latency:

```bash
hey -z 10m -q 10 -c 20 https://example.com/ > baseline.txt
```

Capture a baseline before touching anything: request rate, p95 latency, healthy host count.

---

## Test 1 — Instance failure

**Hypothesis.** Terminating one of two instances causes zero failed user requests, and the Auto
Scaling group restores the fleet to two within about three minutes.

**Procedure**

```bash
# 1. Confirm the starting state: 2 healthy targets in 2 different AZs
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State}' --output table

# 2. Start the traffic generator in another terminal

# 3. Terminate one instance WITHOUT letting the ASG pre-launch a replacement
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id i-0123456789abcdef0 \
  --no-should-decrement-desired-capacity

# 4. Watch target health every 10 s
watch -n 10 "aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text"
```

**Expected timeline**

| Time | Event |
|---|---|
| T+0 | Instance terminating |
| T+0–30 s | Target group marks it `unhealthy` after 2 failed checks × 15 s |
| T+30 s | ALB stops routing to it; target enters `draining` for the 30 s deregistration delay |
| T+~60 s | ASG detects capacity below desired and launches a replacement |
| T+~3 min | Replacement passes health checks, enters `healthy`, starts receiving traffic |

**Success criteria**

- ✅ **Zero non-200 responses** in the traffic log
- ✅ Fleet returns to 2 healthy targets
- ✅ The replacement lands in the same AZ as the terminated instance (the ASG rebalances)

**If it fails.** A burst of 502/503 usually means the health check interval is too slow, or the
deregistration delay is too long relative to the request duration. If no replacement launches,
check the ASG's activity history (`aws autoscaling describe-scaling-activities`) — the usual cause
is an instance profile or launch template error.

**Evidence to capture.** Screenshot of the target group during the transition (one `healthy`, one
`draining`), the ASG activity history, and the tail of `test-run.log` showing an unbroken run of
successes.

---

## Test 2 — Availability Zone failure

**Hypothesis.** Losing all capacity in one AZ leaves the application serving from the other, with
no user-visible failure.

You cannot switch off a real AZ, so simulate it by removing all of the AZ's capacity at once.

**Procedure**

```bash
# 1. Note which instances are in AZ-a
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $PROJECT-asg \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone}' --output table

# 2. Traffic generator running

# 3. Terminate every AZ-a instance simultaneously
aws ec2 terminate-instances --instance-ids i-aaa i-bbb

# 4. (Optional, sharper simulation) also remove AZ-a from the ASG so it cannot
#    immediately replace capacity there
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $PROJECT-asg \
  --vpc-zone-identifier "$APP_B"
```

**Expected result**

- The ALB routes 100% of traffic to AZ-b within ~30 s.
- Zero failed requests, assuming the surviving instance can carry full load — which is why the
  design targets 50% CPU.
- The ASG launches replacement capacity in AZ-b (or in AZ-a if you left it in the list).
- p95 latency rises somewhat while a single instance carries the full load.

**Restore**

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $PROJECT-asg \
  --vpc-zone-identifier "$APP_A,$APP_B"
```

**Success criteria**

- ✅ Zero non-200 responses
- ✅ Traffic continues from the surviving AZ
- ✅ p95 latency stays within your service objective under half capacity

**What this test also proves.** If a single instance cannot carry the load, your capacity planning
is wrong: `desired = 2` across 2 AZs means each instance must be able to serve 100% of peak.

---

## Test 3 — Database failover

**Hypothesis.** An RDS Multi-AZ failover completes in 60–120 seconds with no data loss, and the
application reconnects automatically.

**Procedure**

```bash
# 1. Record the current primary AZ
aws rds describe-db-instances --db-instance-identifier $PROJECT-mysql \
  --query 'DBInstances[0].{AZ:AvailabilityZone,Secondary:SecondaryAvailabilityZone}'

# 2. Resolve the writer endpoint's current address
dig +short $PROJECT-mysql.xxxx.eu-west-1.rds.amazonaws.com

# 3. Traffic generator running, ideally including a write path

# 4. Force a failover
aws rds reboot-db-instance --db-instance-identifier $PROJECT-mysql --force-failover

# 5. Watch the endpoint's resolution change
watch -n 5 "dig +short $PROJECT-mysql.xxxx.eu-west-1.rds.amazonaws.com"

# 6. Confirm the AZs have swapped
aws rds describe-db-instances --db-instance-identifier $PROJECT-mysql \
  --query 'DBInstances[0].{AZ:AvailabilityZone,Secondary:SecondaryAvailabilityZone}'

# 7. Read the failover event
aws rds describe-events --source-identifier $PROJECT-mysql \
  --source-type db-instance --duration 30 \
  --query 'Events[].{Time:Date,Message:Message}' --output table
```

**Expected result**

- The writer endpoint resolves to a new IP within 60–120 s.
- `AvailabilityZone` and `SecondaryAvailabilityZone` have swapped.
- An RDS event of category `failover` is recorded.
- The application returns errors for the duration of the failover, then recovers **without a
  restart**.
- Any transaction acknowledged before the failover is present afterwards — RPO = 0.

**Success criteria**

- ✅ Failover completes within 120 s
- ✅ No committed data lost
- ✅ The application reconnects on its own

**If the application does not recover.** This is the most valuable possible outcome of this test,
because it means you found a real bug before production did. The two usual causes:

1. **DNS caching.** The runtime cached the resolved IP forever. In Java, set
   `networkaddress.cache.ttl=5`.
2. **Connection pool holding dead connections.** Set a `maxLifetime` shorter than typical, enable
   a validation query, and add retry-with-backoff on transient connection errors.

**Also verify:** that the ALB health check does **not** query the database. If it does, every
instance fails health checks during the failover, the ASG terminates the whole fleet, and a
90-second database event becomes a full outage. See
[05-scaling-and-resilience.md](05-scaling-and-resilience.md#the-health-check-trap).

---

## Test 4 — Auto Scaling under load

**Hypothesis.** Sustained CPU above 50% triggers scale-out, and capacity returns to baseline after
load subsides.

**Procedure**

```bash
# Option A - synthetic CPU load, applied on every instance via Session Manager
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Name,Values=$PROJECT-web" \
  --parameters 'commands=["dnf install -y stress-ng","stress-ng --cpu 2 --timeout 900s &"]'

# Option B - realistic HTTP load (preferred: it exercises the full path)
hey -z 15m -q 200 -c 100 https://example.com/
```

Watch:

```bash
watch -n 30 "aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $PROJECT-asg \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,InService:length(Instances)}'"

aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name $PROJECT-asg --max-items 10 \
  --query 'Activities[].{Time:StartTime,Cause:Cause}' --output table
```

**Expected timeline**

| Time | Event |
|---|---|
| T+0 | Load begins, CPU climbs above 50% |
| T+~2 min | The target tracking alarm (3 consecutive 1-minute periods) enters `ALARM` |
| T+~3 min | ASG increases desired capacity |
| T+~5 min | New instances pass health checks and receive traffic |
| T+~7 min | Average CPU converges back toward 50% |
| Load stops | CPU drops; after the scale-in cooldown (~15 min) capacity returns to 2 |

**Success criteria**

- ✅ Scale-out triggers automatically
- ✅ New instances are distributed across both AZs
- ✅ p95 latency recovers once new capacity is serving
- ✅ Scale-in returns the fleet to `min = 2`
- ✅ Capacity never exceeds `max = 6`

**Note the asymmetry.** Scale-out is deliberately fast and scale-in deliberately slow — removing
capacity too eagerly causes thrashing, where the group scales in, immediately breaches again, and
scales back out. Expect scale-in to take 10–15 minutes.

---

## Additional checks

### Security verification

```bash
# The ALB must NOT be reachable directly from the internet
curl -sv --max-time 10 http://$ALB_DNS_NAME/ ; echo "exit: $?"
# Expect a timeout — sg-alb only accepts the CloudFront prefix list

# WAF must block an obvious injection attempt
curl -s -o /dev/null -w '%{http_code}\n' "https://example.com/?id=1%27%20OR%20%271%27=%271"
# Expect 403

# No instance should have a public IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$PROJECT-web" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,PublicIp:PublicIpAddress}' --output table
# PublicIp must be None for every row

# IMDSv2 must be required
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$PROJECT-web" \
  --query 'Reservations[].Instances[].MetadataOptions.HttpTokens' --output text
# Expect "required"

# No security group anywhere should allow port 22 from the internet
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[?IpPermissions[?FromPort==`22`]].GroupName'
# Expect an empty list
```

### CloudFront caching verification

```bash
# Static assets must be cached at the edge
curl -sI https://example.com/static/app.css | grep -i x-cache
# Expect "Hit from cloudfront" on the second request

# Dynamic responses must NOT be cached
curl -sI https://example.com/ | grep -i x-cache
# Expect "Miss from cloudfront" every time
```

A `Hit from cloudfront` on a dynamic, authenticated page means the `Default (*)` behaviour is
caching. Fix it before anything else — it is the most damaging misconfiguration in this
architecture.

### Encryption verification

```bash
aws rds describe-db-instances --db-instance-identifier $PROJECT-mysql \
  --query 'DBInstances[0].{Encrypted:StorageEncrypted,MultiAZ:MultiAZ,Public:PubliclyAccessible}'
# Expect Encrypted=true, MultiAZ=true, Public=false

aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=$PROJECT-web" \
  --query 'Volumes[].{Id:VolumeId,Encrypted:Encrypted}' --output table
```

---

## Results template

Record these for the submission.

| # | Test | Date | Result | Downtime | Notes |
|---|---|---|---|---|---|
| 1 | Instance failure | | ☐ Pass ☐ Fail | | |
| 2 | AZ failure | | ☐ Pass ☐ Fail | | |
| 3 | Database failover | | ☐ Pass ☐ Fail | | |
| 4 | Auto Scaling under load | | ☐ Pass ☐ Fail | | |
| 5 | Security checks | | ☐ Pass ☐ Fail | | |
| 6 | Caching behaviour | | ☐ Pass ☐ Fail | | |

**Evidence to attach:** target group health during each transition, ASG scaling activity history,
the RDS failover event, CloudWatch graphs covering the test window, and the traffic generator log.
