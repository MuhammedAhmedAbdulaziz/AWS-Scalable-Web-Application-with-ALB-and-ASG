# 02 — Network Design

The VPC is the boundary that every other control depends on. This document covers the address
plan, routing, NAT placement, network ACLs, and the VPC endpoint options.

---

## Address plan

**VPC CIDR: `10.0.0.0/16`** — 65 536 addresses.

The block is far larger than the workload needs, and that is deliberate. A VPC CIDR can be
extended with a secondary block, but subnets cannot be resized after creation and CIDRs cannot
overlap with anything you might later peer with, connect through Transit Gateway, or reach over a
VPN. Choosing a small block to be tidy is how you end up rebuilding the VPC.

The `/24` subnets are grouped by tier in the second octet so the layout is readable at a glance
and future tiers slot in without renumbering:

| Range | Purpose | Used |
|---|---|---|
| `10.0.0.0/24` – `10.0.9.0/24` | Public subnets | 2 of 10 |
| `10.0.10.0/24` – `10.0.19.0/24` | Private application subnets | 2 of 10 |
| `10.0.20.0/24` – `10.0.29.0/24` | Private data subnets | 2 of 10 |
| `10.0.30.0/24` + | Reserved (cache tier, VPC endpoints, third AZ) | — |

### Subnets

| Name | CIDR | AZ | Type | Default route | Usable IPs | Contents |
|---|---|---|---|---|---|---|
| `subnet-public-a` | `10.0.0.0/24` | eu-west-1a | **Public** | Internet gateway | 251 | ALB node, NAT gateway A |
| `subnet-public-b` | `10.0.1.0/24` | eu-west-1b | **Public** | Internet gateway | 251 | ALB node, NAT gateway B |
| `subnet-private-app-a` | `10.0.10.0/24` | eu-west-1a | **Private** | NAT gateway A | 251 | EC2 web tier |
| `subnet-private-app-b` | `10.0.11.0/24` | eu-west-1b | **Private** | NAT gateway B | 251 | EC2 web tier |
| `subnet-private-db-a` | `10.0.20.0/24` | eu-west-1a | **Private** | **none** | 251 | RDS primary |
| `subnet-private-db-b` | `10.0.21.0/24` | eu-west-1b | **Private** | **none** | 251 | RDS standby |

The name carries the type on purpose. A subnet is public or private only because of the default
route in its associated route table — there is no flag on the subnet itself — so encoding it in
the name is the only way the distinction is visible when you are looking at a list of subnet IDs
in the console.

> **AWS reserves five addresses in every subnet:** the network address, the VPC router
> (`x.x.x.1`), the DNS server (`x.x.x.2`), one reserved for future use (`x.x.x.3`), and the
> broadcast address. A `/24` therefore yields 251 usable addresses, not 254.

> **ALB subnet sizing:** an ALB needs at least 8 free IP addresses per subnet to launch, and
> consumes more as it scales out. Never place an ALB in a `/28`.

---

## Routing

Four route tables — one public, one per AZ for the app tier (each pointing at its own AZ's NAT
gateway), and one for the data tier with no default route at all.

### `rtb-public` — associated with both public subnets

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` |
| `0.0.0.0/0` | `igw-xxxxxxxx` |

The `local` route is implicit, cannot be removed, and always wins because routing is
longest-prefix-match — a more specific route beats a less specific one, which is why you can never
accidentally route intra-VPC traffic out through the internet gateway.

**A subnet is "public" only because of this route table.** There is no public/private flag on a
subnet. A subnet whose route table has a default route to an internet gateway is public; anything
else is private. This is the single most misunderstood point in VPC design.

### `rtb-private-a` — associated with `subnet-private-app-a`

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` |
| `0.0.0.0/0` | `nat-xxxxxxxx` (NAT gateway **A**) |

### `rtb-private-b` — associated with `subnet-private-app-b`

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` |
| `0.0.0.0/0` | `nat-yyyyyyyy` (NAT gateway **B**) |

### `rtb-data` — associated with both data subnets

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` |

No default route. RDS reaches nothing outside the VPC, and nothing outside the VPC can be reached
from it. Backups, snapshots, patching and monitoring are all performed by the RDS service itself
on the AWS side of the boundary — they do not traverse your route tables.

---

## Why one NAT gateway per AZ

A NAT gateway lives in one subnet, in one Availability Zone. Consider the shared-NAT variant:

```
subnet-private-app-a ──┐
               ├──► NAT gateway in AZ-a ──► IGW
subnet-private-app-b ──┘
```

When AZ-a fails, the instances in AZ-b are healthy, the ALB is healthy in AZ-b, and the RDS
standby has been promoted in AZ-b — but every outbound connection from AZ-b is dead, because the
NAT gateway it routes through was in AZ-a. Any application that calls an external payment gateway,
fetches from an external API, or refreshes a token from an external identity provider is now
failing, in an architecture that was built specifically to survive this event.

The per-AZ layout keeps each AZ's egress path entirely within that AZ:

```
subnet-private-app-a ──► NAT gateway A (AZ-a) ──► IGW
subnet-private-app-b ──► NAT gateway B (AZ-b) ──► IGW
```

The secondary benefit is cost: cross-AZ traffic to a NAT gateway in another AZ is charged as
inter-AZ data transfer **in addition to** the NAT data-processing charge.

Each NAT gateway needs an Elastic IP. NAT gateways are managed and automatically redundant
*within* their AZ; the redundancy you must provide yourself is *across* AZs.

---

## Network ACLs

Security groups do the real work here; NACLs are a coarse second layer at the subnet boundary.
The essential difference:

| | Security group | Network ACL |
|---|---|---|
| Attaches to | ENI (instance) | Subnet |
| State | **Stateful** — return traffic implicitly allowed | **Stateless** — return traffic needs its own rule |
| Rules | Allow only | Allow **and** deny |
| Evaluation | All rules evaluated | First match by rule number wins |
| Default | Deny all inbound | Default NACL allows everything |

The stateless part is where NACLs bite. If you allow inbound 443 and forget to allow **outbound
ephemeral ports 1024–65535**, the request arrives and the response cannot leave. Every custom
NACL needs ephemeral port rules in the reverse direction.

### `nacl-data` — the one custom NACL in this design

Applied to both data subnets, as a backstop in case a security group is ever misconfigured.

**Inbound**

| Rule | Type | Protocol | Port | Source | Action |
|---|---|---|---|---|---|
| 100 | MySQL | TCP | 3306 | `10.0.10.0/24` | ALLOW |
| 110 | MySQL | TCP | 3306 | `10.0.11.0/24` | ALLOW |
| \* | All | All | All | `0.0.0.0/0` | DENY |

**Outbound**

| Rule | Type | Protocol | Port | Destination | Action |
|---|---|---|---|---|---|
| 100 | Custom TCP | TCP | 1024–65535 | `10.0.10.0/24` | ALLOW |
| 110 | Custom TCP | TCP | 1024–65535 | `10.0.11.0/24` | ALLOW |
| \* | All | All | All | `0.0.0.0/0` | DENY |

Note that outbound is restricted to the ephemeral port range back to the app subnets only — the
data tier can respond to queries and initiate nothing.

The public and app subnets keep the default NACL (allow all) and rely on security groups. Adding
restrictive NACLs to those tiers is possible but has poor cost/benefit: they must be written in
CIDR terms, so they cannot express "from the ALB's security group", and they are a frequent cause
of hard-to-diagnose connectivity failures.

---

## VPC endpoints (optional, recommended)

Instances currently reach AWS service APIs — S3, Systems Manager, Secrets Manager, CloudWatch —
through the NAT gateway and out over the public internet to the public service endpoints. VPC
endpoints keep that traffic on the AWS network instead.

| Endpoint | Type | Cost | Why |
|---|---|---|---|
| `com.amazonaws.eu-west-1.s3` | Gateway | **Free** | Route-table entry; S3 traffic bypasses NAT entirely. Add this unconditionally — it is free and removes NAT data-processing charges for every S3 byte |
| `com.amazonaws.eu-west-1.ssm` | Interface | ~$7.30/mo + data | Session Manager control plane |
| `com.amazonaws.eu-west-1.ssmmessages` | Interface | ~$7.30/mo + data | Session Manager data channel |
| `com.amazonaws.eu-west-1.ec2messages` | Interface | ~$7.30/mo + data | Legacy SSM Agent message channel — see note |
| `com.amazonaws.eu-west-1.secretsmanager` | Interface | ~$7.30/mo + data | Database credential retrieval |

> **`ec2messages` in 2026:** AWS is retiring the `ec2messages` channel. Regions launched from 2024
> onward support only `ssmmessages`, and SSM Agent 3.3.40.0 and later prefers `ssmmessages`
> automatically where it is available. In older regions such as `eu-west-1`, create all three for
> compatibility; in a newly launched region, `ssm` + `ssmmessages` is sufficient.

The four interface endpoints together cost roughly $29/month (three SSM endpoints at ~$22 plus
Secrets Manager at ~$7.30), which beats the NAT data processing they replace only at meaningful
traffic volumes. The decision rule:

- **Gateway endpoint for S3:** always, it is free.
- **Interface endpoints:** add them when you want to remove the NAT gateways entirely (a private
  subnet with no NAT but with SSM endpoints still supports Session Manager), or when you have a
  compliance requirement that AWS API traffic must not traverse the internet.

Interface endpoints need their own security group allowing inbound TCP 443 from the app subnets,
and private DNS enabled so the standard service hostnames resolve to the endpoint's private IPs.

---

## DNS

Both `enableDnsSupport` and `enableDnsHostnames` must be **on**:

- `enableDnsSupport` provides the Amazon-provided DNS resolver at `VPC base + 2` (`10.0.0.2`) and
  the link-local `169.254.169.253`. Without it, instances cannot resolve the RDS endpoint, the SSM
  endpoints, or anything else.
- `enableDnsHostnames` makes AWS assign DNS hostnames to instances. It is also a prerequisite for
  **private DNS on interface VPC endpoints**, which is what makes `secretsmanager.eu-west-1.amazonaws.com`
  resolve to the endpoint's private IP instead of the public one.

The RDS writer endpoint (`mydb.xxxx.eu-west-1.rds.amazonaws.com`) is a DNS name whose record is
updated by the RDS service during a failover to point at the promoted standby. This is why the
application must connect by endpoint name and must not cache the resolved IP beyond its TTL — a
JVM with `networkaddress.cache.ttl = -1` will keep talking to the old primary's address after a
failover and fail until it is restarted.

---

## Verification commands

```bash
# Confirm subnets and their AZs
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxx" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}' \
  --output table

# Confirm each route table's default route
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxx" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]}' \
  --output json

# Prove the data subnets have no default route (expect an empty list)
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-private-db-a-id" \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'

# Test the path from an instance to the database, without SSH
aws ssm start-session --target i-xxxxxxxx
# then, in the session:
#   nc -zv mydb.xxxx.eu-west-1.rds.amazonaws.com 3306
#   curl -s https://checkip.amazonaws.com    # should return the NAT gateway's Elastic IP
```

---

## Common failure modes

| Symptom | Usual cause |
|---|---|
| Instance cannot reach the internet | Private subnet's route table has no NAT route, or the NAT gateway is in a private subnet instead of a public one |
| ALB stuck in `provisioning` | Its subnets are in the same AZ, or a subnet has fewer than 8 free IPs |
| Session Manager cannot connect | No egress path to the SSM endpoints, missing `AmazonSSMManagedInstanceCore` on the instance profile, or SSM Agent not running |
| Application cannot reach RDS | `sg-rds` does not reference `sg-web`, or the DB subnet group lists the wrong subnets |
| Connectivity works one way only | A custom NACL is missing its ephemeral-port rule in the reverse direction |
| Everything breaks after a failover | The application cached the resolved IP of the RDS endpoint |
