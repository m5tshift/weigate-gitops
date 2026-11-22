#!/usr/bin/env bash
# Applies platform/clickhouse/full/ddl/*.sql to ClickHouse in a container (the image of the ClickHouseInstallation) twice,
# then checks the tables and the report views on test rows inserted into the target tables.
# Kafka-engine tables are created without a broker; the parsing in the materialized views is not covered here.
# Usage: hack/ddl.sh   (needs docker and yq v4)
set -euo pipefail
cd "$(dirname "$0")/.."

image=$(yq eval '.spec.templates.podTemplates[0].spec.containers[0].image' platform/clickhouse/full/clickhouse.yaml)
name=ddl-test-$$
docker run -d --rm --name "$name" "$image" > /dev/null
trap 'docker stop "$name" > /dev/null 2>&1 || true' EXIT
ch() { docker exec -i "$name" clickhouse-client "$@"; }

for _ in $(seq 60); do ch --query 'SELECT 1' </dev/null > /dev/null 2>&1 && break; sleep 1; done
ch --query 'SELECT 1' </dev/null > /dev/null

for run in 1 2; do
  for f in platform/clickhouse/full/ddl/*.sql; do ch --multiquery < "$f"; done
  echo "ddl: run $run applied"
done

fail=0
expect() { # expect <name> <want> <query>
  got=$(ch --query "$3" </dev/null)
  want=$(printf "$2")
  if [ "$got" = "$want" ]; then echo "ddl: $1 ok"; else echo "ddl: $1: want '$want', got '$got'"; fail=1; fi
}

expect objects "chain_transfers chain_transfers_mv chain_transfers_queue invoice_events invoice_events_mv invoice_events_queue invoice_state merchant_conversion_daily merchant_turnover_daily rate_ohlc_1m rate_ticks rate_ticks_mv rate_ticks_queue" \
  "SELECT arrayStringConcat(groupArray(name), ' ') FROM (SELECT name FROM system.tables WHERE database = 'weigate' ORDER BY name)"
expect kafka-engines "3" "SELECT count() FROM system.tables WHERE database = 'weigate' AND engine = 'Kafka'"

# Two invoices of merchant m1: one created and paid (the paid event is delivered twice), one only created.
ch --query "INSERT INTO weigate.invoice_events (event_id, event_type, event_time, invoice_id, merchant_id, sequence, status, amount_usd_cents) VALUES
  ('e1', 'invoice.created', '2026-05-01 10:00:00', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 1, 'NEW', 1000),
  ('e2', 'invoice.paid', '2026-05-01 10:05:00', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 5, 'PAID', 0),
  ('e2', 'invoice.paid', '2026-05-01 10:05:00', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 5, 'PAID', 0),
  ('e3', 'invoice.created', '2026-05-01 11:00:00', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a1', 1, 'NEW', 500)" </dev/null
expect turnover "2026-05-01\t1\t1000" \
  "SELECT day, paid_invoices, turnover_usd_cents FROM weigate.merchant_turnover_daily"
expect conversion "2026-05-01\t2\t1\t0.5" \
  "SELECT day, created_invoices, paid_invoices, conversion FROM weigate.merchant_conversion_daily"

ch --query "INSERT INTO weigate.rate_ticks VALUES
  ('t1', 'coinbase', 'ETH-USD', 2000.5, '2026-05-01 10:00:10'),
  ('t2', 'coinbase', 'ETH-USD', 2010.25, '2026-05-01 10:00:50'),
  ('t3', 'coinbase', 'ETH-USD', 1990, '2026-05-01 10:00:30')" </dev/null
expect ohlc "coinbase\tETH-USD\t2000.5\t2010.25\t1990\t2010.25" \
  "SELECT source, pair, open, high, low, close FROM weigate.rate_ohlc_1m"

exit "$fail"
