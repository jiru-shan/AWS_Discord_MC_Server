#!/usr/bin/env bash
# Publish this boot's address, then record it for the rest of the boot.
#
# Runs as ExecStartPre of minecraft.service, so it completes before the Java
# process starts. In route53 mode it points the A record at the fresh public IP;
# in elastic_ip mode the address never changes and there is nothing to publish.

set -euo pipefail
. "$(dirname "$0")/common.sh"

ip=$(public_ipv4) || die "could not read this instance's public IPv4 from IMDS"
log "public IPv4 is $ip"

case "${ADDRESSING_MODE:-none}" in
  route53)
    [ -n "${ROUTE53_ZONE_ID:-}" ] || die "ADDRESSING_MODE=route53 but ROUTE53_ZONE_ID is unset"
    [ -n "${ROUTE53_RECORD_NAME:-}" ] || die "ADDRESSING_MODE=route53 but ROUTE53_RECORD_NAME is unset"

    log "pointing ${ROUTE53_RECORD_NAME} at ${ip}"
    batch=$(jq -nc \
      --arg name "$ROUTE53_RECORD_NAME" \
      --arg ip "$ip" \
      --argjson ttl "${ROUTE53_TTL:-30}" \
      '{Comment: "minecraft on-demand server boot",
        Changes: [{Action: "UPSERT",
                   ResourceRecordSet: {Name: $name, Type: "A", TTL: $ttl,
                                       ResourceRecords: [{Value: $ip}]}}]}')

    aws route53 change-resource-record-sets \
      --hosted-zone-id "$ROUTE53_ZONE_ID" \
      --change-batch "$batch" >/dev/null \
      || die "Route 53 update failed; players will not be able to resolve the hostname"

    address="${ROUTE53_RECORD_NAME%.}"
    ;;

  elastic_ip)
    # The Elastic IP is attached by AWS before the instance boots, so the
    # metadata address already is the stable one.
    address="${STATIC_ADDRESS:-$ip}"
    ;;

  *)
    address="$ip"
    ;;
esac

echo "$address" > "$RUN_DIR/address"
log "connect address for this boot: $(connect_address_with_port)"
