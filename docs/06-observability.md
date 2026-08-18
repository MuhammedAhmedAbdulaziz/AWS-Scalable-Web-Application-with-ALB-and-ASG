# 06 — Observability

What is measured, what pages a human, and what is only worth looking at during an investigation.

---

## Principles

1. **Alarm on symptoms users feel, not on causes.** High CPU is not an outage — it is what a
   healthy, well-utilised instance looks like. 5xx responses and elevated latency are outages.
2. **Every alarm must have an action.** If nobody would do anything about it at 03:00, it is a
   dashboard widget, not an alarm.
3. **`treat-missing-data` matters.** For "instance is unhealthy", missing data means the target
   group has no targets at all — that is worse than the breach. Use `breaching` there and
   `notBreaching` for metrics that are simply absent when there is no traffic.
4. **Alarm on the ratio, not the count.** 50 5xx responses out of 50 requests is an outage; 50 out
   of 5 000 000 is background noise. Use metric math.

---

## Metrics worth watching

### ALB — `AWS/ApplicationELB`

| Metric | Meaning | Alarm |
|---|---|---|
| `HTTPCode_ELB_5XX_Count` | The ALB itself failed — no healthy targets, or it could not reach any | Yes |
| `HTTPCode_Target_5XX_Count` | The application returned 5xx | Yes, as a ratio |
| `TargetResponseTime` | Time from request forwarded to response received — the application's real latency | Yes, on p95 |
| `UnHealthyHostCount` | Targets failing health checks | Yes |
| `HealthyHostCount` | Targets serving | Yes, when < 2 |
| `RequestCount` | Traffic volume | Dashboard |
| `RejectedConnectionCount` | The ALB hit its connection limit | Dashboard |
| `TargetConnectionErrorCount` | The ALB could not open a connection to a target | Dashboard |

Use **p95**, not `Average`, for `TargetResponseTime`. An average hides the tail: 95 requests at
50 ms and 5 at 10 s average to 547.5 ms and look unremarkable, while one user in twenty is waiting
ten seconds.

### EC2 / Auto Scaling — `AWS/EC2`, `AWS/AutoScaling`

| Metric | Notes |
|---|---|
| `CPUUtilization` | Drives the scaling policy. Alarm only at a sustained extreme (>90% for 15 min) |
| `StatusCheckFailed_Instance` | The OS is unresponsive |
| `StatusCheckFailed_System` | The underlying host has failed — recovery requires a stop/start |
| `CPUCreditBalance` | **T-family only, and important.** A `t3.micro` earns CPU credits. T3 instances launch in `unlimited` mode by default, so exhausting the balance does not throttle — it bills surplus vCPU-hours at a flat rate, and the cost appears silently on the bill. In `standard` mode (`CreditSpecification.CpuCredits=standard`) the instance is instead throttled to its 10% baseline and everything gets slow while CPU reads *low*. Alarm on this either way |
| `GroupInServiceInstances` | Current fleet size. **Requires `enable-metrics-collection` on the ASG** — group metrics are free but off by default |
| `GroupDesiredCapacity` | Persistent divergence from in-service means launches are failing |

**Memory and disk are not in `AWS/EC2`.** The hypervisor cannot see inside the instance. The
CloudWatch Agent must be installed to publish `mem_used_percent` and `disk_used_percent` to the
`CWAgent` namespace. A disk filling up is a very common cause of a mysteriously unhealthy
instance, and without the agent you are blind to it.

### RDS — `AWS/RDS`

| Metric | Notes |
|---|---|
| `CPUUtilization` | Sustained > 80% means it is time to scale up or optimise queries |
| `DatabaseConnections` | Approaching `max_connections` causes application errors, not slowness |
| `FreeableMemory` | Falling toward zero means the buffer pool no longer fits — read latency will climb sharply |
| `FreeStorageSpace` | Alarm well before zero; a full disk stops writes |
| `ReadLatency` / `WriteLatency` | Storage-level latency |
| `ReplicaLag` | Read replicas and Multi-AZ DB **clusters** only. A Multi-AZ DB *instance* standby replicates synchronously and publishes no `ReplicaLag`, so this metric has no data in this design |
| `BurstBalance` | gp2 only, analogous to CPU credits for storage IOPS |

### CloudFront — `AWS/CloudFront` (always in `us-east-1`)

| Metric | Notes |
|---|---|
| `Requests` | Edge request volume |
| `BytesDownloaded` | Egress volume, drives cost |
| `4xxErrorRate` / `5xxErrorRate` | A 5xx rate spike usually means the origin is failing |
| `CacheHitRate` | For `/static/*` this should be > 90%. A drop means a cache key or TTL change |

CloudFront metrics are only ever published to `us-east-1`. Cross-region dashboard widgets are
required if the rest of your dashboard lives elsewhere.

### WAF — `AWS/WAFV2`

| Metric | Notes |
|---|---|
| `BlockedRequests` | By rule. A spike on one rule is either an attack or a false positive |
| `CountedRequests` | What *would* have been blocked — the metric to watch during count-mode rollout |
| `AllowedRequests` | Baseline |

---

## Alarms

| # | Alarm | Condition | Missing data | Severity |
|---|---|---|---|---|
| 1 | Unhealthy targets | `UnHealthyHostCount > 0` for 2 × 60 s | `notBreaching` | Warning |
| 2 | Insufficient healthy targets | `HealthyHostCount < 2` for 2 × 60 s | **`breaching`** | **Critical** |
| 3 | Application 5xx rate | `HTTPCode_Target_5XX_Count / RequestCount > 0.01` for 2 × 60 s | `notBreaching` | Critical |
| 4 | ALB 5xx | `HTTPCode_ELB_5XX_Count > 10` for 2 × 60 s | `notBreaching` | Critical |
| 5 | Latency | p95 `TargetResponseTime > 1 s` for 3 × 60 s | `notBreaching` | Warning |
| 6 | Sustained high CPU | `CPUUtilization > 90%` for 15 × 60 s | `notBreaching` | Warning |
| 7 | CPU credits exhausted | `CPUCreditBalance < 20` for 5 × 60 s | `notBreaching` | Warning |
| 8 | ASG at maximum | `GroupInServiceInstances >= 6` for 10 × 60 s (needs group metrics enabled) | `notBreaching` | Warning |
| 9 | RDS CPU | `CPUUtilization > 80%` for 10 × 60 s | `notBreaching` | Warning |
| 10 | RDS storage | `FreeStorageSpace < 2 GB` | `breaching` | Critical |
| 11 | RDS connections | `DatabaseConnections > 80%` of max for 5 × 60 s | `notBreaching` | Warning |
| 12 | RDS failover occurred | EventBridge rule on RDS event category `failover` | — | Informational |
| 13 | Disk filling | `disk_used_percent > 85%` (CWAgent) for 5 × 60 s | `notBreaching` | Warning |
| 14 | CloudFront origin errors | `5xxErrorRate > 5%` for 2 × 60 s | `notBreaching` | Critical |
| 15 | WAF block spike | `BlockedRequests > 1000` in 5 min | `notBreaching` | Informational |

Alarm 3, expressed as metric math rather than a raw count:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name saa-p1-5xx-rate \
  --evaluation-periods 2 --threshold 0.01 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions $TOPIC_ARN \
  --metrics '[
    {"Id":"e1","Expression":"IF(m2>10, m1/m2, 0)","Label":"5xx rate","ReturnData":true},
    {"Id":"m1","ReturnData":false,"MetricStat":{"Period":60,"Stat":"Sum","Metric":{
      "Namespace":"AWS/ApplicationELB","MetricName":"HTTPCode_Target_5XX_Count",
      "Dimensions":[{"Name":"LoadBalancer","Value":"'"$ALB_SUFFIX"'"}]}}},
    {"Id":"m2","ReturnData":false,"MetricStat":{"Period":60,"Stat":"Sum","Metric":{
      "Namespace":"AWS/ApplicationELB","MetricName":"RequestCount",
      "Dimensions":[{"Name":"LoadBalancer","Value":"'"$ALB_SUFFIX"'"}]}}}
  ]'
```

The `IF(m2>10, ...)` guard suppresses the alarm at very low traffic, where a single error is 100%
of requests.

### Composite alarms

Reduce noise by paging only when several signals agree:

```bash
aws cloudwatch put-composite-alarm \
  --alarm-name saa-p1-service-degraded \
  --alarm-rule "ALARM(saa-p1-5xx-rate) OR (ALARM(saa-p1-latency-p95) AND ALARM(saa-p1-unhealthy-hosts))" \
  --alarm-actions $CRITICAL_TOPIC_ARN
```

---

## Notification routing

Two SNS topics, because not everything deserves the same urgency:

| Topic | Subscribers | Receives |
|---|---|---|
| `saa-p1-critical` | On-call (email + SMS, or PagerDuty via HTTPS) | Alarms 2, 3, 4, 10, 14 |
| `saa-p1-warnings` | Team email, Slack via Chatbot | Everything else |

An SNS email subscription is *pending* until the recipient clicks the confirmation link. An
unconfirmed subscription silently delivers nothing — verify with:

```bash
aws sns list-subscriptions-by-topic --topic-arn $TOPIC_ARN \
  --query 'Subscriptions[].{Endpoint:Endpoint,Arn:SubscriptionArn}'
# "PendingConfirmation" instead of an ARN means it is not active
```

---

## Logs

| Log | Destination | Retention |
|---|---|---|
| Application logs (`/var/log/httpd/*`) | CloudWatch Logs via CW Agent | 30 days |
| System logs (`/var/log/messages`, `cloud-init-output.log`) | CloudWatch Logs via CW Agent | 30 days |
| ALB access logs | S3, lifecycle to Glacier at 90 days | 1 year |
| CloudFront standard logs | S3 | 90 days |
| WAF logs | Firehose → S3 | 90 days |
| RDS error + slow query logs | CloudWatch Logs | 30 days |
| Session Manager session output | CloudWatch Logs | 1 year |
| VPC Flow Logs | CloudWatch Logs | 14 days |
| CloudTrail | S3 + CloudWatch Logs | 1 year (or Organization trail) |

**Set retention on every log group.** The default is "never expire", and CloudWatch Logs storage
quietly becomes a meaningful line item on a long-running account.

`cloud-init-output.log` is the first thing to read when an instance launches and immediately fails
its health check — it contains the user data script's output, including whatever failed.

### Useful queries

ALB access logs go to S3, not CloudWatch Logs, so the first two queries run in **Athena** over an
external table on the log bucket. Only the third runs in CloudWatch Logs Insights.

```sql
-- Athena: slowest requests in the last hour
fields @timestamp, target_processing_time, request_url, elb_status_code
| filter target_processing_time > 1
| sort target_processing_time desc
| limit 50

-- Athena: 5xx grouped by URL
fields request_url, elb_status_code
| filter elb_status_code >= 500
| stats count() as errors by request_url
| sort errors desc

-- Logs Insights: application errors by instance, to spot a single bad host
fields @timestamp, @message, @logStream
| filter @message like /ERROR/
| stats count() as errors by @logStream
| sort errors desc
```

---

## Dashboard

One dashboard, arranged so the top row answers "is it working?" and lower rows answer "why not?".

| Row | Widgets |
|---|---|
| 1 — Service health | Request count · 5xx rate · p95 latency · healthy host count |
| 2 — Compute | ASG in-service vs desired · average CPU · CPU credit balance · memory (CWAgent) |
| 3 — Database | RDS CPU · connections · freeable memory · free storage |
| 4 — Edge | CloudFront requests · cache hit rate · WAF blocked requests · 4xx/5xx rate |
| 5 — Alarm status | Alarm status widget covering every alarm above |

```bash
aws cloudwatch put-dashboard --dashboard-name saa-p1-overview \
  --dashboard-body file://examples/cloudwatch-dashboard.json
```

---

## What is deliberately not instrumented

- **No distributed tracing.** AWS X-Ray is the right answer once there is more than one service to
  trace between. A single web tier plus a database does not need it yet.
- **No synthetic monitoring.** CloudWatch Synthetics canaries would catch failures the internal
  metrics cannot see (DNS, certificate expiry, a broken checkout flow). Worth adding; costs
  roughly $0.0012 per canary run.
- **No RUM.** Real User Monitoring measures what browsers actually experience, which is the only
  metric users care about. Also worth adding for a real production application.
