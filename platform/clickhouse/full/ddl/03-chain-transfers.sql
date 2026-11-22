-- chain.transfers (SRS 4.1.5). Idempotency key: block_hash + tx_hash + log_index (empty for native ETH);
-- after a reorganization the same tx_hash arrives from another block and stays as a separate row.
CREATE TABLE IF NOT EXISTS weigate.chain_transfers_queue
(
    raw String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'weigate-kafka-bootstrap.kafka:9092',
         kafka_topic_list = 'chain.transfers',
         kafka_group_name = 'clickhouse-chain-transfers',
         kafka_format = 'JSONAsString',
         kafka_handle_error_mode = 'stream';

CREATE TABLE IF NOT EXISTS weigate.chain_transfers
(
    event_id String,
    event_time DateTime64(3, 'UTC'),
    chain_id UInt64,
    block_number UInt64,
    block_hash String,
    block_time DateTime('UTC'),
    tx_hash String,
    log_index Nullable(UInt32),
    from_address String,
    to_address String,
    amount UInt256,
    asset_kind LowCardinality(String),
    asset_contract String
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(block_time)
ORDER BY (block_hash, tx_hash, ifNull(log_index, 4294967295));

CREATE MATERIALIZED VIEW IF NOT EXISTS weigate.chain_transfers_mv TO weigate.chain_transfers AS
SELECT
    JSONExtractString(raw, 'id') AS event_id,
    parseDateTime64BestEffortOrZero(JSONExtractString(raw, 'time'), 3, 'UTC') AS event_time,
    JSONExtractUInt(raw, 'data', 'chainId') AS chain_id,
    JSONExtractUInt(raw, 'data', 'blockNumber') AS block_number,
    JSONExtractString(raw, 'data', 'blockHash') AS block_hash,
    toDateTime(JSONExtractUInt(raw, 'data', 'blockTimestamp'), 'UTC') AS block_time,
    JSONExtractString(raw, 'data', 'txHash') AS tx_hash,
    JSONExtract(raw, 'data', 'logIndex', 'Nullable(UInt32)') AS log_index,
    JSONExtractString(raw, 'data', 'from') AS from_address,
    JSONExtractString(raw, 'data', 'to') AS to_address,
    toUInt256OrZero(JSONExtractString(raw, 'data', 'amount')) AS amount,
    JSONExtractString(raw, 'data', 'asset', 'kind') AS asset_kind,
    JSONExtractString(raw, 'data', 'asset', 'contract') AS asset_contract
FROM weigate.chain_transfers_queue
WHERE length(_error) = 0;
