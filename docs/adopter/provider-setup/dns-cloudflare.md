# Cloudflare DNS setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / Cloudflare DNS

**Audiences:** adopter (deploy)

Cloudflare DNS is used by both external-dns (to publish HTTPRoute and Service records automatically) and cert-manager (to solve ACME DNS-01 challenges for the wildcard certificates on `*.int.<domain>` and `*.ext.<domain>`).

For background on the DNS strategy, see [Networking](../../architecture/networking.md#dns-strategy).

---

## API token

Create a scoped API token (not the legacy Global API Key):

1. Open [My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens).
2. **Create Token → Custom token**.
3. Permissions:
   - `Zone` → `DNS` → `Edit`
   - `Zone` → `Zone` → `Read`
4. Zone resources: **Include → Specific zone → `example.com`** (the zone the toolkit will manage records in).
5. Optional TTL and IP filters if your policy requires them.
6. Create and copy the token (shown once).

Put it in `config/environments/<env>/.env`:

```bash
CLOUDFLARE_API_TOKEN="..."
```

The Makefile maps this to `TF_VAR_dns_credentials.cloudflare_api_token` automatically.

Verify the token has the right scope:

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .
```

---

## Zone

The toolkit expects a DNS zone matching the `dns.domain` value in `config.yaml`. The zone must already exist in Cloudflare:

1. Add the zone in the Cloudflare dashboard (or via the API).
2. Update the parent registrar/zone to delegate to Cloudflare's assigned nameservers.
3. Wait for delegation to propagate.

The toolkit will not create or delete the zone itself.

### Proxied vs DNS-only

Set `dns.cloudflare.proxied: false` in `config.yaml` for records the toolkit manages. The orange-cloud proxy interferes with mTLS termination on the gateway and with ACME DNS-01 validation.

```yaml
dns:
  provider: "cloudflare"
  domain: "sw1.example.com"
  cloudflare:
    proxied: false
```

---

## What the toolkit writes to the zone

Once deployed, the toolkit creates:

- A wildcard A/AAAA record for `*.int.<domain>` pointing at the Gateway LoadBalancer IPs (external-dns)
- A wildcard A/AAAA record for `*.ext.<domain>` pointing at the same IPs (external-dns)
- TXT records for ACME DNS-01 challenges (cert-manager)
- For Switches: optional per-DFSP records under `<domain>`

You do not need to pre-create these — external-dns reconciles them from Gateway/HTTPRoute resources.

---

## Next

- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
