#!/usr/bin/env bash
set -euo pipefail

AKVORADO_DIR="/opt/akvorado"
CSV_FILE="/opt/akvorado/customer-mapping/customer_ip_map.csv"
JOB_NAME="customer_traffic_5m"

cd "$AKVORADO_DIR"

log() {
    echo "[$(date '+%F %T')] $*"
}

ch_query() {
    docker compose exec -T clickhouse clickhouse-client --query "$1"
}

ch_multiquery() {
    docker compose exec -T clickhouse clickhouse-client --multiquery
}

log "Start customer traffic rollup"

log "Sync customer mapping"
ch_query "TRUNCATE TABLE default.customer_ip_map"

tail -n +2 "$CSV_FILE" | \
docker compose exec -T clickhouse clickhouse-client --query "
INSERT INTO default.customer_ip_map
    (customer_name, customer_ip, description, enabled)
SELECT
    trimBoth(raw_customer_name) AS customer_name,
    assumeNotNull(toIPv6OrNull(concat('::ffff:', trimBoth(raw_customer_ip)))) AS customer_ip,
    trimBoth(raw_description) AS description,
    toUInt8OrZero(trimBoth(raw_enabled)) AS enabled
FROM input(
    'raw_customer_name String,
     raw_customer_ip String,
     raw_description String,
     raw_enabled String'
)
WHERE trimBoth(raw_customer_name) != ''
  AND trimBoth(raw_customer_ip) != ''
  AND isNotNull(toIPv6OrNull(concat('::ffff:', trimBoth(raw_customer_ip))))
FORMAT CSV
"

log "Read rollup state"

MAX_BLOCKS=12
PROCESSED=0

while true; do
    BLOCK_START=$(ch_query "
SELECT last_processed_time + INTERVAL 5 MINUTE
FROM default.customer_traffic_rollup_state FINAL
WHERE job_name = '$JOB_NAME'
FORMAT TabSeparatedRaw
" | tr -d '\r')

    LATEST_COMPLETE_BLOCK=$(ch_query "
SELECT toStartOfInterval(now(), INTERVAL 5 MINUTE) - INTERVAL 5 MINUTE
FORMAT TabSeparatedRaw
" | tr -d '\r')

    log "block_start=$BLOCK_START latest_complete_block=$LATEST_COMPLETE_BLOCK processed=$PROCESSED"

    if [[ "$BLOCK_START" > "$LATEST_COMPLETE_BLOCK" ]]; then
        log "No new completed block"
        break
    fi

    if (( PROCESSED >= MAX_BLOCKS )); then
        log "Reached max blocks per run: $MAX_BLOCKS"
        break
    fi

    log "Insert rollup block $BLOCK_START"
    ch_query "
INSERT INTO default.customer_traffic_5m
SELECT
    toStartOfInterval(f.TimeReceived, INTERVAL 5 MINUTE) AS time,
    if(m_src.customer_name != '', m_src.customer_name, m_dst.customer_name) AS customer_name,
    if(m_src.customer_name != '', 'Upload', 'Download') AS direction,
    if(
        if(m_src.customer_name != '', f.DstCountry, f.SrcCountry) = 'VN',
        'Domestic',
        'International'
    ) AS traffic_type,
    sum(f.Bytes * f.SamplingRate) AS bytes,
    sum(f.Packets * f.SamplingRate) AS packets,
    now() AS updated_at
FROM default.flows AS f
LEFT JOIN default.customer_ip_map AS m_src
    ON f.SrcAddr = m_src.customer_ip AND m_src.enabled = 1
LEFT JOIN default.customer_ip_map AS m_dst
    ON f.DstAddr = m_dst.customer_ip AND m_dst.enabled = 1
WHERE f.TimeReceived >= toDateTime('$BLOCK_START')
  AND f.TimeReceived <  toDateTime('$BLOCK_START') + INTERVAL 5 MINUTE
  AND (m_src.customer_name != '') != (m_dst.customer_name != '')
GROUP BY
    time,
    customer_name,
    direction,
    traffic_type
"

    log "Update state to $BLOCK_START"
    cat <<SQL | docker compose exec -T clickhouse clickhouse-client --multiquery
INSERT INTO default.customer_traffic_rollup_state
    (job_name, last_processed_time, updated_at)
VALUES
    ('$JOB_NAME', toDateTime('$BLOCK_START'), now());
SQL

    PROCESSED=$((PROCESSED + 1))
done

log "Done. processed_blocks=$PROCESSED"
