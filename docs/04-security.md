# 04 — Security

Defence in depth: each layer assumes the layer in front of it has already failed.

```
Layer 1   Edge         AWS WAF managed rules, CloudFront, TLS 1.2+
Layer 2   Perimeter    Security groups (chained), no public IPs on compute
Layer 3   Network      Private subnets, no egress route from the data tier, NACLs
Layer 4   Identity     IAM instance profile, least privilege, IMDSv2
Layer 5   Data         KMS encryption at rest, TLS in transit, Secrets Manager
Layer 6   Access       Session Manager, no SSH keys, no bastion
Layer 7   Audit        CloudTrail, VPC Flow Logs, ALB access logs, session logging
```

---

## Layer 1 — Edge

### AWS WAF web ACL

Scope `CLOUDFRONT`, which is always created in `us-east-1` regardless of where the rest of the
stack lives. Four AWS managed rule groups, evaluated in priority order:

| Priority | Rule group | Blocks |
|---|---|---|
| 1 | `AWSManagedRulesAmazonIpReputationList` | Sources on Amazon's threat intelligence list — bots, scanners, known malicious IPs |
| 2 | `AWSManagedRulesCommonRuleSet` | The core OWASP-style set: XSS, path traversal, oversized bodies, PHP/LFI patterns |
| 3 | `AWSManagedRulesKnownBadInputsRuleSet` | Request patterns associated with known CVEs, including Log4Shell (`${jndi:`) |
| 4 | `AWSManagedRulesSQLiRuleSet` | SQL injection in query strings, bodies, headers and cookies |

Plus one custom rule:

| Priority | Rule | Action |
|---|---|---|
| 10 | Rate-based rule, 2 000 requests per 5-minute window per source IP | Block |

`examples/waf-rules.json` — a bare JSON array, which is what `--rules file://...` expects:

```json
[
  { "Name": "AWS-AmazonIpReputationList", "Priority": 1,
    "Statement": { "ManagedRuleGroupStatement":
      { "VendorName": "AWS", "Name": "AWSManagedRulesAmazonIpReputationList" } },
    "OverrideAction": { "None": {} },
    "VisibilityConfig": { "SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true,
      "MetricName": "AmazonIpReputationList" } },

  { "Name": "AWS-CommonRuleSet", "Priority": 2,
    "Statement": { "ManagedRuleGroupStatement":
      { "VendorName": "AWS", "Name": "AWSManagedRulesCommonRuleSet" } },
    "OverrideAction": { "None": {} },
    "VisibilityConfig": { "SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true,
      "MetricName": "CommonRuleSet" } },

  { "Name": "AWS-KnownBadInputs", "Priority": 3,
    "Statement": { "ManagedRuleGroupStatement":
      { "VendorName": "AWS", "Name": "AWSManagedRulesKnownBadInputsRuleSet" } },
    "OverrideAction": { "None": {} },
    "VisibilityConfig": { "SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true,
      "MetricName": "KnownBadInputs" } },

  { "Name": "AWS-SQLi", "Priority": 4,
    "Statement": { "ManagedRuleGroupStatement":
      { "VendorName": "AWS", "Name": "AWSManagedRulesSQLiRuleSet" } },
    "OverrideAction": { "None": {} },
    "VisibilityConfig": { "SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true,
      "MetricName": "SQLiRuleSet" } },

  { "Name": "RateLimitPerIP", "Priority": 10,
    "Statement": { "RateBasedStatement": { "Limit": 2000, "AggregateKeyType": "IP" } },
    "Action": { "Block": {} },
    "VisibilityConfig": { "SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true,
      "MetricName": "RateLimitPerIP" } }
]
```

**Deploy in count mode first.** Set each managed rule group's override action to `Count` for a
week, watch the `CountedRequests` metric and the sampled requests, and identify legitimate traffic
that would have been blocked — file uploads and rich-text editors trip the common rule set
routinely. Switch to `None` (i.e. use the group's own block actions) once the false positives are
excluded. Turning WAF on in block mode on day one is how you take down your own application.

**What WAF does not do.** It inspects request syntax; it has no idea whether the requester is
authorised. It will not stop a valid session performing an action it should not be allowed to
perform. Authentication and authorisation remain the application's job.

### CloudFront and TLS

- Minimum protocol version `TLSv1.2_2021`; the ALB listener uses
  `ELBSecurityPolicy-TLS13-1-2-2021-06`.
- Viewer protocol policy `redirect-to-https` on every behaviour; the ALB's port 80 listener does
  nothing but issue a 301 (`sg-alb` allows 80 from the CloudFront prefix list purely so that
  listener is reachable).
- Origin protocol policy **HTTPS only** — traffic between the edge and the ALB is encrypted, not
  just the viewer-facing hop.
- Certificates come from ACM (free, auto-renewing). CloudFront requires its certificate in
  `us-east-1`; the ALB requires one in its own region. You need both.
- Response headers policy adding HSTS, `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, and a Content-Security-Policy.

---

## Layer 2 — Security groups

Rules reference **other security groups**, never CIDR blocks:

| Group | Direction | Protocol / port | Source or destination |
|---|---|---|---|
| `sg-alb` | Inbound | TCP 443 | Prefix list `com.amazonaws.global.cloudfront.origin-facing` |
| `sg-alb` | Inbound | TCP 80 | Same prefix list — reaches the HTTP→HTTPS redirect listener only |
| `sg-alb` | Outbound | TCP 80 | `sg-web` |
| `sg-web` | Inbound | TCP 80 | `sg-alb` |
| `sg-web` | Outbound | TCP 3306 | `sg-rds` |
| `sg-web` | Outbound | TCP 443 | `0.0.0.0/0` (package repos, AWS APIs) |
| `sg-rds` | Inbound | TCP 3306 | `sg-web` |
| `sg-rds` | Outbound | — | none |

Three properties follow from referencing groups instead of CIDRs:

1. **Rules stay correct as instances change.** A new instance launched by the ASG is authorised
   the moment it joins `sg-web` — there is no list of IPs to update.
2. **A private IP cannot impersonate a tier.** Something else in `10.0.10.0/24` that is not in
   `sg-web` still cannot reach the database, which a CIDR rule would have allowed.
3. **The rules document the architecture.** `sg-rds ← sg-web` states the intended data flow.

The CloudFront prefix list on `sg-alb` is what makes the origin unreachable directly. Without it,
anyone who discovers the ALB's DNS name can bypass CloudFront and therefore bypass WAF entirely.
Belt and braces: have CloudFront add a secret custom header (`X-Origin-Verify`) and have the ALB
listener reject requests that lack it.

Security groups are **stateful** — allowing inbound 443 automatically permits the response. There
is never a need for an outbound rule to permit a reply.

---

## Layer 3 — Network isolation

- The web tier has **no public IP address**. `MapPublicIpOnLaunch` is false on the app subnets and
  the launch template does not request one. An instance with no public IP is not routable from the
  internet regardless of any security group mistake.
- The data tier has **no route to `0.0.0.0/0`**. See [02-network-design.md](02-network-design.md).
- `nacl-data` is a stateless second layer at the data subnet boundary.
- VPC Flow Logs on the VPC, delivered to CloudWatch Logs, capturing `REJECT` at minimum — this is
  the evidence trail when you need to answer "did anything try to reach the database?"

---

## Layer 4 — Identity

### IAM

The instance profile carries two AWS managed policies plus one scoped inline policy:

| Policy | Grants |
|---|---|
| `AmazonSSMManagedInstanceCore` | Session Manager, Parameter Store reads, agent registration |
| `CloudWatchAgentServerPolicy` | `PutMetricData`, log stream creation |
| Inline (below) | The specific secret and S3 prefix this application uses |

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadOwnDatabaseSecret",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:rds!db-*" },
    { "Sid": "StaticAssetsReadOnly",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::saa-p1-static/*" }
  ]
}
```

Note what is absent: no `s3:*`, no `ec2:*`, no wildcard resources. If the application is
compromised, the credentials it exposes are worth exactly one secret and one bucket prefix.

### IMDSv2

`HttpTokens=required` in the launch template. IMDSv1 answers a plain `GET` to
`169.254.169.254`, which means any server-side request forgery in the application can be pointed
at the metadata service and used to read the instance's temporary IAM credentials. IMDSv2 requires
a `PUT` to obtain a session token first, and `HttpPutResponseHopLimit=1` stops the token from
being retrieved through a proxy or a container network hop.

This single setting closes the most commonly exploited path from "application bug" to "AWS
credentials".

### Human access

Nobody uses IAM users with long-lived access keys. Access is via IAM Identity Center or assumed
roles with MFA. Root is used for nothing and has hardware MFA.

---

## Layer 5 — Data protection

| Where | Control |
|---|---|
| RDS storage, backups, snapshots, read replicas | KMS encryption, enabled at creation (it cannot be added later — you must snapshot, copy with encryption, restore) |
| EBS volumes | `Encrypted: true` in the launch template; enable EBS encryption by default at the account level |
| S3 buckets | SSE-S3 or SSE-KMS, plus a bucket policy denying `s3:PutObject` without encryption and denying non-TLS requests |
| In transit, viewer → edge | TLS 1.2+ |
| In transit, edge → ALB | HTTPS only |
| In transit, ALB → EC2 | HTTP inside the VPC. Acceptable for most compliance regimes; terminate TLS on the instance if yours requires end-to-end encryption |
| In transit, EC2 → RDS | TLS with `require_secure_transport=ON` in the parameter group, using the RDS CA bundle |

### Secrets

`--manage-master-user-password` has RDS create the master credential in Secrets Manager and rotate
it on a schedule. The application retrieves it at runtime with `GetSecretValue` using its instance
role. There is no password in user data, in an environment variable baked into an AMI, in a
configuration file, or in anyone's shell history.

Non-secret configuration (feature flags, endpoint names, the AMI parameter) lives in SSM Parameter
Store, which is free for standard parameters.

---

## Layer 6 — Administrative access

No SSH. No key pair. No bastion. No inbound port 22 rule anywhere in the account.

```bash
aws ssm start-session --target i-0123456789abcdef0
```

The mechanism: the SSM Agent maintains an **outbound** connection to the Systems Manager service;
session I/O is multiplexed over it. Because the connection originates from the instance, no
inbound security group rule exists to be attacked.

What that buys you:

| Property | Consequence |
|---|---|
| Authorisation is IAM | Grant with a policy, revoke with a policy. Scope by tag: `ssm:resourceTag/Environment` |
| Every session is in CloudTrail | `StartSession` events with the principal, target and timestamp |
| Session output can be logged | Stream keystrokes and output to CloudWatch Logs or S3 for audit |
| No key material | Nothing to leak, rotate, or find in a git repository |
| Port forwarding without SSH | `aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost` tunnels to RDS for a local client |

Example scoped policy — an engineer may only open sessions on instances tagged `Environment=dev`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ssm:StartSession"],
    "Resource": "arn:aws:ec2:*:*:instance/*",
    "Condition": { "StringEquals": { "ssm:resourceTag/Environment": "dev" } }
  }]
}
```

---

## Layer 7 — Audit

| Source | Destination | Answers |
|---|---|---|
| CloudTrail (all regions, log file validation on) | S3 + CloudWatch Logs | Who called which API, when, from where |
| VPC Flow Logs | CloudWatch Logs | What tried to talk to what, and was it rejected |
| ALB access logs | S3, lifecycle to Glacier at 90 days | Every HTTP request, its status, latency and client |
| CloudFront standard logs | S3 | Edge-level request detail, cache hit ratio |
| WAF logs | Kinesis Data Firehose → S3 | Which requests matched which rule |
| Session Manager logs | CloudWatch Logs | What was typed in every shell session |
| RDS error and slow query logs | CloudWatch Logs | Database-level errors and slow statements |

ALB access log delivery needs a bucket policy. Current guidance uses the service principal
`logdelivery.elasticloadbalancing.amazonaws.com`; the older per-region ELB account ID policy is
still supported for regions that existed before August 2022, but AWS recommends the service
principal form:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "logdelivery.elasticloadbalancing.amazonaws.com" },
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::saa-p1-logs/alb/AWSLogs/111122223333/*",
    "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control" } }
  }]
}
```

---

## Threat model summary

| Threat | Control |
|---|---|
| SQL injection, XSS, path traversal | WAF managed rule groups at the edge |
| Volumetric DDoS | CloudFront absorption + AWS Shield Standard (automatic, free) |
| Application-layer flood | WAF rate-based rule, 2 000 req/5 min per IP |
| Direct-to-origin bypass of WAF | `sg-alb` restricted to the CloudFront prefix list + secret origin header |
| Stolen SSH key | There is no SSH key |
| Credential theft via SSRF | IMDSv2 required, hop limit 1 |
| Lateral movement from a compromised instance | Instance role limited to one secret and one S3 prefix; `sg-rds` allows only 3306 from `sg-web` |
| Data exfiltration from the database tier | No egress route on the data route table |
| Snapshot or backup theft | KMS encryption on storage, snapshots and backups |
| Accidental public S3 exposure | Account-level and bucket-level public access block; OAC instead of public objects |
| Insider action without a trace | CloudTrail, session logging, flow logs |

---

## Deliberate gaps

Honest scope statement — these are correct next steps, not oversights:

- **No AWS Shield Advanced.** $3 000/month; Shield Standard is adequate for this workload.
- **No GuardDuty, Security Hub or Config.** All three belong in a real production account. They
  are account-wide services, outside the scope of a single workload's architecture.
- **TLS terminates at the ALB.** ALB → EC2 is plaintext inside the VPC.
- **No WAF bot control or account takeover prevention.** Both are paid add-ons worth adding once
  there is a login flow to protect.
- **Single account, single region.** Multi-account (Control Tower) and DR to a second region are
  the next architectural steps, not this project's scope.
