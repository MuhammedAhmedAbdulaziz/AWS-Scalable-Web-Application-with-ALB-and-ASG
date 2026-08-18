# 07 — Cost Analysis

All figures are **`us-east-1` on-demand list prices**, August 2026, for a month of 730 hours.
us-east-1 is used as the reference because it is the region AWS quotes on its own pricing pages;
`eu-west-1`, where this architecture is deployed, runs a few percent higher on most line items
(NAT gateway $0.048 vs $0.045 per hour, for example), so treat these as a floor. Prices change —
verify with the [AWS Pricing Calculator](https://calculator.aws) before committing to a number.

---

## Baseline: steady state, 2 instances

| Component | Calculation | USD / month | Share |
|---|---|---|---|
| NAT gateway × 2 | 2 × 730 h × $0.045 | **65.70** | 42% |
| NAT data processing | 10 GB × $0.045 | 0.45 | <1% |
| Application Load Balancer | 730 h × $0.0225 | 16.43 | 11% |
| ALB LCU | ~1 LCU × 730 h × $0.008 | 5.84 | 4% |
| EC2 `t3.micro` × 2 | 2 × 730 h × $0.0104 | 15.18 | 10% |
| EBS gp3 × 2 | 2 × 8 GB × $0.08 | 1.28 | <1% |
| RDS `db.t3.micro` Multi-AZ | 730 h × ~$0.034 | 24.82 | 16% |
| RDS storage (gp3, 20 GB, both AZs) | 40 GB × $0.115 | 4.60 | 3% |
| RDS backup storage | 20 GB beyond free allocation | ~1.90 | 1% |
| CloudFront data out | 50 GB × $0.085 | 4.25 | 3% |
| CloudFront requests | 1 M × $0.0100 per 10 000 HTTPS | ~1.00 | <1% |
| AWS WAF | $5.00 web ACL + 5 × $1.00 rules + 1 M × $0.60 | 10.60 | 7% |
| Route 53 | $0.50 hosted zone + queries | 0.90 | <1% |
| S3 (static + logs) | ~10 GB + requests | ~0.50 | <1% |
| CloudWatch | Custom metrics, logs, dashboard | ~2.50 | 2% |
| SNS | Low volume | ~0.10 | <1% |
| ACM certificates | Public certificates are free | 0.00 | — |
| **Total** | | **156.05** | ~100% |

Two things stand out. **NAT gateways are 42% of the bill** — more than compute and the database
combined — and they carry no application logic at all. And **the ALB costs more than the two EC2
instances it balances**, which is normal for small fleets: the ALB is a fixed cost that amortises
as the fleet grows.

### Under load

At `max = 6` instances sustained for a full month, EC2 rises from $15.18 to $45.55 and total cost
to roughly **$186/month**. Scaling out is cheap here because the fixed components — NAT, ALB, RDS
— dominate. The marginal cost of a `t3.micro` is $7.59/month.

---

## Where the money actually goes

```
NAT gateways      ██████████████████████████    42%   66.15
RDS Multi-AZ      ████████████                  20%   31.32
ALB               █████████                     14%   22.27
EC2 + EBS         ███████                       11%   16.46
WAF               ████                           7%   10.60
Everything else   ████                           6%    9.25
```

---

## Cost levers, in order of ratio

### 1. Free S3 gateway endpoint — save ~$0–5/month, no downside

A gateway VPC endpoint for S3 is **free** and routes S3 traffic off the NAT path entirely,
removing the $0.045/GB data-processing charge on every S3 byte. There is no reason not to have
one. Add it to both private route tables.

### 2. One NAT gateway instead of two — save $32.85/month (21%)

The single largest saving available. **Cost: you reintroduce a zonal single point of failure in
egress.** If the NAT gateway's AZ fails, the surviving AZ's instances keep serving inbound traffic
but lose all outbound connectivity.

Correct for development and staging. Wrong for production, in an architecture whose entire premise
is surviving an AZ failure — see [ADR-003](01-architecture-decisions.md).

### 3. Remove NAT gateways entirely — save $66/month

Possible if the instances' only outbound needs are AWS APIs. Replace with interface VPC endpoints:

| Endpoint | ~USD / month |
|---|---|
| `ssm` + `ssmmessages` (+ `ec2messages` in older regions) | ~22 |
| `secretsmanager` | ~7.30 |
| `s3` gateway | free |
| **Total** | **~29** |

Net saving ~$37/month **and** the instances have no internet path at all, which is a security
improvement, not just a cost one. The catch: no `dnf update` from the public repositories, so you
need a golden AMI pipeline or an S3-hosted package mirror. This is the right end state for a
mature production environment.

### 4. Graviton instances — save ~20% on compute

`t4g.micro` is roughly 20% cheaper than `t3.micro` at better price/performance. `db.t4g.micro`
likewise for RDS. The only requirement is that your application stack runs on arm64 — which for a
PHP, Python, Node, Java or Go application it does. Saving: ~$3/month on EC2, ~$5/month on RDS at
this scale; the percentage is what matters as you grow.

### 5. Savings Plans or Reserved Instances — save 30–40% on committed compute

A one-year no-upfront Compute Savings Plan covering the two baseline instances saves ~30%. RDS
Reserved Instances save similarly. Commit only to your **baseline**, not your peak — the ASG's
elastic capacity above the baseline should stay on-demand.

### 6. Spot Instances for burst capacity — save up to 90%

Use a mixed instances policy on the ASG: on-demand for the baseline two, Spot for everything above
it. Because the web tier is stateless and behind an ALB with connection draining, a Spot
interruption (2-minute warning) is handled the same way as any other instance termination.

```json
{
  "MixedInstancesPolicy": {
    "InstancesDistribution": {
      "OnDemandBaseCapacity": 2,
      "OnDemandPercentageAboveBaseCapacity": 0,
      "SpotAllocationStrategy": "price-capacity-optimized"
    }
  }
}
```

### 7. RDS Single-AZ in non-production — save ~$12.50/month per environment

Halves the database cost. **Never in production** — it removes the automatic failover that is the
entire point of the deployment. Perfectly reasonable in dev, where a 20-minute restore is
acceptable.

### 8. CloudWatch log retention — save a few dollars, growing over time

The default log group retention is "never expire". Setting 30 days on application logs and 14 on
flow logs keeps storage flat instead of monotonically increasing.

### 9. S3 lifecycle policies

Transition ALB access logs to Glacier Instant Retrieval at 90 days and expire at one year. Small
in absolute terms, but log buckets grow forever if left alone.

---

## Environment-specific configurations

| Setting | Production | Staging | Development |
|---|---|---|---|
| NAT gateways | 2 | 1 | 1 (or none + endpoints) |
| ASG min / desired / max | 2 / 2 / 6 | 1 / 1 / 2 | 1 / 1 / 2 |
| Instance type | `t3.micro`+ | `t3.micro` | `t3.micro` |
| RDS | Multi-AZ | Single-AZ | Single-AZ, `db.t4g.micro` |
| RDS backup retention | 7 days | 1 day | 0 |
| WAF | Full rule set | Full rule set | None |
| CloudFront | Yes | Yes | No (hit the ALB directly) |
| Deletion protection | On | On | Off |
| Schedule | 24×7 | Stopped nights + weekends | Stopped nights + weekends |
| **~USD / month** | **156** | **~55** | **~25** |

Stopping non-production environments outside working hours (roughly 168 → 50 hours per week) cuts
their hourly-billed components by about 70%. An EventBridge rule that sets the ASG's desired
capacity to zero and stops the RDS instance at 19:00, reversing at 07:00 on weekdays, is a
20-minute job that pays for itself in a fortnight.

> RDS instances can only be stopped for **7 days** at a time, after which AWS starts them again
> automatically. Scheduled stop/start still works; a permanently stopped instance does not.

---

## Free tier

For a new AWS account (first 12 months), the following are covered:

| Covered | Not covered |
|---|---|
| 750 h/month `t2.micro` or `t3.micro` | **NAT gateway** — no free tier at all |
| 750 h/month `db.t3.micro` Single-AZ | **Multi-AZ RDS** — the standby is not free |
| 20 GB RDS storage | **ALB beyond 750 h** |
| 750 h/month ALB + 15 LCU | **WAF** — no free tier |
| 1 TB/month CloudFront out, 10 M requests | |
| 5 GB S3, 100 GB/month general egress | |

The unavoidable cost even on a fresh free-tier account is roughly **$66 for NAT gateways +
~$12 for the RDS standby + ~$10 for WAF ≈ $88/month**. Budget for it, and set a billing alarm
before you deploy:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name billing-over-50-usd \
  --namespace AWS/Billing --metric-name EstimatedCharges \
  --dimensions Name=Currency,Value=USD \
  --statistic Maximum --period 21600 --evaluation-periods 1 \
  --threshold 50 --comparison-operator GreaterThanThreshold \
  --alarm-actions $TOPIC_ARN --region us-east-1
```

Billing metrics are published only to `us-east-1`, regardless of where your resources are.

---

## Tagging for cost allocation

Apply consistently and activate the tags as **cost allocation tags** in Billing → Cost allocation
tags — until you do, they do not appear in Cost Explorer.

| Tag | Example | Purpose |
|---|---|---|
| `Project` | `saa-p1` | Group everything in this stack |
| `Environment` | `prod` / `staging` / `dev` | Compare environment costs |
| `Owner` | `platform-team` | Chargeback |
| `CostCenter` | `CC-1234` | Finance reporting |
| `ManagedBy` | `terraform` / `manual` | Find hand-made resources |

Also enable **AWS Budgets** with a monthly threshold and an alert at 80% of forecast. Cost
Explorer with `Group by: Tag → Project` then answers "what is this project costing?" in one query.
