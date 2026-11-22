-- Views for reports (FR-11). They read the deduplicated tables (FINAL), so repeated deliveries are not counted twice.
-- The user reporting is read-only and reads these views.
CREATE VIEW IF NOT EXISTS weigate.invoice_state AS
SELECT
    invoice_id,
    any(merchant_id) AS merchant_id,
    min(event_time) AS created_at,
    max(event_type IN ('invoice.paid', 'invoice.late_paid')) AS is_paid,
    minIf(event_time, event_type IN ('invoice.paid', 'invoice.late_paid')) AS paid_at,
    max(amount_usd_cents) AS amount_usd_cents
FROM weigate.invoice_events FINAL
GROUP BY invoice_id;

CREATE VIEW IF NOT EXISTS weigate.merchant_turnover_daily AS
SELECT
    toDate(paid_at) AS day,
    merchant_id,
    count() AS paid_invoices,
    sum(amount_usd_cents) AS turnover_usd_cents
FROM weigate.invoice_state
WHERE is_paid = 1
GROUP BY day, merchant_id;

CREATE VIEW IF NOT EXISTS weigate.merchant_conversion_daily AS
SELECT
    toDate(created_at) AS day,
    merchant_id,
    count() AS created_invoices,
    sum(is_paid) AS paid_invoices,
    sum(is_paid) / count() AS conversion
FROM weigate.invoice_state
GROUP BY day, merchant_id;

CREATE VIEW IF NOT EXISTS weigate.rate_ohlc_1m AS
SELECT
    source,
    pair,
    toStartOfMinute(quoted_at) AS minute,
    argMin(price, quoted_at) AS open,
    max(price) AS high,
    min(price) AS low,
    argMax(price, quoted_at) AS close
FROM weigate.rate_ticks FINAL
GROUP BY source, pair, minute;
