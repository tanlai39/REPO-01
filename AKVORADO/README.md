# Akvorado + Grafana NetFlow Operation README

Tài liệu này mô tả kiến trúc, thành phần cấu hình quan trọng và các thao tác vận hành hệ thống Akvorado/Grafana dùng để giám sát NetFlow Cisco theo IP/khách hàng.

## 1. Mục Tiêu Hệ Thống

- Thu thập NetFlow từ router Cisco core.
- Lưu raw flow vào ClickHouse qua Akvorado.
- Hiển thị traffic theo IP, khách hàng, chiều Upload/Download, Domestic/International trên Grafana.
- Có dashboard realtime để phát hiện bất thường: high flows/s, PPS cao, nhiều destination/source, packet nhỏ.
- Lưu traffic khách hàng dạng rollup 5 phút để xem dữ liệu dài ngày nhẹ hơn raw `flows`.

## 2. Kiến Trúc Tổng Quan

```text
Cisco ASR Core Routers
    -> Akvorado Inlet
        -> Kafka
            -> Akvorado Outlet
                -> ClickHouse
                    -> Grafana Dashboards
```

Thành phần chính:

| Thành phần | Vai trò |
|---|---|
| Cisco Core | Export NetFlow từ các interface public/internal |
| Akvorado | Collector, enricher, exporter |
| Kafka | Buffer flow trước khi ghi ClickHouse |
| ClickHouse | Lưu raw flows và bảng aggregate |
| Grafana | Dashboard vận hành, customer traffic, DDoS view |
| CSV mapping | Map IP public với tên khách hàng |

## 3. Đường Dẫn Quan Trọng

| Đường dẫn | Mục đích |
|---|---|
| `/opt/akvorado` | Thư mục chính Docker Compose Akvorado |
| `/opt/akvorado/customer-mapping/customer_ip_map.csv` | File mapping IP khách hàng |
| `/opt/akvorado/customer-rollup/customer_traffic_rollup.sh` | Script sync mapping và rollup traffic 5 phút |
| `/var/log/customer_traffic_rollup.log` | Log cron rollup |
| `/data/clickhouse` | Dữ liệu ClickHouse |
| `/data/kafka` | Dữ liệu Kafka |

## 4. Dải IP Đang Giám Sát

| Range | Ghi chú |
|---|---|
| `103.141.177.0/24` | Public customer range |
| `103.205.98.0/24` | Public customer range |

Trong ClickHouse, IPv4 thường được lưu dạng IPv4-mapped IPv6:

```sql
toIPv6('::ffff:103.141.177.22')
```

Khi hiển thị lại IPv4:

```sql
replaceOne(toString(SrcAddr), '::ffff:', '')
```

## 5. ClickHouse Tables Quan Trọng

### 5.1 Raw/Akvorado Default Tables

| Table | Vai trò | Ghi chú |
|---|---|---|
| `default.flows` | Raw flow chi tiết | Có `SrcAddr`, `DstAddr`; dùng troubleshoot, query từng IP |
| `default.flows_1m0s` | Aggregate 1 phút mặc định | Dùng dashboard tổng hợp |
| `default.flows_5m0s` | Aggregate 5 phút mặc định | Nhẹ hơn raw, không dùng tốt cho per-customer IP mapping |
| `default.flows_1h0m0s` | Aggregate 1 giờ mặc định | Trend dài ngày |

### 5.2 Customer Mapping Table

```sql
CREATE TABLE IF NOT EXISTS default.customer_ip_map
(
    customer_name LowCardinality(String),
    customer_ip IPv6,
    description String,
    enabled UInt8,
    updated_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (customer_ip, customer_name);
```

CSV nguồn:

```csv
customer_name,customer_ip,description,enabled
ORG-ILOTUSLAND,103.141.177.22,,1
ORG-ILOTUSLAND,103.141.177.23,,1
```

Ý nghĩa:

| Cột | Ý nghĩa |
|---|---|
| `customer_name` | Tên khách hàng |
| `customer_ip` | IP public của khách |
| `description` | Ghi chú |
| `enabled` | `1` đang dùng, `0` chưa dùng hoặc đã disable |
| `updated_at` | Thời điểm import/sync |

### 5.3 Customer Rollup 5 Phút

```sql
CREATE TABLE IF NOT EXISTS default.customer_traffic_5m
(
    time DateTime,
    customer_name LowCardinality(String),
    direction LowCardinality(String),
    traffic_type LowCardinality(String),
    bytes UInt64,
    packets UInt64,
    updated_at DateTime DEFAULT now()
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(time)
ORDER BY (customer_name, time, direction, traffic_type)
TTL time + INTERVAL 90 DAY;
```

Table này lưu traffic đã map theo customer:

| Cột | Ý nghĩa |
|---|---|
| `time` | Mốc 5 phút |
| `customer_name` | Tên khách tại thời điểm rollup |
| `direction` | `Upload` hoặc `Download` |
| `traffic_type` | `Domestic` hoặc `International` |
| `bytes` | Tổng bytes đã nhân SamplingRate |
| `packets` | Tổng packets đã nhân SamplingRate |

Lưu ý quan trọng:

- Dữ liệu trong `customer_traffic_5m` không tự đổi tên khi sửa CSV mapping.
- Nếu IP đổi sang khách khác, dữ liệu cũ vẫn giữ tên khách cũ đã được rollup.
- Đây là hành vi tốt cho vận hành vì khách mới không bị dính dữ liệu lịch sử của khách cũ.

### 5.4 Rollup State Table

```sql
CREATE TABLE IF NOT EXISTS default.customer_traffic_rollup_state
(
    job_name String,
    last_processed_time DateTime,
    updated_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY job_name;
```

Mục đích:

- Lưu block 5 phút cuối cùng đã xử lý.
- Tránh insert trùng dữ liệu vào `SummingMergeTree`.
- Nếu insert trùng cùng `time/customer/direction/traffic_type`, ClickHouse sẽ cộng đôi số liệu.

## 6. Customer Mapping Sync

Import/sync CSV vào ClickHouse:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
TRUNCATE TABLE default.customer_ip_map
"

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
FORMAT CSVWithNames
" < /opt/akvorado/customer-mapping/customer_ip_map.csv
```

Check mapping:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    count() AS total_rows,
    countIf(enabled = 1) AS enabled_rows,
    countIf(enabled = 0) AS disabled_rows,
    uniqExact(customer_name) AS total_customers
FROM default.customer_ip_map
FORMAT PrettyCompact
"
```

Check một khách:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    customer_name,
    replaceOne(toString(customer_ip), '::ffff:', '') AS customer_ip,
    description,
    enabled
FROM default.customer_ip_map
WHERE customer_name = 'ORG-ILOTUSLAND'
ORDER BY customer_ip
FORMAT PrettyCompact
"
```

## 7. Customer Traffic Rollup

Script chạy tại:

```bash
/opt/akvorado/customer-rollup/customer_traffic_rollup.sh
```

Cron root:

```cron
*/5 * * * * /opt/akvorado/customer-rollup/customer_traffic_rollup.sh >> /var/log/customer_traffic_rollup.log 2>&1
```

Check cron:

```bash
crontab -l
systemctl status cron --no-pager
tail -200 /var/log/customer_traffic_rollup.log
```

Check state:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    job_name,
    last_processed_time,
    updated_at
FROM default.customer_traffic_rollup_state FINAL
FORMAT PrettyCompact
"
```

Check dữ liệu rollup mới nhất:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    max(time) AS newest_time,
    count() AS rows,
    uniqExact(customer_name) AS customers
FROM default.customer_traffic_5m
FORMAT PrettyCompact
"
```

## 8. Grafana Customer Traffic Query

Query panel theo biến `$customer`:

```sql
SELECT
    time,
    concat(direction, ' ', traffic_type) AS series,
    round(sum(bytes) * 8 / 300000000, 2) AS Mbps
FROM default.customer_traffic_5m
WHERE $__timeFilter(time)
  AND customer_name = '$customer'
GROUP BY
    time,
    series
ORDER BY
    time,
    series
```

Variable `customer`:

```sql
SELECT DISTINCT customer_name
FROM default.customer_ip_map
WHERE enabled = 1
ORDER BY customer_name
```

Panel gợi ý:

| Setting | Giá trị |
|---|---|
| Query Type | Time Series |
| Unit | Mbps |
| Legend | `{{series}}` |
| Min interval | `5m` |
| Default dashboard range | `Last 3 hours` hoặc `Last 24 hours` |

## 9. Top Customer Traffic Query

Query này tính average Mbps tổng Upload + Download của từng khách trong time range Grafana đang chọn.

```sql
WITH customer_traffic AS
(
    SELECT
        m.customer_name,
        sum(f.Bytes * f.SamplingRate) AS total_bytes
    FROM default.flows AS f
    INNER JOIN default.customer_ip_map AS m
        ON f.SrcAddr = m.customer_ip
    WHERE $__timeFilter(f.TimeReceived)
      AND m.enabled = 1
    GROUP BY m.customer_name

    UNION ALL

    SELECT
        m.customer_name,
        sum(f.Bytes * f.SamplingRate) AS total_bytes
    FROM default.flows AS f
    INNER JOIN default.customer_ip_map AS m
        ON f.DstAddr = m.customer_ip
    WHERE $__timeFilter(f.TimeReceived)
      AND m.enabled = 1
    GROUP BY m.customer_name
)

SELECT
    customer_name,
    round(
        sum(total_bytes) * 8
        / greatest((${__to} - ${__from}) / 1000, 1)
        / 1000000,
        2
    ) AS average_mbps
FROM customer_traffic
GROUP BY customer_name
ORDER BY average_mbps DESC
LIMIT 5
```

Khuyến nghị:

- Dashboard realtime nên để default time range `Last 30 minutes`.
- Query này dùng raw `default.flows`, không nên mở range quá dài khi đang incident.

## 10. DDoS/High PPS Dashboard

### 10.1 Total Inbound PPS

```sql
SELECT
    toStartOfMinute(f.TimeReceived) AS time,
    round(sum(f.Packets * f.SamplingRate) / 60, 0) AS pps
FROM default.flows AS f
WHERE
    $__timeFilter(f.TimeReceived)
    AND f.InIfBoundary = 'external'
    AND f.OutIfBoundary = 'internal'
    AND
    (
        (f.DstAddr >= toIPv6('::ffff:103.141.177.0') AND f.DstAddr <= toIPv6('::ffff:103.141.177.255'))
        OR
        (f.DstAddr >= toIPv6('::ffff:103.205.98.0') AND f.DstAddr <= toIPv6('::ffff:103.205.98.255'))
    )
GROUP BY time
ORDER BY time
```

### 10.2 Total Inbound BPS

```sql
SELECT
    toStartOfMinute(f.TimeReceived) AS time,
    round(sum(f.Bytes * f.SamplingRate) * 8 / 60, 0) AS bps
FROM default.flows AS f
WHERE
    $__timeFilter(f.TimeReceived)
    AND f.InIfBoundary = 'external'
    AND f.OutIfBoundary = 'internal'
    AND
    (
        (f.DstAddr >= toIPv6('::ffff:103.141.177.0') AND f.DstAddr <= toIPv6('::ffff:103.141.177.255'))
        OR
        (f.DstAddr >= toIPv6('::ffff:103.205.98.0') AND f.DstAddr <= toIPv6('::ffff:103.205.98.255'))
    )
GROUP BY time
ORDER BY time
```

### 10.3 Total Outbound PPS

Do không phải traffic upload nào cũng có `OutIfBoundary='external'`, dashboard outbound nên lọc theo `SrcAddr` public range, không phụ thuộc boundary.

```sql
SELECT
    toStartOfMinute(f.TimeReceived) AS time,
    round(sum(f.Packets * f.SamplingRate) / 60, 0) AS pps
FROM default.flows AS f
WHERE
    $__timeFilter(f.TimeReceived)
    AND
    (
        (f.SrcAddr >= toIPv6('::ffff:103.141.177.0') AND f.SrcAddr <= toIPv6('::ffff:103.141.177.255'))
        OR
        (f.SrcAddr >= toIPv6('::ffff:103.205.98.0') AND f.SrcAddr <= toIPv6('::ffff:103.205.98.255'))
    )
GROUP BY time
ORDER BY time
```

### 10.4 Total Outbound BPS

```sql
SELECT
    toStartOfMinute(f.TimeReceived) AS time,
    round(sum(f.Bytes * f.SamplingRate) * 8 / 60, 0) AS bps
FROM default.flows AS f
WHERE
    $__timeFilter(f.TimeReceived)
    AND
    (
        (f.SrcAddr >= toIPv6('::ffff:103.141.177.0') AND f.SrcAddr <= toIPv6('::ffff:103.141.177.255'))
        OR
        (f.SrcAddr >= toIPv6('::ffff:103.205.98.0') AND f.SrcAddr <= toIPv6('::ffff:103.205.98.255'))
    )
GROUP BY time
ORDER BY time
```

## 11. Incident Query Runbook

### 11.1 Top Source IP Theo Flow Records

```bash
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

### 11.2 Top Destination IP Theo Flow Records

```bash
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

### 11.3 Check Riêng Một IP Nghi Ngờ

```bash
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

### 11.4 IP Nghi Ngờ Đang Đi Đâu

```bash
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

### 11.5 Traffic IP Đi Qua Interface Nào

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
WITH toIPv6('::ffff:103.205.98.41') AS target_ip
SELECT
    ExporterName,
    InIfBoundary,
    OutIfBoundary,
    InIfName,
    OutIfName,
    count() AS flow_records
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 5 MINUTE
WHERE SrcAddr = target_ip OR DstAddr = target_ip
GROUP BY
    ExporterName,
    InIfBoundary,
    OutIfBoundary,
    InIfName,
    OutIfName
ORDER BY flow_records DESC
LIMIT 20
FORMAT PrettyCompact
"
```

### 11.6 Check IP Đang Download Từ Source Nào

Ví dụ check `103.141.177.22`:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
WITH toIPv6('::ffff:103.141.177.22') AS target_ip
SELECT
    replaceOne(toString(SrcAddr), '::ffff:', '') AS source_ip,
    SrcCountry,
    SrcAS,
    DstPort,
    ExporterName,
    InIfName,
    OutIfName,
    count() AS flow_records,
    round(sum(Packets * SamplingRate) / 30, 0) AS pps,
    round(sum(Bytes * SamplingRate) * 8 / 30 / 1000000, 2) AS mbps,
    round(sum(Bytes * SamplingRate) / nullIf(sum(Packets * SamplingRate), 0), 0) AS avg_packet_bytes
FROM default.flows
PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND
WHERE DstAddr = target_ip
GROUP BY
    SrcAddr,
    SrcCountry,
    SrcAS,
    DstPort,
    ExporterName,
    InIfName,
    OutIfName
ORDER BY flow_records DESC
LIMIT 20
FORMAT PrettyCompact
"
```

## 12. Server Health Check

### 12.1 Query Đang Chạy Trong ClickHouse

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    query_id,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(memory_usage) AS memory,
    query
FROM system.processes
WHERE query NOT LIKE '%system.processes%'
ORDER BY elapsed DESC
LIMIT 10
FORMAT PrettyCompact
"
```

Nếu không có output hoặc chỉ thấy query check chính nó, nghĩa là hiện không có query nặng đang chạy.

### 12.2 Dung Lượng ClickHouse Theo Table

```bash
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

### 12.3 Disk Server

```bash
df -h /data
du -sh /data/* 2>/dev/null
```

Nếu `du` báo lỗi `tmp_merge_* no such file`, đây thường là do ClickHouse đang merge part, không phải lỗi hư dữ liệu.

## 13. Bài Học Từ Sự Cố High Flows/s

Sự cố IP `103.205.98.41` cho thấy:

- Mbps không cao nhưng flow records/s cực lớn.
- Packet nhỏ, rất nhiều destination, làm Akvorado/ClickHouse/Grafana bị ảnh hưởng.
- Portgroup shaping giảm Mbps nhưng không trị tận gốc flow/PPS.
- Core ACL có thể vẫn thấy flow nếu NetFlow accounting xảy ra trước hoặc tại điểm drop.
- Chặn càng gần source càng hiệu quả.

Hướng xử lý khẩn cấp đã hiệu quả:

| Biện pháp | Tác dụng |
|---|---|
| MAC ACL tại switch access | Giảm mạnh flows/s vì chặn gần source |
| Portgroup shaping | Giảm băng thông VM gây nhiễu |
| Query top source flow records | Xác định nhanh IP gây high cardinality |
| Check interface/exporter | Xác định đường đi và thiết bị liên quan |

Ngưỡng tham khảo:

| Flows/s | Nhận xét |
|---:|---|
| `< 5k` | Bình thường |
| `10k - 30k` | Cần theo dõi, dashboard raw có thể bắt đầu chậm |
| `> 30k` | Incident, cần xác định source ngay |
| `> 60k` | Có nguy cơ ảnh hưởng collector/ClickHouse/Grafana |

## 14. Khuyến Nghị Vận Hành

- Dashboard realtime chỉ nên dùng raw `default.flows` với range ngắn: `Last 5m`, `Last 30m`, tối đa vài giờ.
- Dashboard khách hàng dài ngày nên dùng `default.customer_traffic_5m`.
- Khi incident high flows/s, ưu tiên query `PREWHERE TimeReceived >= now() - INTERVAL 30 SECOND`.
- Không mở dashboard raw với range 15 ngày trong lúc server đang bị high flow.
- Theo dõi disk `/data`, Kafka và ClickHouse sau các đợt high flows/s.
- Giữ lại Akvorado default aggregate tables, không drop nếu chưa có đánh giá đầy đủ.
- Khi sửa CSV mapping, kiểm tra ký tự khoảng trắng lạ bằng `hex(customer_name)` nếu Grafana không ra dữ liệu.

## 15. Checklist Sau Khi Thêm Khách Hàng Mới

1. Thêm IP vào `/opt/akvorado/customer-mapping/customer_ip_map.csv`.
2. Đảm bảo `customer_name` không có khoảng trắng đầu/cuối, đặc biệt NBSP.
3. Set `enabled=1`.
4. Chạy script hoặc chờ cron:

```bash
/opt/akvorado/customer-rollup/customer_traffic_rollup.sh
```

5. Check mapping:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    customer_name,
    replaceOne(toString(customer_ip), '::ffff:', '') AS customer_ip,
    enabled
FROM default.customer_ip_map
WHERE customer_name = 'CUSTOMER-NAME'
FORMAT PrettyCompact
"
```

6. Chờ ít nhất một block 5 phút hoàn thành để có dữ liệu trong Grafana.

## 16. Checklist Khi Grafana Không Có Data

1. Kiểm tra time range có nằm trong dữ liệu rollup chưa.
2. Query trực tiếp ClickHouse:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    customer_name,
    min(time) AS oldest_time,
    max(time) AS newest_time,
    count() AS rows
FROM default.customer_traffic_5m
WHERE customer_name LIKE '%CUSTOMER%'
GROUP BY customer_name
FORMAT PrettyCompact
"
```

3. Nếu nghi ngờ khoảng trắng/ký tự lạ:

```bash
cd /opt/akvorado

docker compose exec -T clickhouse clickhouse-client --query "
SELECT
    concat('[', customer_name, ']') AS customer_name_visible,
    hex(customer_name) AS customer_name_hex,
    count() AS rows,
    min(time) AS oldest_time,
    max(time) AS newest_time
FROM default.customer_traffic_5m
WHERE customer_name LIKE '%CUSTOMER%'
GROUP BY customer_name
ORDER BY oldest_time
FORMAT PrettyCompact
"
```

4. Mở Grafana Query Inspector để xem SQL thực tế.
5. Nếu variable không interpolate đúng, thử hard-code `customer_name = 'ORG-XXX'`.

## 17. Ghi Chú Bảo Mật Và HA

- User Grafana chỉ nên cấp quyền view dashboard cần thiết.
- ClickHouse user Grafana cần quyền `SELECT` trên các table dùng cho dashboard.
- Không dùng user admin ClickHouse cho Grafana nếu không cần.
- Nên backup định kỳ các file:
  - `/opt/akvorado/docker-compose.yml`
  - cấu hình Akvorado trong `/opt/akvorado`
  - `/opt/akvorado/customer-mapping/customer_ip_map.csv`
  - `/opt/akvorado/customer-rollup/customer_traffic_rollup.sh`
  - Grafana dashboards export JSON
- Với high availability thực sự, cần xem xét tách ClickHouse/Kafka/storage hoặc ít nhất có backup/restore procedure rõ ràng.

## 18. Lệnh Nhanh Hay Dùng

```bash
cd /opt/akvorado

# Xem container
docker compose ps

# Xem log rollup
tail -200 /var/log/customer_traffic_rollup.log

# Chạy rollup thủ công
/opt/akvorado/customer-rollup/customer_traffic_rollup.sh

# Check disk
df -h /data

# Check table size
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

