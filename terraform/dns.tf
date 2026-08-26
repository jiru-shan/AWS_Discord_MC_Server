# Created so the name resolves from the moment the stack exists, rather than
# only after the first boot. The boot script owns the value from then on.

resource "aws_route53_record" "server" {
  count = local.use_route53 ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.record_name
  type    = "A"
  ttl     = var.route53_ttl

  # Placeholder from RFC 5737 TEST-NET-1. announce-address.sh replaces it with
  # the real address before the server accepts connections.
  records = ["192.0.2.1"]

  lifecycle {
    # The instance rewrites this on every boot. Without this, every apply would
    # propose reverting the record to the placeholder above.
    ignore_changes = [records]
  }
}
