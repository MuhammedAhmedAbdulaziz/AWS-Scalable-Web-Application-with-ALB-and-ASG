# 10 — Cleanup

Delete in reverse dependency order. AWS refuses to delete a resource that something else still
references, and the error messages are not always specific about which reference is blocking it.

> **Why this matters.** NAT gateways, the ALB and RDS bill by the hour whether or not any traffic
> flows. An unattached Elastic IP is charged specifically *because* it is unattached. A forgotten
> deployment is roughly **$156/month** indefinitely.

---

## Order of deletion

```
 1. Route 53 records          (release the DNS name)
 2. CloudFront distribution   (disable, wait, then delete — slowest step)
 3. WAF web ACL               (only after the distribution is gone)
 4. Auto Scaling group        (set desired/min to 0 first)
 5. Launch template
 6. ALB listeners, ALB, target group
 7. RDS instance              (disable deletion protection first)
 8. DB subnet group
 9. NAT gateways              (wait for deletion), then release Elastic IPs
10. VPC endpoints
11. Security groups           (in dependency order: rds → web → alb)
12. Subnets, route tables, internet gateway, VPC
13. S3 buckets                (empty first)
14. CloudWatch alarms, log groups, dashboard
15. SNS topic
16. IAM instance profile and role
```

---

## Commands

```bash
export PROJECT=saa-p1
export AWS_DEFAULT_REGION=eu-west-1
```

### 1–3. Edge

```bash
# Route 53 alias record
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{
  "Changes":[{"Action":"DELETE","ResourceRecordSet":{ ...the exact record set... }}]}'

# CloudFront must be DISABLED before it can be deleted
ETAG=$(aws cloudfront get-distribution-config --id $DIST_ID --query ETag --output text)
aws cloudfront get-distribution-config --id $DIST_ID \
  --query DistributionConfig > /tmp/dist.json
# set "Enabled": false in /tmp/dist.json
aws cloudfront update-distribution --id $DIST_ID \
  --distribution-config file:///tmp/dist.json --if-match $ETAG

# Deployment takes 5-15 minutes; wait for it
aws cloudfront wait distribution-deployed --id $DIST_ID

ETAG=$(aws cloudfront get-distribution --id $DIST_ID --query ETag --output text)
aws cloudfront delete-distribution --id $DIST_ID --if-match $ETAG

# WAF web ACL - us-east-1 for CLOUDFRONT scope, and it must have no associations left
LOCK=$(aws wafv2 get-web-acl --region us-east-1 --scope CLOUDFRONT \
  --name $PROJECT-web-acl --id $WEB_ACL_ID --query WebACL.LockToken --output text)
aws wafv2 delete-web-acl --region us-east-1 --scope CLOUDFRONT \
  --name $PROJECT-web-acl --id $WEB_ACL_ID --lock-token $LOCK
```

CloudFront is the slowest deletion in the whole stack — budget 20 minutes. The WAF web ACL cannot
be deleted while any distribution still references it, and **remember it lives in `us-east-1`**,
not in your working region. It is the single most commonly orphaned resource in this architecture,
and it costs $5/month plus $1 per rule to leave behind.

### 4–6. Compute and load balancing

```bash
# Scale to zero first so instances are not relaunched mid-teardown
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $PROJECT-asg \
  --min-size 0 --desired-capacity 0
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $PROJECT-asg \
  --force-delete

aws ec2 delete-launch-template --launch-template-name $PROJECT-lt

for L in $(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN \
             --query 'Listeners[].ListenerArn' --output text); do
  aws elbv2 delete-listener --listener-arn $L
done
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $TG_ARN
```

The ALB must be fully deleted before its security group can be — the ENIs it created linger for a
minute or two afterwards.

### 7–8. Database

```bash
# Deletion protection blocks the delete call
aws rds modify-db-instance --db-instance-identifier $PROJECT-mysql \
  --no-deletion-protection --apply-immediately

# Take a final snapshot, or skip it (irreversible)
aws rds delete-db-instance --db-instance-identifier $PROJECT-mysql \
  --final-db-snapshot-identifier $PROJECT-final-$(date +%Y%m%d)
# ...or, to keep nothing at all:
# aws rds delete-db-instance --db-instance-identifier $PROJECT-mysql \
#   --skip-final-snapshot --delete-automated-backups

aws rds wait db-instance-deleted --db-instance-identifier $PROJECT-mysql
aws rds delete-db-subnet-group --db-subnet-group-name $PROJECT-db-subnets
```

> **Snapshots survive the instance and continue to bill.** A final snapshot is cheap insurance and
> easy to forget. List them later with
> `aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier'`.

### 9–12. Network

```bash
# NAT gateways first
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_A
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_B
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_A $NAT_B   # ~2 minutes

# Then release the Elastic IPs - an unattached EIP is billed
aws ec2 release-address --allocation-id $EIP_A
aws ec2 release-address --allocation-id $EIP_B

# VPC endpoints
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text)

# Security groups, in reverse dependency order
aws ec2 delete-security-group --group-id $SG_RDS
aws ec2 delete-security-group --group-id $SG_WEB
aws ec2 delete-security-group --group-id $SG_ALB

# Subnets, route tables, IGW, VPC
for S in $PUB_A $PUB_B $APP_A $APP_B $DB_A $DB_B; do aws ec2 delete-subnet --subnet-id $S; done
for R in $RTB_PUB $RTB_A $RTB_B $RTB_DB; do aws ec2 delete-route-table --route-table-id $R; done
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-vpc --vpc-id $VPC_ID
```

If `delete-security-group` reports a dependency violation, an ENI still references it. Find it:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_WEB" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}'
```

Usually it is an ALB or NAT ENI that has not finished releasing — wait a few minutes and retry.

### 13–16. Storage, monitoring, identity

```bash
# S3 buckets must be empty (including all versions) before deletion
aws s3 rm s3://$BUCKET --recursive
aws s3api delete-bucket --bucket $BUCKET

aws cloudwatch delete-alarms --alarm-names \
  $PROJECT-unhealthy-hosts $PROJECT-5xx-rate $PROJECT-latency-p95 $PROJECT-rds-cpu
aws cloudwatch delete-dashboards --dashboard-names $PROJECT-overview

for G in $(aws logs describe-log-groups --log-group-name-prefix /$PROJECT \
             --query 'logGroups[].logGroupName' --output text); do
  aws logs delete-log-group --log-group-name $G
done

aws sns delete-topic --topic-arn $TOPIC_ARN

aws iam remove-role-from-instance-profile \
  --instance-profile-name $PROJECT-ec2-profile --role-name $PROJECT-ec2-role
aws iam delete-instance-profile --instance-profile-name $PROJECT-ec2-profile
aws iam detach-role-policy --role-name $PROJECT-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam detach-role-policy --role-name $PROJECT-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam delete-role --role-name $PROJECT-ec2-role
```

---

## Verification sweep

Run all of these. Every one should return empty.

```bash
echo "--- NAT gateways"
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'

echo "--- Unattached Elastic IPs (billed!)"
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'

echo "--- Load balancers"
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'

echo "--- RDS instances"
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'

echo "--- Manual RDS snapshots (these still bill)"
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier'

echo "--- Running instances"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'

echo "--- Non-default VPCs"
aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query 'Vpcs[].VpcId'

echo "--- CloudFront distributions"
aws cloudfront list-distributions --query 'DistributionList.Items[].Id'

echo "--- WAF web ACLs in us-east-1 (easy to forget)"
aws wafv2 list-web-acls --region us-east-1 --scope CLOUDFRONT --query 'WebACLs[].Name'

echo "--- EBS volumes"
aws ec2 describe-volumes --query 'Volumes[].VolumeId'
```

Finally, check **Billing → Bills** the next day. Charges lag by up to 24 hours, so a clean sweep
today does not guarantee a zero bill until you have seen tomorrow's figure.

---

## The commonly forgotten list

| Resource | Why it is missed | Cost if left |
|---|---|---|
| WAF web ACL in `us-east-1` | It is not in your working region | $5/mo + $1 per rule |
| Unattached Elastic IPs | Billed *because* they are unattached | ~$3.60/mo each |
| RDS manual snapshots | Survive the instance deletion | ~$0.095/GB-month |
| EBS snapshots | Created by AMIs or backup jobs | ~$0.05/GB-month |
| CloudWatch log groups | Default retention is "never expire" | Grows forever |
| ACM certificates | Free, but clutter the account | $0 |
| Route 53 hosted zone | Persists after every record is deleted | $0.50/mo |
| S3 buckets with versioning | `s3 rm --recursive` does not remove old versions | Storage cost |
| Orphaned ENIs | Left behind by deleted services | Block SG/subnet deletion |
