# Route 53 setup

The default `addressing_mode = "elastic_ip"` gives players a fixed IP address
and needs no domain. This is the alternative: a hostname like `mc.example.com`
that the instance repoints at itself on every boot.

It is worth the setup for two reasons — a name is easier to hand to people than
four numbers, and it removes the only charge this stack incurs while nobody is
playing.

| | `elastic_ip` (default) | `route53` |
| --- | --- | --- |
| Players connect to | `54.190.12.7` | `mc.example.com` |
| Needs a domain | no | **yes** |
| Cost while stopped | ~$3.60/month for the held address, free for the first 12 months on a free-tier account | $0.50/month per hosted zone, whatever the instance is doing |
| If AWS reassigns things | never; the address is yours | the record is rewritten each boot |
| Failure mode | none worth mentioning | a failed DNS update aborts the boot, deliberately |

Route 53 is cheaper in the long run and no cheaper in the first year. Pick it
for the name, not the two dollars.

---

## What you need first

**A domain name**, and its DNS served by Route 53. There are two ways to get
there, and only the first is a five-minute job:

1. **Register the domain in Route 53.** Console → Route 53 → *Registered
   domains* → *Register domains*. Route 53 creates the hosted zone and points
   the domain at it for you; nothing else to configure. From about $3/year for
   a `.click` or `.link`, ~$14 for a `.com`.

2. **Use a domain you already own elsewhere.** Create a hosted zone in Route 53
   for it (below), then log in to your existing registrar and replace its
   nameservers with the four Route 53 gives you. That moves *all* DNS for the
   domain to Route 53 — mail records included, so copy any existing records
   over first. Delegation takes minutes to a couple of days to propagate.

   If you would rather not move the whole domain, delegate one subdomain
   instead: make a hosted zone for `mc.example.com`, then at your registrar add
   `NS` records for `mc` pointing at the four Route 53 nameservers. Everything
   else about the domain stays where it is.

Either way you end up with a **hosted zone**, and that is the thing this
project needs.

## 1. Create the hosted zone

Skip this if Route 53 registered the domain — you already have one.

Console → Route 53 → *Hosted zones* → *Create hosted zone*:

- **Domain name**: `example.com` (or `mc.example.com` for the subdomain-only
  approach above)
- **Type**: *Public hosted zone*

Or from the CLI:

```bash
aws route53 create-hosted-zone \
  --name example.com \
  --caller-reference "$(date +%s)"
```

## 2. Copy the zone ID

Console → Route 53 → *Hosted zones* → your domain. The **Hosted zone ID** is on
the detail panel: 13-32 uppercase alphanumerics, like `Z0123456789ABCDEFGHIJ`.

```bash
aws route53 list-hosted-zones \
  --query 'HostedZones[].{name:Name,id:Id}' --output table
```

The CLI prints it as `/hostedzone/Z0123456789ABCDEFGHIJ`. Use only the part
after the last slash.

## 3. Choose the record name

Any name inside the zone. `mc.example.com` is the obvious one; the bare
`example.com` works too if the domain exists only for this.

It must be a name nothing else in the zone uses — this project rewrites that
record on every boot, so pointing it at a name shared with a website would take
the website down.

It must also be **fully qualified** and built from letters, digits, hyphens,
underscores and dots: `mc.example.com`, not `mc`. Terraform refuses anything
else at plan time rather than at boot. The reason is the IAM policy below,
which pins the instance to this exact record through a condition key AWS
evaluates against a normalised form of the name — lowercased, trailing dot
removed, and every other character replaced by a `\three-digit octal` escape.
Terraform can produce the first two and not the third, so a wildcard or an
internationalised name would build a policy that never matches and fail every
boot with an `AccessDenied` that names nothing useful. A single label is refused
for a different reason: Terraform reads it as relative to the zone while the
boot script sends it to the API as absolute, and the two would disagree about
which record they mean.

## 4. Configure and apply

In `terraform/terraform.tfvars`:

```hcl
addressing_mode     = "route53"
route53_zone_id     = "Z0123456789ABCDEFGHIJ"
route53_record_name = "mc.example.com"
# route53_ttl       = 30            # seconds; see below
```

```bash
terraform apply
```

Terraform refuses the apply if the mode is `route53` and either of the other
two is empty, rather than deploying something that cannot publish an address.

Two things happen on apply:

- The **A record is created immediately**, pointing at `192.0.2.1` — a
  documentation address from RFC 5737 that routes nowhere. This is so the name
  resolves from the moment the stack exists rather than only after the first
  boot, which makes "does this name work?" answerable straight away.
- The instance is granted `route53:ChangeResourceRecordSets` narrowed three
  ways: to that hosted zone, to that one record name, and to `A` records. It
  cannot touch anything else in your DNS, which is what makes it reasonable to
  point this at a zone that also serves a real website.

Terraform then stops managing the record's value: `ignore_changes = [records]`
in `dns.tf`, because the instance owns it from the first boot onwards. Without
that, every future apply would propose reverting the live address to the
placeholder.

## 5. Start it and check

`/start` in Discord, then once it reports ready:

```bash
dig +short mc.example.com

# or, on Windows without dig
nslookup mc.example.com 8.8.8.8
```

The answer should be the instance's current public IP, not `192.0.2.1`.
`/address` in Discord will now report the hostname rather than an IP, and
players connect to `mc.example.com` with no port (or `mc.example.com:25570` if
you changed `server_port`).

---

## How it works at boot

`announce-address.sh` runs as an `ExecStartPre` of `minecraft.service`, so it
finishes before the Java process starts accepting connections:

1. Read this boot's public IPv4 from IMDSv2, retrying — an Elastic IP or a
   fresh public address is not always attached the instant the network is up.
2. `UPSERT` the A record to that address via `route53
   change-resource-record-sets`.
3. Write the hostname to `/run/minecraft/address`, where `/status`, `/address`
   and the Discord notification all read it from.

**A failed DNS update aborts the boot.** That is deliberate: a server nobody
can resolve is worse than a server that visibly failed to start, because the
first looks like a networking problem on the player's end and the second shows
up in the logs and the Discord channel.

## Choosing a TTL

`route53_ttl` defaults to **30 seconds**. Resolvers cache the record for that
long, so it bounds how long a player who looked the name up during the previous
session can be sent to a stale address.

Short is right here — the address genuinely changes between sessions. The cost
of a short TTL is more Route 53 queries, and Route 53 charges $0.40 per million.
A group of friends will not reach a dollar a year.

Raise it only if you are on `elastic_ip`-style stability anyway, and never
above the length of a typical gap between sessions.

## Costs

| Item | Cost |
| --- | --- |
| Hosted zone | $0.50/month, per zone, always |
| Standard queries | $0.40 per million |
| Domain registration | varies; from ~$3/year |

The hosted zone charge is not in the AWS free tier. Against the ~$3.60/month
Elastic IP it replaces, Route 53 wins — but only after the first year, when
the free tier stops covering the public IPv4 address.

## Switching between modes

Both directions are a variable change and an apply; neither rebuilds the
instance or touches the world.

**To Route 53**, from `elastic_ip`: set the three variables above and apply.
Terraform releases the Elastic IP and creates the record. The address changes,
so tell your players.

**Back to `elastic_ip`**: set `addressing_mode = "elastic_ip"` and apply. A new
Elastic IP is allocated — it will not be the one you had before. The A record
is destroyed with it; if you would rather keep the name pointing at the new
fixed IP, leave the record in place by managing it outside this stack.

In both cases the change reaches the instance on its next boot, so `/stop` and
`/start` before telling anyone the new address.

## Troubleshooting

**`dig` still returns `192.0.2.1`.** The instance has not completed a boot
since the record was created, or `announce-address.sh` failed. Check:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo journalctl -u minecraft | grep -i route53
```

**"Route 53 update failed; players will not be able to resolve the hostname"**
in the journal, and the server did not start. Almost always an `AccessDenied`,
because the IAM policy names the zone, the record and the type explicitly. The
usual cause is a `route53_zone_id` that does not match the zone the record name
lives in. Confirm with `aws route53 list-hosted-zones` and re-apply — the
policy is regenerated from the same variables, so an apply fixes both at once.

The other way to get an `AccessDenied` here — a record name the condition key
cannot express — is now refused by Terraform before it can be deployed, so an
existing stack is the only way to still hit it. Re-running `terraform apply`
after an upgrade will surface it as a validation error on
`route53_record_name`.

To see the underlying error rather than the script's summary:

```bash
sudo journalctl -u minecraft -n 100 | grep -A 5 route53
```

**The name does not resolve at all, from anywhere.** The zone exists but the
domain is not delegated to it. Compare the four nameservers on the hosted zone
detail page against what the registrar publishes:

```bash
dig +short NS example.com
```

If they differ, the registrar is still authoritative and nothing in Route 53
takes effect. This is the most common failure for a domain registered
elsewhere.

**It resolves for you but not for a player.** A resolver is holding the old
value. `route53_ttl` bounds this; if you have just lowered the TTL, the *old*
TTL governs how long the stale answer survives.

**"InvalidChangeBatch" in the journal.** `route53_record_name` is not inside
the zone that `route53_zone_id` identifies — for example the zone is
`example.com` but the record is `mc.example.org`.

---

Every setting mentioned here, with its type and default, is in the
[configuration reference](configuration.md#addressing).
