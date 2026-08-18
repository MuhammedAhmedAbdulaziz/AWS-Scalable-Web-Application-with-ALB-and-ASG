# 03 — Deployment Guide

A step-by-step runbook. Each step gives the console path and the equivalent AWS CLI command. The
CLI commands are written to be run in order — each one exports the IDs the next step needs.

> **Cost warning.** NAT gateways, the ALB and RDS Multi-AZ begin billing the moment they are
> created and are not covered by the free tier. A full deployment left running costs roughly
> **$156/month**. Follow [10-cleanup.md](10-cleanup.md) when you are finished.

---

## Prerequisites

```bash
aws --version                 # v2 required
aws sts get-caller-identity   # confirm the account and identity
export AWS_REGION=eu-west-1
export AWS_DEFAULT_REGION=eu-west-1
export AZ_A=eu-west-1a
export AZ_B=eu-west-1b
export PROJECT=saa-p1
```

Required permissions: `ec2:*`, `elasticloadbalancing:*`, `autoscaling:*`, `rds:*`,
`cloudfront:*`, `wafv2:*`, `route53:*`, `iam:*`, `ssm:*`, `cloudwatch:*`, `sns:*`, `s3:*`.

---

## Step 1 — VPC and subnets

**Console:** VPC → Your VPCs → Create VPC → *VPC and more*. The wizard creates subnets, route
tables, the internet gateway and NAT gateways in one action. Set 2 AZs, 2 public subnets, 4
private subnets, and **NAT gateways: 1 per AZ**.

**CLI:**

```bash
# VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc}]" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Subnets
mk_subnet () {  # $1 cidr  $2 az  $3 name
  aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $1 --availability-zone $2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-$3}]" \
    --query 'Subnet.SubnetId' --output text
}

PUB_A=$(mk_subnet 10.0.0.0/24  $AZ_A public-a)
PUB_B=$(mk_subnet 10.0.1.0/24  $AZ_B public-b)
APP_A=$(mk_subnet 10.0.10.0/24 $AZ_A private-app-a)
APP_B=$(mk_subnet 10.0.11.0/24 $AZ_B private-app-b)
DB_A=$(mk_subnet  10.0.20.0/24 $AZ_A private-db-a)
DB_B=$(mk_subnet  10.0.21.0/24 $AZ_B private-db-b)

# Public subnets auto-assign public IPs (needed for the NAT gateways and ALB nodes)
aws ec2 modify-subnet-attribute --subnet-id $PUB_A --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB_B --map-public-ip-on-launch
```

## Step 2 — Internet gateway, NAT gateways, route tables

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# One NAT gateway per AZ, each with its own Elastic IP
EIP_A=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
EIP_B=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)

NAT_A=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP_A \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-a}]" \
  --query 'NatGateway.NatGatewayId' --output text)
NAT_B=$(aws ec2 create-nat-gateway --subnet-id $PUB_B --allocation-id $EIP_B \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-b}]" \
  --query 'NatGateway.NatGatewayId' --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_B   # ~2 minutes

# Public route table
RTB_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rtb-public}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB_PUB --subnet-id $PUB_A
aws ec2 associate-route-table --route-table-id $RTB_PUB --subnet-id $PUB_B

# Private route table per AZ — each pointing at its own AZ's NAT gateway
RTB_A=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rtb-private-a}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_A --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_A
aws ec2 associate-route-table --route-table-id $RTB_A --subnet-id $APP_A

RTB_B=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rtb-private-b}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_B --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_B
aws ec2 associate-route-table --route-table-id $RTB_B --subnet-id $APP_B

# Data route table — deliberately no default route
RTB_DB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rtb-data}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 associate-route-table --route-table-id $RTB_DB --subnet-id $DB_A
aws ec2 associate-route-table --route-table-id $RTB_DB --subnet-id $DB_B

# Free S3 gateway endpoint — attach to the two private route tables
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.s3 \
  --route-table-ids $RTB_A $RTB_B
```

## Step 3 — Security groups

Create all three first, then add the rules, because they reference each other.

```bash
mk_sg () { aws ec2 create-security-group --group-name "$PROJECT-$1" --description "$2" \
  --vpc-id $VPC_ID --query GroupId --output text; }

SG_ALB=$(mk_sg sg-alb "ALB - accepts traffic from CloudFront only")
SG_WEB=$(mk_sg sg-web "Web tier - accepts traffic from the ALB only")
SG_RDS=$(mk_sg sg-rds "RDS - accepts traffic from the web tier only")

# ALB ← CloudFront managed prefix list (not 0.0.0.0/0)
PL_CF=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --query 'PrefixLists[0].PrefixListId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,PrefixListIds=[{PrefixListId=$PL_CF}]"

# Port 80 from the same prefix list, so the HTTP->HTTPS redirect listener in Step 6
# is actually reachable. Without this rule that listener can never be hit.
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL_CF}]"

# Web ← ALB   (security group reference, not a CIDR)
aws ec2 authorize-security-group-ingress --group-id $SG_WEB \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$SG_ALB}]"

# RDS ← Web
aws ec2 authorize-security-group-ingress --group-id $SG_RDS \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_WEB}]"
```

There is **no port 22 rule**. Shell access is Session Manager only.

## Step 4 — IAM instance role

```bash
cat > /tmp/trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

aws iam create-role --role-name $PROJECT-ec2-role \
  --assume-role-policy-document file:///tmp/trust.json

# Session Manager, Parameter Store read, CloudWatch Agent
aws iam attach-role-policy --role-name $PROJECT-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name $PROJECT-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam create-instance-profile --instance-profile-name $PROJECT-ec2-profile
aws iam add-role-to-instance-profile --instance-profile-name $PROJECT-ec2-profile \
  --role-name $PROJECT-ec2-role
```

Add a scoped inline policy for the specific secret and S3 prefix the application needs — see
[04-security.md](04-security.md#iam).

## Step 5 — RDS Multi-AZ

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name $PROJECT-db-subnets \
  --db-subnet-group-description "Private data subnets" \
  --subnet-ids $DB_A $DB_B

aws rds create-db-instance \
  --db-instance-identifier $PROJECT-mysql \
  --db-instance-class db.t3.micro \
  --engine mysql --engine-version 8.0 \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --master-username admin \
  --manage-master-user-password \
  --multi-az \
  --db-subnet-group-name $PROJECT-db-subnets \
  --vpc-security-group-ids $SG_RDS \
  --backup-retention-period 7 \
  --preferred-backup-window "02:00-03:00" \
  --preferred-maintenance-window "sun:03:30-sun:04:30" \
  --enable-cloudwatch-logs-exports '["error","slowquery"]' \
  --no-publicly-accessible \
  --deletion-protection

aws rds wait db-instance-available --db-instance-identifier $PROJECT-mysql   # ~10-15 minutes
```

Key flags:

| Flag | Why |
|---|---|
| `--multi-az` | Creates the synchronous standby in the second AZ. This is the availability feature |
| `--manage-master-user-password` | RDS creates and rotates the password in Secrets Manager — no password in a script or a shell history |
| `--storage-encrypted` | KMS encryption at rest. **Cannot be enabled after creation** — you would have to snapshot, copy the snapshot with encryption, and restore |
| `--no-publicly-accessible` | No public DNS name for the instance |
| `--deletion-protection` | Blocks accidental deletion; must be turned off before teardown |

## Step 6 — Target group and ALB

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name $PROJECT-tg --protocol HTTP --port 80 --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP --health-check-path /health \
  --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Deregistration delay: how long the ALB drains in-flight requests before removing a target
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30

ALB_ARN=$(aws elbv2 create-load-balancer --name $PROJECT-alb \
  --subnets $PUB_A $PUB_B --security-groups $SG_ALB \
  --scheme internet-facing --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Dimension values for CloudWatch alarms are the ARN suffixes, not the full ARNs
ALB_SUFFIX=$(echo $ALB_ARN | cut -d/ -f2-)          # app/saa-p1-alb/0123456789abcdef
TG_SUFFIX=$(echo $TG_ARN  | cut -d: -f6)            # targetgroup/saa-p1-tg/0123456789abcdef

# HTTPS listener (CERT_ARN = an ACM certificate in this region)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# HTTP listener that only redirects
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
  --default-actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]'
```

### Health check tuning

Defaults are interval 30 s, timeout 5 s, healthy threshold 5, unhealthy threshold 2, matcher 200.
The values above tighten detection:

```
detection time = unhealthy threshold × interval = 2 × 15 s = 30 s
```

The default 2 × 30 s = 60 s means up to a minute of requests going to a dead instance. Do not
tighten further without reason — an interval below 10 s adds real health-check load, and a
threshold of 1 makes a single dropped packet eject a healthy instance.

### Listener rules (optional)

```bash
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN \
  --query 'Listeners[?Port==`443`].ListenerArn' --output text)

# Path-based routing to a second target group
aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 10 \
  --conditions '[{"Field":"path-pattern","Values":["/api/*"]}]' \
  --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_API_ARN\"}]"

# Fixed response for a maintenance page
aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 20 \
  --conditions '[{"Field":"path-pattern","Values":["/maintenance"]}]' \
  --actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"503","ContentType":"text/html","MessageBody":"<h1>Maintenance</h1>"}}]'
```

Rules evaluate in priority order, lowest number first; the listener's default action is the
fallback. Available conditions: `path-pattern`, `host-header`, `http-header`, `http-request-method`,
`query-string`, `source-ip`.

## Step 7 — Launch template and Auto Scaling group

```bash
# Always resolve the AMI dynamically
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

cat > /tmp/userdata.sh <<'BASH'
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y httpd amazon-cloudwatch-agent
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Shallow health check: does NOT touch the database. See README.
echo OK > /var/www/html/health
cat > /var/www/html/index.html <<HTML
<h1>Scalable Web Application</h1>
<p>Instance: $IID</p>
<p>Availability Zone: $AZ</p>
HTML

systemctl enable --now httpd
BASH

aws ec2 create-launch-template \
  --launch-template-name $PROJECT-lt \
  --launch-template-data "{
    \"ImageId\":\"$AMI_ID\",
    \"InstanceType\":\"t3.micro\",
    \"IamInstanceProfile\":{\"Name\":\"$PROJECT-ec2-profile\"},
    \"SecurityGroupIds\":[\"$SG_WEB\"],
    \"UserData\":\"$(base64 -w0 /tmp/userdata.sh)\",
    \"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpPutResponseHopLimit\":1},
    \"Monitoring\":{\"Enabled\":true},
    \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/xvda\",
      \"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}],
    \"TagSpecifications\":[{\"ResourceType\":\"instance\",
      \"Tags\":[{\"Key\":\"Name\",\"Value\":\"$PROJECT-web\"}]}]
  }"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name $PROJECT-asg \
  --launch-template "LaunchTemplateName=$PROJECT-lt,Version=\$Latest" \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "$APP_A,$APP_B" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --default-instance-warmup 120 \
  --tags "Key=Name,Value=$PROJECT-web,PropagateAtLaunch=true"

# Group metrics (GroupInServiceInstances, GroupDesiredCapacity, ...) are free but
# OFF by default. Without this, the ASG dashboard widgets and alarm 8 stay empty.
aws autoscaling enable-metrics-collection \
  --auto-scaling-group-name $PROJECT-asg --granularity "1Minute"
```

`MetadataOptions.HttpTokens=required` enforces IMDSv2, which requires a session token obtained via
a `PUT` request. This is what prevents an SSRF vulnerability in the application from being used to
read the instance's IAM credentials from the metadata service.

`--health-check-type ELB` is the important one. The default is `EC2`, which only checks that the
hypervisor believes the instance is running — a hung web server passes. With `ELB`, an instance
that fails the target group health check is replaced.

`--health-check-grace-period 300` suppresses health checks for the first five minutes so an
instance that is still installing packages is not killed before it can serve. Set it longer than
your worst-case boot time; too short produces an infinite launch/terminate loop.

## Step 8 — Scaling policy

```bash
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name $PROJECT-asg \
  --policy-name cpu50 \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},
    "TargetValue":50.0,
    "DisableScaleIn":false
  }'
```

EC2 Auto Scaling creates and manages the two CloudWatch alarms behind this policy — do not edit or
delete them by hand.

## Step 9 — S3, WAF and CloudFront

```bash
# Static asset bucket - no public access, reached only through CloudFront OAC
BUCKET=$PROJECT-static-$RANDOM
aws s3api create-bucket --bucket $BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# WAF web ACL — CLOUDFRONT scope is ALWAYS created in us-east-1
aws wafv2 create-web-acl --region us-east-1 \
  --name $PROJECT-web-acl --scope CLOUDFRONT \
  --default-action Allow={} \
  --visibility-config \
    SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=$PROJECT-web-acl \
  --rules file://examples/waf-rules.json
```

`examples/waf-rules.json` holds the five rules; the rationale for each is in
[04-security.md](04-security.md#aws-waf-web-acl).

**CloudFront distribution** (console is easier for this one):

| Setting | Value |
|---|---|
| Origin 1 | S3 static bucket, **Origin access control (OAC)**, signing enabled |
| Origin 2 | ALB DNS name, protocol **HTTPS only**, custom header `X-Origin-Verify` |
| Behaviour `/static/*` | Origin 1, `CachingOptimized`, redirect HTTP to HTTPS, GET/HEAD |
| Behaviour `Default (*)` | Origin 2, **`CachingDisabled`**, **`AllViewer`** origin request policy, all methods |
| WAF | Attach the web ACL created above |
| Price class | `PriceClass_100` |
| Minimum TLS | `TLSv1.2_2021` |
| Alternate domain name | Your domain + an ACM certificate **in us-east-1** |

> The `Default (*)` behaviour **must** use `CachingDisabled` and forward all cookies and headers.
> Caching authenticated responses and serving one user's page to another is the most damaging
> mistake available in this architecture.

Creating the OAC also requires an S3 bucket policy allowing the CloudFront service principal with
a `AWS:SourceArn` condition matching the distribution ARN — the console offers to copy it for you.

## Step 10 — Route 53

```bash
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{
  "Changes":[{"Action":"UPSERT","ResourceRecordSet":{
    "Name":"example.com","Type":"A",
    "AliasTarget":{
      "HostedZoneId":"Z2FDTNDATAQYW2",
      "DNSName":"dxxxxxxxxxxxxx.cloudfront.net",
      "EvaluateTargetHealth":false}}}]}'
```

`Z2FDTNDATAQYW2` is the fixed hosted zone ID for all CloudFront distributions, in every region.

Why an **alias** and not a CNAME: DNS forbids a CNAME at a zone apex (`example.com`), because a
CNAME cannot coexist with the SOA and NS records that must exist there. An alias is a Route 53
extension that returns the target's A record directly. It is also free — alias queries to AWS
resources are not billed, while CNAME queries are.

## Step 11 — CloudWatch and SNS

```bash
TOPIC_ARN=$(aws sns create-topic --name $PROJECT-alerts --query TopicArn --output text)
aws sns subscribe --topic-arn $TOPIC_ARN --protocol email --notification-endpoint ops@example.com
# confirm the subscription from the email

aws cloudwatch put-metric-alarm \
  --alarm-name $PROJECT-unhealthy-hosts \
  --metric-name UnHealthyHostCount --namespace AWS/ApplicationELB \
  --statistic Average --period 60 --evaluation-periods 2 \
  --threshold 0 --comparison-operator GreaterThanThreshold \
  --dimensions Name=TargetGroup,Value=$TG_SUFFIX Name=LoadBalancer,Value=$ALB_SUFFIX \
  --alarm-actions $TOPIC_ARN --treat-missing-data notBreaching
```

The full alarm set and the dashboard definition are in [06-observability.md](06-observability.md).

---

## Post-deployment verification

```bash
# 1. Both targets healthy
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State}' --output table

# 2. Instances are spread across both AZs
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $PROJECT-asg \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus}' \
  --output table

# 3. RDS is Multi-AZ and shows a secondary AZ
aws rds describe-db-instances --db-instance-identifier $PROJECT-mysql \
  --query 'DBInstances[0].{MultiAZ:MultiAZ,AZ:AvailabilityZone,Secondary:SecondaryAvailabilityZone,Status:DBInstanceStatus}'

# 4. Session Manager works without any inbound rule
aws ssm start-session --target $(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $PROJECT-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# 5. The site responds through CloudFront, and refreshing shows both instance IDs
curl -s https://example.com | grep Instance
```

Then run the four resilience tests in [08-validation-testing.md](08-validation-testing.md).

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Targets stuck `unhealthy` | Is httpd running? Does `/health` return 200? Does `sg-web` allow 80 from `sg-alb`? Is the grace period long enough? |
| Instances launch and terminate in a loop | Health check grace period shorter than boot time; user data failing (read `/var/log/cloud-init-output.log` over Session Manager) |
| `start-session` fails | Instance profile missing `AmazonSSMManagedInstanceCore`; no egress to the SSM endpoints; agent not running (`systemctl status amazon-ssm-agent`) |
| CloudFront returns 502 | Origin protocol set to HTTPS but the ALB has no HTTPS listener, or `sg-alb` does not allow the CloudFront prefix list |
| CloudFront serves stale/wrong content | The `Default (*)` behaviour is caching — set it to `CachingDisabled` |
| RDS unreachable | `sg-rds` does not reference `sg-web`; DB subnet group lists the wrong subnets |
| ALB stuck `provisioning` | Both subnets in one AZ, or fewer than 8 free IPs in a subnet |
