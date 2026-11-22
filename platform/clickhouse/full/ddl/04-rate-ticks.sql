-- rate.ticks (SRS 4.1.5): quote history; the price is a decimal string in the source's quote currency.
CREATE TABLE IF NOT EXISTS weigate.rate_ticks_queue
(
    raw String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'weigate-kafka-bootstrap.kafka:9092',
         kafka_topic_list = 'rate.ticks',
         kafka_group_name = 'clickhouse-rate-ticks',
         kafka_format = 'JSONAsString',
         kafka_handle_error_mode = 'stream';

CREATE TABLE IF NOT EXISTS weigate.rate_ticks
(
    event_id String,
    source LowCardinality(String),
    pair LowCardinality(String),
    price Decimal(38, 18),
    quoted_at DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(quoted_at)
ORDER BY (source, pair, quoted_at, event_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS weigate.rate_ticks_mv TO weigate.rate_ticks AS
SELECT
    JSONExtractString(raw, 'id') AS event_id,
    JSONExtractString(raw, 'data', 'source') AS source,
    JSONExtractString(raw, 'data', 'pair') AS pair,
    toDecimal128OrZero(JSONExtractString(raw, 'data', 'price'), 18) AS price,
    parseDateTime64BestEffortOrZero(JSONExtractString(raw, 'data', 'quotedAt'), 3, 'UTC') AS quoted_at
FROM weigate.rate_ticks_queue
WHERE length(_error) = 0;
