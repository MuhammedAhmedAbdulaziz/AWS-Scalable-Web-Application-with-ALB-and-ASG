# 09 — Well-Architected Review

A self-assessment against the six pillars of the AWS Well-Architected Framework. The value of this
exercise is the "gaps" column, not the score.

| Pillar | Assessment |
|---|---|
| Operational excellence | Adequate — good observability, weak automation |
| Security | Strong |
| Reliability | Strong within one region, absent across regions |
| Performance efficiency | Good |
| Cost optimisation | Reasonable, with known unexploited levers |
| Sustainability | Fair |

---

## Operational Excellence

**Design principles applied**

- Operations as code, in part — the architecture is documented and reproducible, and instance
  configuration is in the launch template rather than applied by hand.
- Small, reversible changes — instance refresh with checkpoints allows a rollback at 50%.
- Anticipate failure — the four resilience tests in
  [08-validation-testing.md](08-validation-testing.md) are run deliberately, not discovered.
- Learn from failure — CloudTrail, flow logs and session logging provide the material for a
  post-incident review.

**Gaps**

| Gap | Impact | Remediation |
|---|---|---|
| No infrastructure as code | Environments drift; rebuilding is manual and error-prone | Terraform or CloudFormation for the whole stack |
| No CI/CD pipeline | Deployments are manual `start-instance-refresh` calls | CodePipeline / GitHub Actions with an automated instance refresh and rollback on alarm |
| No runbooks for common incidents | Response time depends on who is on call | SSM Automation documents for the top five failure modes |
| Patching is not scheduled | Instances drift from the current AMI | SSM Patch Manager with a maintenance window, plus periodic instance refresh onto the latest AMI |

---

## Security

**Design principles applied**

- Strong identity foundation — IAM roles, no long-lived keys, no SSH keys anywhere.
- Traceability — CloudTrail, VPC Flow Logs, ALB and CloudFront access logs, WAF logs, Session
  Manager session logging.
- Security at all layers — seven layers, enumerated in [04-security.md](04-security.md).
- Automated protection — WAF managed rule groups update themselves as AWS adds signatures.
- Data protection in transit and at rest — TLS everywhere externally, KMS on all storage.
- Reduced blast radius — private subnets, chained security groups, scoped instance role, no egress
  route from the data tier.
- Prepared for events — logging is in place; incident response automation is not.

**Gaps**

| Gap | Impact | Remediation |
|---|---|---|
| No GuardDuty | Threat detection is manual | Enable GuardDuty (account-wide, low cost) |
| No AWS Config | Configuration drift goes unnoticed | Config rules for "no public S3", "encrypted volumes", "no 0.0.0.0/0 on 22" |
| No Security Hub | No central posture view | Enable with the AWS Foundational Security Best Practices standard |
| ALB → EC2 is plaintext | In-VPC traffic unencrypted | Terminate TLS on the instance if required by compliance |
| Single account | No isolation between environments | AWS Organizations / Control Tower with per-environment accounts |
| No automated secret rotation for application secrets | Manual rotation is skipped | Secrets Manager rotation Lambda (the RDS master password already rotates) |

---

## Reliability

**Design principles applied**

- Automatically recover from failure — ASG replaces unhealthy instances; RDS fails over on its own.
- Test recovery procedures — the four tests exist and are meant to be run.
- Scale horizontally — many small instances rather than one large one.
- Stop guessing capacity — target tracking adjusts capacity to demand.
- Manage change through automation — instance refresh, immutable-ish deployments.

**Quantified**

| Component | Redundancy | RTO | RPO |
|---|---|---|---|
| Web tier | 2 AZs, `min = 2` | 0 (transparent) | n/a |
| Load balancer | AWS-managed, multi-AZ | 0 | n/a |
| Database | Multi-AZ synchronous standby | 60–120 s | 0 |
| Egress | NAT gateway per AZ | 0 | n/a |
| Static assets | S3 (11 nines durability) + CloudFront | 0 | 0 |
| **Region** | **none** | **not covered** | **not covered** |

**Gaps**

| Gap | Impact | Remediation |
|---|---|---|
| Single region | A regional outage is a full outage | Pilot-light DR: cross-region snapshot copies, IaC to rebuild, Route 53 failover records |
| Backups not tested | An untested backup is not a backup | Quarterly restore drill from a snapshot |
| No service quota monitoring | An account limit can block scaling in an incident | CloudWatch alarms on Service Quotas usage metrics |
| Manual failover to the DR path | Slow and error-prone under pressure | Route 53 health-check-driven failover records |

---

## Performance Efficiency

**Design principles applied**

- Democratise advanced technology — CloudFront, WAF, RDS and ELB are managed services; no
  bespoke caching or load balancing to operate.
- Go global in minutes — CloudFront serves from edge locations worldwide.
- Use serverless where it fits — not applied here; noted below.
- Experiment often — instance types can be changed by editing the launch template.
- Mechanical sympathy — ALB for HTTP, CloudFront for static content, RDS for relational data.

**Gaps**

| Gap | Impact | Remediation |
|---|---|---|
| `t3.micro` is burstable | T3 launches in `unlimited` mode by default, so sustained load quietly bills surplus vCPU-hours rather than throttling; in `standard` mode it throttles to 10% of a vCPU instead | Alarm on `CPUCreditBalance`; move to `m7i`/`c7i` for steady load, or set `CpuCredits=standard` if a predictable bill matters more than predictable performance |
| No caching layer | Every request that needs data hits RDS | ElastiCache for Redis for sessions and hot reads |
| No read replicas | Read scaling requires vertical scaling of the primary | Add read replicas and route reads to the reader endpoint |
| No CDN tuning | Default TTLs may be suboptimal | Review `CacheHitRate`; tune `Cache-Control` headers at the origin |
| Boot time gates scale-out | ~3 minutes from decision to serving | Golden AMI via EC2 Image Builder; consider warm pools |

---

## Cost Optimisation

**Design principles applied**

- Consumption model — Auto Scaling matches capacity to demand.
- Measure efficiency — tagging strategy defined; Cost Explorer and Budgets available.
- Stop spending on undifferentiated heavy lifting — managed services throughout.
- Analyse and attribute expenditure — cost allocation tags on every resource.

**Gaps**

| Gap | Annual impact | Remediation |
|---|---|---|
| No Savings Plan | ~$60/year on compute | One-year no-upfront Compute Savings Plan on the baseline |
| x86 instead of Graviton | ~$95/year | `t4g.micro` / `db.t4g.micro` |
| No Spot for burst capacity | Up to 90% on above-baseline capacity | Mixed instances policy |
| Two NAT gateways in non-production | ~$395/year per environment | One NAT gateway, or VPC endpoints only |
| Non-production runs 24×7 | ~70% of non-production spend | EventBridge schedule to scale to zero overnight |
| No S3 lifecycle policies | Grows unbounded | Transition logs to Glacier at 90 days, expire at 1 year |

---

## Sustainability

**Design principles applied**

- Maximise utilisation — a 50% CPU target is a deliberate trade of utilisation for response time,
  which is defensible but not optimal for efficiency.
- Use managed services — AWS runs them at far higher aggregate utilisation than a single tenant
  could.
- Reduce downstream impact — CloudFront serves cached content from the edge, avoiding origin
  compute and long-haul network transfer entirely.

**Gaps**

| Gap | Remediation |
|---|---|
| Graviton not used | arm64 instances deliver materially better performance per watt |
| Non-production runs overnight | Scheduled scale-to-zero |
| No object lifecycle management | Old logs occupy storage indefinitely |
| Region not chosen for carbon intensity | `eu-north-1` (Stockholm) runs on a notably low-carbon grid |

---

## Summary

**The architecture is strongest on security and reliability** — the two pillars the brief targets.
Private subnets, chained security groups, no SSH, WAF at the edge, IMDSv2, encryption everywhere,
`min = 2` across two AZs, and a synchronous database standby together make the design resistant to
both the common attack paths and the common failure modes.

**The clearest gap is operational: there is no infrastructure as code.** Every recommendation in
the operational excellence section flows from that one. The stack is documented well enough to
rebuild by hand, which is not the same as being able to rebuild it reliably.

**The clearest architectural limit is that it is single-region.** That is a deliberate scope
decision rather than an oversight, but it should be stated plainly: this design survives the loss
of an Availability Zone, not the loss of a Region.

### Prioritised next steps

| Priority | Action | Pillar |
|---|---|---|
| 1 | Codify the stack in Terraform or CloudFormation | Operational excellence |
| 2 | Enable GuardDuty, Config and Security Hub | Security |
| 3 | Add ElastiCache for sessions and hot reads | Performance |
| 4 | Move to Graviton and buy a Savings Plan | Cost, sustainability |
| 5 | Build the pilot-light DR path in a second region | Reliability |
| 6 | Add a CI/CD pipeline with automated instance refresh | Operational excellence |
