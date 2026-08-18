#!/bin/bash
#
# Launch template user data — web tier bootstrap
# Project 1: Scalable Web Application with ALB and Auto Scaling
#
# Runs as root on every instance launch. Must be idempotent: the Auto Scaling
# group will run it again on every replacement instance.
#
set -euxo pipefail

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
dnf update -y
dnf install -y httpd amazon-cloudwatch-agent

# ---------------------------------------------------------------------------
# Instance identity — IMDSv2 only (a plain GET is refused by design)
# ---------------------------------------------------------------------------
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IMDS() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }

INSTANCE_ID=$(IMDS instance-id)
AZ=$(IMDS placement/availability-zone)
LOCAL_IP=$(IMDS local-ipv4)

# ---------------------------------------------------------------------------
# Health check endpoint
#
# IMPORTANT: this is a SHALLOW check. It answers "can this instance serve
# requests?" and must NOT query the database. If it did, a 60-120 s RDS
# failover would fail every instance's health check simultaneously, the ASG
# would terminate the entire fleet, and a brief database blip would become a
# full outage. Dependency health belongs on /health/deep, which feeds a
# CloudWatch alarm rather than a termination decision.
# ---------------------------------------------------------------------------
echo "OK" > /var/www/html/health

cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Scalable Web Application</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 40rem; color: #232F3E; }
    dt { font-weight: 600; margin-top: .75rem; }
    code { background: #f4f4f4; padding: .1rem .3rem; border-radius: 3px; }
  </style>
</head>
<body>
  <h1>Scalable Web Application</h1>
  <p>Served from a private subnet, behind an Application Load Balancer and CloudFront.</p>
  <dl>
    <dt>Instance ID</dt><dd><code>${INSTANCE_ID}</code></dd>
    <dt>Availability Zone</dt><dd><code>${AZ}</code></dd>
    <dt>Private IP</dt><dd><code>${LOCAL_IP}</code></dd>
  </dl>
  <p>Refresh a few times — the ALB round-robins across both Availability Zones.</p>
</body>
</html>
HTML

# ---------------------------------------------------------------------------
# CloudWatch Agent — memory and disk are NOT visible to the hypervisor, so
# without the agent there are no mem_used_percent / disk_used_percent metrics.
# ---------------------------------------------------------------------------
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'JSON'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "AutoScalingGroupName": "${aws:AutoScalingGroupName}"
    },
    "aggregation_dimensions": [["AutoScalingGroupName"]],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/httpd/access_log",
            "log_group_name": "/saa-p1/httpd/access", "retention_in_days": 30 },
          { "file_path": "/var/log/httpd/error_log",
            "log_group_name": "/saa-p1/httpd/error", "retention_in_days": 30 },
          { "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/saa-p1/cloud-init", "retention_in_days": 30 }
        ]
      }
    }
  }
}
JSON

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

# ---------------------------------------------------------------------------
# Start serving
# ---------------------------------------------------------------------------
systemctl enable --now httpd

# The SSM Agent is pre-installed on Amazon Linux 2023; make sure it is running
# so Session Manager works without any inbound security group rule.
systemctl enable --now amazon-ssm-agent
