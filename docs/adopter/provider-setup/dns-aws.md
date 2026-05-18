# AWS Route53 DNS setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / AWS Route53 DNS

**Audiences:** adopter (deploy)

AWS Route53 is used by both external-dns (to publish HTTPRoute and Service records automatically) and cert-manager (to solve ACME DNS-01 challenges for the wildcard certificates on `*.int.<domain>` and `*.ext.<domain>`).

Route53 is a natural fit when the infrastructure provider is AWS, but works with any infrastructure provider — DNS is an independent dimension.

For background on the DNS strategy, see [Networking](../../architecture/networking.md#dns-strategy).

---

## Hosted zone

The toolkit expects a Route53 hosted zone matching the `dns.domain` value in `config.yaml`. Create it once:

```bash
aws route53 create-hosted-zone \
  --name sw1.example.com \
  --caller-reference "ml-iac3-$(date +%s)"
```

Note the four NS values returned. Add them as NS records in the parent zone (Route53, the registrar, or wherever the parent lives) so the subdomain is delegated to Route53.

Verify delegation propagated:

```bash
dig +short NS sw1.example.com @1.1.1.1
```

The toolkit will not create or delete the hosted zone itself.

---

## IAM credentials

Create an IAM user (or role, if you prefer assume-role) with permissions external-dns and cert-manager need.

### Minimum policy

Scope to the specific hosted zone if possible. Replace `Z123EXAMPLE` with your hosted zone ID:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/Z123EXAMPLE"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:ListResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": "*"
    }
  ]
}
```

### Create the user and access key

```bash
aws iam create-user --user-name ml-iac3-dns
aws iam put-user-policy --user-name ml-iac3-dns \
  --policy-name ml-iac3-dns --policy-document file://policy.json
aws iam create-access-key --user-name ml-iac3-dns
```

Save the `AccessKeyId` and `SecretAccessKey` from the last command.

Put them in `config/environments/<env>/.env`:

```bash
# DNS credentials (consumed via TF_VAR_dns_credentials)
AWS_ACCESS_KEY_ID="AKIA..."
AWS_SECRET_ACCESS_KEY="..."
AWS_REGION="us-east-1"          # Route53 is global, but the SDK requires a region
```

If AWS is **also** your infrastructure provider, the same credentials are used by the Terraform `aws` provider for EKS/VPC. If you want separation, use scoped roles via `AWS_PROFILE` — see your AWS deployment docs (planned).

---

## What the toolkit writes to the zone

Once deployed, the toolkit creates:

- A wildcard A/AAAA record for `*.int.<domain>` pointing at the Gateway LoadBalancer (external-dns)
- A wildcard A/AAAA record for `*.ext.<domain>` pointing at the same target (external-dns)
- TXT records for ACME DNS-01 challenges (cert-manager)
- For Switches: optional per-DFSP records under `<domain>`

You do not need to pre-create these — external-dns reconciles them from Gateway/HTTPRoute resources.

---

## Next

- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
