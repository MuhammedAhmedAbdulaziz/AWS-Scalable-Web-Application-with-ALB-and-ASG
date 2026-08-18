# Examples

Supporting configuration referenced by the documentation. Replace the placeholder account ID
(`111122223333`), region, bucket names and resource IDs before use.

| File | Referenced from | Purpose |
|---|---|---|
| `waf-rules.json` | [docs/03 §9](../docs/03-deployment-guide.md), [docs/04](../docs/04-security.md) | The five WAF rules — four AWS managed rule groups plus a rate limit |
| `user-data.sh` | [docs/03 §7](../docs/03-deployment-guide.md) | Launch template bootstrap: httpd, the shallow `/health` endpoint, CloudWatch Agent |
| `instance-role-policy.json` | [docs/04](../docs/04-security.md#iam) | Least-privilege inline policy for the EC2 instance role |
| `cloudwatch-dashboard.json` | [docs/06](../docs/06-observability.md#dashboard) | The five-row operational dashboard |

```bash
# Apply the dashboard
aws cloudwatch put-dashboard \
  --dashboard-name saa-p1-overview \
  --dashboard-body file://examples/cloudwatch-dashboard.json

# Create the WAF web ACL (CLOUDFRONT scope is always us-east-1)
aws wafv2 create-web-acl --region us-east-1 \
  --name saa-p1-web-acl --scope CLOUDFRONT \
  --default-action Allow={} \
  --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=saa-p1-web-acl \
  --rules file://examples/waf-rules.json
```
