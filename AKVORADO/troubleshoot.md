# 1. Check top source flow record
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    replaceOne(toString(SrcAddr), '::ffff:', '') AS src_ip,
    count() AS flow_records
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
GROUP BY SrcAddr
ORDER BY flow_records DESC
LIMIT 10
FORMAT PrettyCompact
"
```

# 2.Top Destination IP Theo Flow Records
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    replaceOne(toString(DstAddr), '::ffff:', '') AS dst_ip,
    count() AS flow_records
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
GROUP BY DstAddr
ORDER BY flow_records DESC
LIMIT 10
FORMAT PrettyCompact
"
```

# 3. Check Riêng Một IP Nghi Ngờ
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
WITH toIPv6('::ffff:103.205.98.41') AS target_ip
SELECT
    countIf(SrcAddr = target_ip) AS upload_flows,
    countIf(DstAddr = target_ip) AS download_flows,
    count() AS total_flows_checked,
    round(sumIf(Bytes * SamplingRate, SrcAddr = target_ip) * 8 / 30 / 1000000, 2) AS upload_mbps,
    round(sumIf(Bytes * SamplingRate, DstAddr = target_ip) * 8 / 30 / 1000000, 2) AS download_mbps
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
WHERE SrcAddr = target_ip OR DstAddr = target_ip
FORMAT PrettyCompact
"
```

# 4. Check 1 IP Trong mạng đang upload đi đâu
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
WITH toIPv6('::ffff:103.205.98.41') AS target_ip
SELECT
    replaceOne(toString(DstAddr), '::ffff:', '') AS dst_ip,
    DstPort,
    count() AS flows,
    round(sum(Bytes * SamplingRate) * 8 / 30 / 1000000, 2) AS mbps
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
WHERE SrcAddr = target_ip
GROUP BY
    DstAddr,
    DstPort
ORDER BY flows DESC
LIMIT 20
FORMAT PrettyCompact
"
```

# 5. Check TOP Upload
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    replaceOne(toString(SrcAddr), '::ffff:', '') AS src_ip,
    count() AS flow_records,
    uniqExact(DstAddr) AS destination_count,
    round(sum(Packets * SamplingRate) / 30, 0) AS pps,
    round(sum(Bytes * SamplingRate) * 8 / 30 / 1000000, 2) AS mbps,
    round(sum(Bytes * SamplingRate) / nullIf(sum(Packets * SamplingRate), 0), 0) AS avg_packet_bytes
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
WHERE
    (
        SrcAddr >= toIPv6('::ffff:103.141.177.0')
        AND SrcAddr <= toIPv6('::ffff:103.141.177.255')
    )
    OR
    (
        SrcAddr >= toIPv6('::ffff:103.205.98.0')
        AND SrcAddr <= toIPv6('::ffff:103.205.98.255')
    )
GROUP BY SrcAddr
ORDER BY flow_records DESC
LIMIT 20
FORMAT PrettyCompact
"
```

# 6. Check TOP Download
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    replaceOne(toString(DstAddr), '::ffff:', '') AS dst_ip,
    count() AS flow_records,
    uniqExact(SrcAddr) AS source_count,
    round(sum(Packets * SamplingRate) / 30, 0) AS pps,
    round(sum(Bytes * SamplingRate) * 8 / 30 / 1000000, 2) AS mbps,
    round(sum(Bytes * SamplingRate) / nullIf(sum(Packets * SamplingRate), 0), 0) AS avg_packet_bytes
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
WHERE
    (
        DstAddr >= toIPv6('::ffff:103.141.177.0')
        AND DstAddr <= toIPv6('::ffff:103.141.177.255')
    )
    OR
    (
        DstAddr >= toIPv6('::ffff:103.205.98.0')
        AND DstAddr <= toIPv6('::ffff:103.205.98.255')
    )
GROUP BY DstAddr
ORDER BY flow_records DESC
LIMIT 20
FORMAT PrettyCompact
"
```

# 7. Check Dung Lượng ClickHouse Theo Table
```
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    sum(rows) AS rows
FROM system.parts
WHERE database = 'default'
  AND active
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC
FORMAT PrettyCompact
"
```





