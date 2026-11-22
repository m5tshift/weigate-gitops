-- invoice.events (SRS 4.1.5): CloudEvents JSON from Kafka -> materialized view -> MergeTree.
-- Delivery is at-least-once: ReplacingMergeTree deduplicates by event id (read with FINAL).
-- Amounts are integers in wei; UInt256 holds values up to 1.15e77, longer ones become 0.
CREATE TABLE IF NOT EXISTS weigate.invoice_events_queue
(
    raw String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'weigate-kafka-bootstrap.kafka:9092',
         kafka_topic_list = 'invoice.events',
         kafka_group_name = 'clickhouse-invoice-events',
         kafka_format = 'JSONAsString',
         kafka_handle_error_mode = 'stream';

CREATE TABLE IF NOT EXISTS weigate.invoice_events
(
    event_id String,
    event_type LowCardinality(String),
    event_time DateTime64(3, 'UTC'),
    invoice_id UUID,
    merchant_id UUID,
    sequence UInt32,
    status LowCardinality(String),
    asset_kind LowCardinality(String),
    asset_contract String,
    amount UInt256,
    received UInt256,
    amount_usd_cents UInt64
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (merchant_id, invoice_id, event_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS weigate.invoice_events_mv TO weigate.invoice_events AS
SELECT
    JSONExtractString(raw, 'id') AS event_id,
    JSONExtractString(raw, 'type') AS event_type,
    parseDateTime64BestEffortOrZero(JSONExtractString(raw, 'time'), 3, 'UTC') AS event_time,
    toUUIDOrZero(JSONExtractString(raw, 'data', 'invoiceId')) AS invoice_id,
    toUUIDOrZero(JSONExtractString(raw, 'data', 'merchantId')) AS merchant_id,
    toUInt32(JSONExtractUInt(raw, 'data', 'sequence')) AS sequence,
    JSONExtractString(raw, 'data', 'status') AS status,
    JSONExtractString(raw, 'data', 'asset', 'kind') AS asset_kind,
    JSONExtractString(raw, 'data', 'asset', 'contract') AS asset_contract,
    toUInt256OrZero(JSONExtractString(raw, 'data', 'amount')) AS amount,
    toUInt256OrZero(JSONExtractString(raw, 'data', 'received')) AS received,
    JSONExtractUInt(raw, 'data', 'amountUsdCents') AS amount_usd_cents
FROM weigate.invoice_events_queue
WHERE length(_error) = 0;
