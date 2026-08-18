# 01 — Architecture Decision Records

Each record states the decision, the reasoning, the alternatives that were rejected, and the
consequences that come with it. The point of writing them down is that the consequences are the
part people forget.

---

## ADR-001 — Three-tier subnet layout instead of two

**Decision.** Split the VPC into three subnet tiers per AZ — public, private-app, private-data —
rather than the more common public/private pair.

**Reasoning.** Route tables and network ACLs attach to subnets, not to instances. If the
application and the database share a subnet, they must share a route table, which means the
database inherits the application's default route to the NAT gateway. The database subnets in
this design have **no route to `0.0.0.0/0` at all**. That is not a rule that can be misconfigured,
bypassed by a permissive security group, or removed by a hurried change — the packet has nowhere
to go. For an exfiltration path to exist, someone must add a route, which is a visible,
auditable action.

**Rejected.** A two-tier layout (public + private). It is simpler and one fewer route table, but
it gives up the "no egress path" property, and the property is the whole reason to isolate a data
tier.

**Consequences.** Six subnets instead of four. RDS needs a DB subnet group listing the two data
subnets. Any future service that genuinely needs egress from the data tier (a database that calls
out to a licence server, for example) needs an explicit VPC endpoint rather than a NAT route.

---

## ADR-002 — Two Availability Zones, `min = 2` on the Auto Scaling group

**Decision.** Every tier spans exactly two AZs, and the ASG minimum size is 2 — one instance per
AZ.

**Reasoning.** Two is the smallest number that provides AZ redundancy, and the brief specifies
two. The critical detail is `min = 2`, not the AZ count. An ASG with `min = 1` spanning two AZs is
**not** highly available: when the single instance's AZ fails, there is a gap of roughly three
minutes — the ASG detecting the failure, then launching, booting and health-checking a replacement
in the other AZ — during which the site is down. With `min = 2` and one instance already warm in
the second AZ, the ALB simply stops sending traffic to the failed target and the remaining
instance absorbs the load. The recovery is a routing change measured in seconds, not a launch
measured in minutes.

**Rejected.** Three AZs. It is more resilient and reduces the per-AZ capacity loss from 50% to
33%, but it adds a third NAT gateway (~$33/month) for a workload where losing half of two
instances is already survivable. The design is deliberately structured so that adding a third AZ
means adding subnets and extending the ASG's AZ list — no other change.

**Consequences.** Each instance must be able to serve 100% of peak traffic on its own, because
during an AZ failure it will have to. `t3.micro` at 50% target CPU is sized with that in mind.

---

## ADR-003 — One NAT gateway per AZ

**Decision.** Deploy a NAT gateway in each public subnet, and point each private-app subnet's
default route at the NAT gateway in its *own* AZ.

**Reasoning.** A NAT gateway is a zonal resource. If both AZs route through a single NAT gateway
and that AZ fails, the surviving AZ's instances lose all outbound connectivity — package
installs, external API calls, and any application dependency on an internet endpoint break, even
though the instances themselves are healthy. This is one of the most common ways a "multi-AZ"
architecture turns out not to be. Cross-AZ NAT also incurs inter-AZ data transfer charges on
every byte.

**Rejected.** A single shared NAT gateway. It saves ~$33/month and is a perfectly reasonable
choice for a development environment — it is listed as the first cost lever in
[07-cost-analysis.md](07-cost-analysis.md) — but it reintroduces a zonal single point of failure
into an architecture whose stated purpose is to not have one.

**Consequences.** Two Elastic IPs, two NAT gateways, and two private route tables instead of one.
NAT gateways are the largest line item in the bill.

---

## ADR-004 — Application Load Balancer, not Network Load Balancer

**Decision.** Use an ALB (Layer 7).

**Reasoning.** The workload is HTTP. An ALB terminates TLS, evaluates host- and path-based listener
rules, performs HTTP health checks against a specific path with a specific expected status code,
and — the deciding factor — is the only load balancer type that AWS WAF can attach to directly.
An NLB operates at Layer 4; it cannot read the request, so it cannot be inspected by WAF and its
health checks can only confirm that a TCP port accepts a connection. A process that is accepting
connections while returning HTTP 500 to every one of them passes an NLB health check and fails an
ALB health check. The ALB is right on both counts.

**Rejected.** NLB (chosen when you need static IPs, extreme throughput, sub-millisecond latency,
or non-HTTP protocols — none apply here). Gateway Load Balancer (for inline virtual appliances,
not for application traffic).

**Consequences.** The ALB's DNS name changes IP addresses over time, so clients must always use
the DNS name, never a resolved IP. Route 53 must use an **alias** record, not a CNAME, so that the
zone apex can point at it.

---

## ADR-005 — RDS Multi-AZ DB instance deployment, not a read replica

**Decision.** Deploy RDS MySQL as a **Multi-AZ DB instance deployment** — one primary with a
synchronous standby in the second AZ.

**Reasoning.** The two features are frequently confused and solve different problems:

| | Multi-AZ DB instance | Read replica |
|---|---|---|
| Replication | Synchronous | Asynchronous |
| Purpose | Availability | Read scalability |
| Standby readable | No | Yes |
| Failover | Automatic, 60–120 s | Manual promotion |
| Data loss on failover | None (RPO = 0) | Possible — replica lag |

The requirement here is availability with no data loss, which is Multi-AZ. A read replica is the
right tool when the *read* workload exceeds one instance, and it is an additive choice — you can
have both.

**Rejected.** A Multi-AZ DB **cluster** deployment (three instances, two readable standbys,
failover typically under 35 seconds) — genuinely better on both availability and read capacity,
but it requires a minimum instance class well above `db.t3.micro` and roughly triples the cost.
Also rejected: self-managed MySQL on EC2, which would mean owning patching, backup, failover
automation and monitoring for no benefit.

**Consequences.** The standby serves no read traffic — you pay for two instances and can use one.
Writes carry the latency of synchronous cross-AZ replication (typically a low single-digit
millisecond penalty). The application must connect through the **writer endpoint** DNS name and
must handle a connection drop during failover by reconnecting; connection pools need a sane
`maxLifetime` so they do not hold stale connections to the old primary.

---

## ADR-006 — Target tracking scaling on average CPU

**Decision.** A single target tracking policy on `ASGAverageCPUUtilization` at 50%.

**Reasoning.** Target tracking is a closed-loop controller: you declare the target, and EC2 Auto
Scaling creates and manages the CloudWatch alarms and computes the capacity change needed to
converge on it. Step scaling requires you to design the alarm thresholds and step adjustments
yourself, and getting them wrong produces either oscillation or sluggish response. Target
tracking is the correct default; step scaling is the escape hatch for when you need
non-proportional responses to specific breach magnitudes.

The 50% target is deliberately low. Scaling is not instantaneous — detecting the breach, launching
an instance, booting the OS, starting the application, and passing enough health checks takes
roughly three minutes. The 50% headroom is what the existing instances use to absorb traffic
during those three minutes. Setting the target to 80% means that by the time capacity arrives, the
existing instances are already saturated.

**Rejected.** Step scaling as the primary policy (kept as a documented option for aggressive
scale-out on large breaches — see [05-scaling-and-resilience.md](05-scaling-and-resilience.md)).
Simple scaling — superseded by both, since it blocks on a cooldown after each action. Scheduled
scaling — useful in addition when traffic is predictably diurnal, not instead.

**Consequences.** CPU must actually be the bottleneck for this to work. If the application is I/O
or memory bound, CPU stays flat while response time degrades and the ASG never reacts. The
mitigation is to scale on `ALBRequestCountPerTarget` or a custom latency metric instead — noted in
the scaling document.

---

## ADR-007 — CloudFront in front of the ALB, not only in front of S3

**Decision.** One CloudFront distribution with two origins: the S3 bucket for `/static/*` and the
ALB for everything else.

**Reasoning.** Putting CloudFront in front of static assets alone is the obvious half of the
benefit. Routing dynamic requests through it as well adds three things that are easy to miss:

1. **TLS terminates at the edge.** The expensive TLS handshake completes at the edge location
   nearest the user, and the connection from edge to origin reuses a warm, persistent connection
   over the AWS backbone. This measurably reduces time-to-first-byte for distant users even
   though the response itself is not cached.
2. **The WAF web ACL attaches at the edge.** Malicious requests are rejected at the edge location
   and never consume ALB capacity, EC2 CPU, or database connections.
3. **The origin can be locked down.** With `sg-alb` accepting traffic only from the
   `com.amazonaws.global.cloudfront.origin-facing` managed prefix list, the ALB is unreachable
   from the open internet — every request must pass through CloudFront and therefore through WAF.

**Rejected.** CloudFront in front of S3 only, with users hitting the ALB directly for dynamic
traffic. Simpler, but the ALB is then internet-facing in the literal sense and WAF must attach to
the ALB separately (which is supported, but at regional scope and after the request has already
crossed the internet to your region).

**Consequences.** The `Default (*)` cache behaviour must be configured to **not** cache: forward
all cookies, all query strings, and the headers the application depends on, with TTL 0. Getting
this wrong caches a logged-in user's page and serves it to someone else — the single most damaging
misconfiguration available in this architecture. Also, the application sees CloudFront's IP as the
client; the real client IP is in the `CloudFront-Viewer-Address` / `X-Forwarded-For` headers.

---

## ADR-008 — Session Manager instead of a bastion host

**Decision.** No bastion host, no SSH key pair, no inbound port 22 rule anywhere.

**Reasoning.** A bastion host is a permanently internet-exposed instance whose entire job is to be
a way in. It has to be patched, monitored, hardened and paid for, its SSH keys have to be
distributed and rotated, and access to it is authenticated by possession of a private key rather
than by an identity your organisation controls.

Session Manager inverts the connection. The SSM Agent on the instance opens an **outbound**
connection to the Systems Manager service; session I/O is tunnelled back down it. Consequences
that follow directly from that inversion:

- No inbound security group rule is required, so there is no inbound attack surface to protect.
- Access is authorised by IAM — the same policies, the same `aws:PrincipalTag` conditions, the
  same MFA requirements as everything else. Revoking access is an IAM change, not a key rotation.
- Every session is recorded in CloudTrail, and session *output* can be streamed to CloudWatch Logs
  or S3. You get a transcript of what was typed, which no bastion gives you by default.
- There is no key material to leak, because there is none.

**Rejected.** A bastion host in the public subnet (all the costs above). EC2 Instance Connect
(convenient, but it still requires an inbound rule for port 22 from the EC2 Instance Connect
service prefix). VPN or Direct Connect (correct for hybrid networks; disproportionate here).

**Consequences.** The instance profile must include `AmazonSSMManagedInstanceCore`. The instance
needs a network path to the SSM endpoints — via the NAT gateway here, or via interface VPC
endpoints if you remove the NAT (which also removes the NAT data-processing charge for SSM
traffic). The SSM Agent is pre-installed on Amazon Linux 2023, so no bootstrap step is required.

---

## ADR-009 — Amazon Linux 2023 with configuration at boot, not a golden AMI

**Decision.** Launch the latest Amazon Linux 2023 AMI (resolved dynamically from the SSM public
parameter) and configure it via launch template user data plus SSM Parameter Store.

**Reasoning.** For a design where instances are disposable, the AMI ID must never be hard-coded —
a pinned AMI silently rots, and every new instance launches with months of unpatched CVEs. The SSM
public parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` always
resolves to the current AMI, so a launch template update and an instance refresh is the whole
patch process.

**Rejected.** A golden AMI built by EC2 Image Builder. It is genuinely better for production —
boot time drops from minutes to seconds because nothing is installed at launch, which directly
improves scale-out responsiveness — but it adds a pipeline to build and maintain. The correct
progression is: start with user data, move to a golden AMI when boot time becomes the constraint
on how fast you can scale.

**Consequences.** Instance boot time includes package installation, which lengthens the scale-out
loop and is part of why the CPU target is 50%. User data runs as root on every launch and must be
idempotent.

---

## ADR-010 — Stateless web tier

**Decision.** No durable state on the instance: no local session store, no uploaded files on the
local disk, no configuration files edited in place.

**Reasoning.** This is the decision the rest of the architecture depends on. Auto Scaling
terminates instances — that is its job. If an instance holds session state, terminating it logs
users out; if it holds uploaded files, terminating it loses them. Every capability the design
claims (scale-out, self-healing, zero-downtime deployment via instance refresh, AZ failure
tolerance) requires that terminating any instance at any moment is harmless.

**Rejected.** ALB sticky sessions as a substitute. They pin a user to an instance, which restores
the appearance of statefulness — until that instance is terminated by a scale-in, at which point
the user loses their session anyway. Stickiness is a valid optimisation for cache locality; it is
not a state-management strategy.

**Consequences.** Sessions live in the database (or in ElastiCache for Redis, the recommended step
when session reads become a database bottleneck). Uploads go directly to S3, ideally via
pre-signed URLs so the bytes never transit the web tier. Configuration is read from SSM Parameter
Store at boot; secrets from Secrets Manager at runtime.

---

## Summary

| ADR | Decision | Primary driver |
|---|---|---|
| 001 | Three subnet tiers | No egress path from the data tier |
| 002 | 2 AZs, ASG `min = 2` | Recovery in seconds, not minutes |
| 003 | NAT gateway per AZ | No zonal single point of failure in egress |
| 004 | ALB over NLB | Layer 7 health checks and WAF attachment |
| 005 | Multi-AZ DB instance | RPO = 0 with automatic failover |
| 006 | Target tracking at 50% | Closed-loop control with headroom for boot time |
| 007 | CloudFront over both origins | Edge TLS, WAF at the edge, lockable origin |
| 008 | Session Manager | Removes the inbound attack surface entirely |
| 009 | Dynamic AMI + user data | Patched by construction |
| 010 | Stateless web tier | Precondition for every other property |
