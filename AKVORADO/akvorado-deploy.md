# Tai lieu trien khai Akvorado + Grafana giam sat NetFlow

Ngay tong hop: 2026-08-11  
He thong: NetFlow server `netflow`  
Pham vi: cai dat Akvorado, ClickHouse, Kafka, GeoIP, Grafana, Traefik/HTTPS va dashboard giam sat bang thong theo IP/customer.  
Khong bao gom: huong dan cau hinh NetFlow tren router Cisco.

## 1. Muc tieu trien khai

He thong duoc dung de thu thap NetFlow tu router Cisco, luu vao ClickHouse thong qua Akvorado, sau do dung Grafana de tao dashboard theo doi bang thong:

- Theo tung IP hoac nhom IP customer.
- Tach Upload/Download.
- Tach Domestic/International dua tren GeoIP country.
- Xem realtime de troubleshoot.
- Xem xu huong dai ngay bang bang aggregate cua Akvorado.
- Public dashboard Grafana qua domain rieng `traffic.tpcloud.vn`.
- Bao ve Akvorado Console/Traefik bang Basic Auth qua `netflow.tpcloud.vn`.
## Kiến trúc

```text
Cisco ASR R1/R2
   │ NetFlow v9 UDP/2055
   ▼
Akvorado Inlet
   │
   ▼
Kafka → Akvorado Outlet → ClickHouse
                           │
                           ▼
                  Akvorado Console
                  http://172.16.31.110:8081

Akvorado Outlet ──SNMPv2──> Cisco R1/R2
                  interface metadata
```

Luồng xử lý chính:

```text
ASR → Inlet → Kafka → Outlet → ClickHouse → Console
```

## 2. Thong tin server

| Hang muc | Gia tri |
|---|---|
| OS | Ubuntu 24.04.x LTS |
| Hostname | `netflow` |
| Timezone | `Asia/Ho_Chi_Minh` |
| IP quan tri / ung dung | `172.16.31.110/24` |
| Gateway | `172.16.31.254` |
| Public/NAT | Public IP NAT ve server noi bo |
| Domain Akvorado | `netflow.tpcloud.vn` |
| Domain Grafana | `traffic.tpcloud.vn` |
| Thu muc cai dat | `/opt/akvorado` |
| Data disk | `/data` |
| Filesystem data disk | XFS |
| Docker project | `akvorado` |

Kiem tra nhanh server:

```bash
hostnamectl
ip -br address
ip route
timedatectl
df -hT
free -h
nproc
```

## 3. Chuan bi OS

### 3.1 Cau hinh timezone va NTP

Timezone da duoc set ve Viet Nam:

```bash
timedatectl set-timezone Asia/Ho_Chi_Minh
```

Chrony duoc cai de dong bo thoi gian:

```bash
apt install -y chrony
systemctl restart chrony
systemctl enable chrony
```

File cau hinh chinh:

```text
/etc/chrony/chrony.conf
```

Noi dung quan trong da dung:

```conf
server 0.asia.pool.ntp.org iburst
rtcsync
makestep 1 3
```

### 3.2 Cau hinh network

Netplan ban dau duoc doi tu file cloud-init sang file rieng:

```bash
mv /etc/netplan/50-cloud-init.yaml /etc/netplan/netflow.yaml
netplan apply
```

Trong qua trinh van hanh co thoi diem file `/etc/netplan/50-cloud-init.yaml` duoc sua lai va apply. Can chot lai mot file netplan duy nhat de tranh nham lan ve sau.

Kiem tra:

```bash
ip -br address
ip route
ping 172.16.31.254
ping 8.8.8.8
ping google.com
```

Khuyen nghi van hanh:

- Chi giu mot file netplan active.
- Backup file truoc khi sua.
- Kiem tra DNS qua `/etc/resolv.conf` va `systemd-resolved`.

### 3.3 Chuan bi disk `/data`

Disk phu `/dev/sdb` duoc tao partition, format XFS va mount vao `/data`:

```bash
fdisk /dev/sdb
mkfs -t xfs /dev/sdb1
mkdir -p /data
echo "/dev/sdb1 /data xfs defaults 0 0" >> /etc/fstab
systemctl daemon-reload
mount -a
df -hT
```

Thu muc data da tao:

```bash
mkdir -p \
  /data/akvorado \
  /data/clickhouse \
  /data/kafka \
  /data/grafana \
  /data/backups
chmod 755 /data
```

Quyen cho ClickHouse va Kafka:

```bash
chown -R 101:101 /data/clickhouse
chmod 750 /data/clickhouse

chown -R 1000:1000 /data/kafka
chmod 750 /data/kafka
```

Kiem tra:

```bash
stat -c '%n owner=%u:%g mode=%a' /data/clickhouse /data/kafka
findmnt /data
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
grep -vE '^\s*(#|$)' /etc/fstab
```

## 4. Cai Docker Engine va Compose

Docker duoc cai tu repository chinh thuc cua Docker:

```bash
apt update
apt install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
systemctl enable --now containerd
```

Kiem tra Docker:

```bash
docker version
docker compose version
docker buildx version
systemctl is-enabled docker
systemctl is-active docker
systemctl is-active containerd
docker info | grep -E 'Storage Driver|Docker Root Dir|Logging Driver|Cgroup Driver|Cgroup Version'
ss -lntp | grep -E ':(2375|2376)\b' || echo "OK: Docker API is not exposed"
```

Docker daemon da duoc cau hinh file:

```text
/etc/docker/daemon.json
```

Luu y bao mat:

- Khong expose Docker API port `2375/2376`.
- Gioi han log Docker de tranh day disk.
- Kiem tra sau khi sua `daemon.json`:

```bash
python3 -m json.tool /etc/docker/daemon.json
systemctl restart docker
docker info --format 'LoggingDriver={{.LoggingDriver}}'
```

## 5. Cai Akvorado

### 5.1 Tai source docker compose quickstart

Version Akvorado da dung:

```text
v2.4.1
```

Lenh tai va giai nen:

```bash
mkdir -p /opt/akvorado
cd /opt/akvorado

curl -fL \
  https://github.com/akvorado/akvorado/releases/download/v2.4.1/docker-compose-quickstart.tar.gz \
  -o /tmp/akvorado-v2.4.1.tar.gz

tar -xzf /tmp/akvorado-v2.4.1.tar.gz -C /opt/akvorado
```

Kiem tra file:

```bash
cd /opt/akvorado
find . -maxdepth 3 -type f | sort
test -f .env && echo "OK: .env exists"
test -f docker/docker-compose.yml && echo "OK: Compose file exists"
```

### 5.2 Compose files quan trong

Thu muc chinh:

```text
/opt/akvorado/docker
```

`.env` thuc te dang dung:

```dotenv
COMPOSE_PROJECT_NAME=akvorado
COMPOSE_FILE=docker/docker-compose.yml:docker/docker-compose-ipinfo.yml:docker/docker-compose-prometheus.yml:docker/docker-compose-loki.yml:docker/docker-compose-grafana.yml:docker/docker-compose-demo.yml:docker/docker-compose-local.yml:docker/docker-compose-tls.yml:docker/docker-compose-cert.yml
COMPOSE_PROFILES=prometheus,loki,grafana,demo
TLS_DOMAIN=netflow.tpcloud.vn
TLS_EMAIL=webmaster@tpcloud.vn
```

Nhung file da dung trong qua trinh trien khai:

| File | Muc dich |
|---|---|
| `docker-compose.yml` | Stack chinh: Traefik, Akvorado components, ClickHouse, Kafka, Redis |
| `docker-compose-local.yml` | Override local: bind `/data`, bind port `8080/8081`, Basic Auth middleware |
| `docker-compose-ipinfo.yml` | GeoIP/IPinfo database |
| `docker-compose-prometheus.yml` | Prometheus |
| `docker-compose-loki.yml` | Loki |
| `docker-compose-grafana.yml` | Grafana |
| `docker-compose-tls.yml` | Them entrypoint HTTPS `publicsecure`, redirect HTTP sang HTTPS |
| `docker-compose-cert.yml` | Mount cert thu cong va Traefik dynamic provider |
| `versions.yml` | Version image |
| `.env` | Compose file/profile/TLS domain |

Kiem tra compose effective:

```bash
cd /opt/akvorado
docker compose config --services
docker compose config --quiet
docker compose config --images
docker compose config --volumes
```

Khi them/bot file compose trong `.env`, luon chay `docker compose config --quiet` truoc khi recreate container.

## 6. Data volume va service backend

### 6.1 Backend services

Services backend duoc start truoc:

```bash
cd /opt/akvorado
docker compose pull
docker compose up -d kafka clickhouse redis
docker compose ps kafka clickhouse redis
```

Kiem tra log:

```bash
docker compose logs --tail=100 kafka clickhouse redis
docker compose logs kafka clickhouse redis 2>&1 \
  | grep -iE 'error|fatal|exception|permission denied|read-only|no space' \
  | tail -100
```

Kiem tra ClickHouse:

```bash
docker inspect akvorado-clickhouse-1 \
  --format 'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}}'

docker compose exec clickhouse wget -qO- --timeout=3 http://127.0.0.1:8123/ping
```

### 6.2 Port backend

Backend port khong nen publish truc tiep ra host:

```bash
ss -lntup | grep -E ':(8123|9000|9004|9005|9009|9092|9093|6379)\b' \
  || echo "OK: Backend ports are not published on host"
```

## 7. Start Akvorado core services

Services da start:

```bash
cd /opt/akvorado
docker compose up -d \
  geoip \
  akvorado-orchestrator \
  akvorado-console \
  akvorado-inlet \
  akvorado-outlet
```

Kiem tra:

```bash
docker compose ps

docker compose logs --since=10m \
  geoip akvorado-orchestrator akvorado-console akvorado-inlet akvorado-outlet 2>&1 \
  | grep -iE 'error|fatal|panic|exception|permission denied|connection refused|timeout|failed' \
  | tail -150
```

Kiem tra restart count:

```bash
for container in \
  akvorado-geoip-1 \
  akvorado-akvorado-orchestrator-1 \
  akvorado-akvorado-console-1 \
  akvorado-akvorado-inlet-1 \
  akvorado-akvorado-outlet-1; do
  docker inspect "$container" \
    --format '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restart={{.RestartCount}}' \
    2>/dev/null || true
done
```

## 8. GeoIP/IPinfo

GeoIP duoc dung de phan loai Domestic/International dua tren country code.

Kiem tra file GeoIP trong container:

```bash
docker compose logs --tail=100 geoip

docker compose exec geoip sh -c '
  ls -lah /data
  test -s /data/country.mmdb && echo "OK: country.mmdb"
  test -s /data/asn.mmdb     && echo "OK: asn.mmdb"
'

docker compose exec akvorado-orchestrator sh -c '
  ls -lah /usr/share/GeoIP
  test -s /usr/share/GeoIP/country.mmdb && echo "OK: country.mmdb"
  test -s /usr/share/GeoIP/asn.mmdb     && echo "OK: asn.mmdb"
'
```

Restart orchestrator sau khi GeoIP san sang:

```bash
docker compose restart akvorado-orchestrator
docker compose logs --since=2m akvorado-orchestrator 2>&1 \
  | grep -iE 'geoip|database|error|fatal|panic|no such file' \
  || echo "OK: No GeoIP loading errors"
```

Luu y thuc te:

- Co truong hop IP CDN/AWS nhu `3.162.66.67` duoc GeoIP nhan country `VN`.
- Khi dashboard tach Domestic/International dua vao `SrcCountry/DstCountry`, ket qua phu thuoc database GeoIP.
- Neu can do chinh xac cao hon GeoIP, can bo sung logic dua tren BGP/community/interface/provider.

## 9. Cau hinh Akvorado `outlet.yaml`

File cau hinh quan trong:

```text
/opt/akvorado/config/outlet.yaml
```

Trong qua trinh lam da backup truoc khi sua:

```bash
cp -a /opt/akvorado/config/outlet.yaml \
  /opt/akvorado/config/outlet.yaml.bak-$(date +%Y%m%d-%H%M%S)
```

Cau hinh thuc te da chot, da sanitize SNMP community:

```yaml
---
metadata:
  providers:
    - type: snmp
      credentials:
        ::/0:
          communities: <REDACTED_SNMP_COMMUNITY>
routing:
  provider:
    type: bmp
    receive-buffer: 212992
core:
  default-sampling-rate: 1

  asn-providers:
    - flow-except-default-route
    - geo-ip

  exporter-classifiers:
    - ClassifySiteRegex(Exporter.Name, "^([^-]+)-", "$1")
    - ClassifyRegion("europe")
    - ClassifyTenant("acme")
    - ClassifyRole("edge")

  interface-classifiers:
    - |
      Exporter.Name == "rCoreTPC-01.tpcloud.vn" &&
      Interface.Name == "Gi0/0/5.1603" &&
      ClassifyConnectivity("ix") &&
      ClassifyProvider("NIX") &&
      ClassifyExternal()

    - |
      Exporter.Name == "rCoreTPC-01.tpcloud.vn" &&
      Interface.Name == "Gi0/0/5.1606" &&
      ClassifyConnectivity("ix") &&
      ClassifyProvider("NIX") &&
      ClassifyExternal()

    - |
      Exporter.Name == "rCoreTPC-01.tpcloud.vn" &&
      Interface.Name == "Gi0/0/4" &&
      ClassifyConnectivity("transit") &&
      ClassifyProvider("Viettel") &&
      ClassifyExternal()

    - |
      Exporter.Name == "rCoreTPC-01.tpcloud.vn" &&
      Interface.Name == "Gi0/0/2" &&
      ClassifyConnectivity("core") &&
      ClassifyProvider("TPCLOUD") &&
      ClassifyInternal()

    - |
      Exporter.Name == "rCoreTPC-01.tpcloud.vn" &&
      Interface.Name == "Po40.1605" &&
      ClassifyConnectivity("core") &&
      ClassifyProvider("TPCLOUD") &&
      ClassifyInternal()

    - |
      Exporter.Name == "rCoreTPC-02.tpcloud.vn" &&
      Interface.Name == "Po20.1604" &&
      ClassifyConnectivity("ix") &&
      ClassifyProvider("IXP") &&
      ClassifyExternal()

    - |
      Exporter.Name == "rCoreTPC-02.tpcloud.vn" &&
      Interface.Name == "Po20.1607" &&
      ClassifyConnectivity("ix") &&
      ClassifyProvider("IXP") &&
      ClassifyExternal()

    - |
      Exporter.Name == "rCoreTPC-02.tpcloud.vn" &&
      Interface.Name == "Gi0/0/2" &&
      ClassifyConnectivity("core") &&
      ClassifyProvider("TPCLOUD") &&
      ClassifyInternal()

    - |
      Exporter.Name == "rCoreTPC-02.tpcloud.vn" &&
      Interface.Name == "Po30.1605" &&
      ClassifyConnectivity("core") &&
      ClassifyProvider("TPCLOUD") &&
      ClassifyInternal()

    - |
      ClassifyConnectivityRegex(
        Interface.Description,
        "^(?i)(transit|pni|ppni|ix):? ",
        "$1"
      ) &&
      ClassifyProviderRegex(
        Interface.Description,
        "^\\S+?\\s(\\S+)",
        "$1"
      ) &&
      ClassifyExternal()

    - ClassifyInternal()
```

Ghi chu thiet ke:

- `default-sampling-rate: 1` vi Cisco ASR export full flow, khong sampling.
- `asn-providers` dung `flow-except-default-route` truoc, fallback `geo-ip`.
- Cac uplink NIX/IXP/Viettel duoc classify `External` de tinh inbound/outbound chuan hon.
- Link inter-router/core tam classify `Internal` theo cau hinh da chot.
- Rule regex theo `Interface.Description` de ve sau chi can dat description chuan: `transit`, `pni`, `ppni`, `ix`.
- Rule cuoi `ClassifyInternal()` gom cac interface con lai vao internal.

Kiem tra SNMP den router:

```bash
apt install -y snmp

read -rsp "SNMP community: " AKV_SNMP_COMMUNITY
echo

snmpget -v2c -c "$AKV_SNMP_COMMUNITY" -t 3 -r 1 \
  172.16.0.1 1.3.6.1.2.1.1.5.0

snmpwalk -v2c -c "$AKV_SNMP_COMMUNITY" -t 3 -r 1 \
  172.16.0.1 1.3.6.1.2.1.31.1.1.1.1 | head -20

unset AKV_SNMP_COMMUNITY
```

Validate syntax:

```bash
cd /opt/akvorado
docker compose config --quiet

docker compose run --rm --no-deps \
  akvorado-orchestrator \
  orchestrator --check --dump /etc/akvorado/akvorado.yaml \
  >/tmp/akvorado-config-dump.txt
```

Restart sau khi sua:

```bash
docker compose restart akvorado-orchestrator akvorado-outlet
docker compose ps akvorado-orchestrator akvorado-outlet
docker compose logs --since=3m --tail=200 akvorado-orchestrator akvorado-outlet
```

## 10. Kiem tra flow pipeline

### 10.1 Kiem tra UDP listener va packet NetFlow

Port NetFlow/sFlow/IPFIX da kiem tra:

```bash
ss -lunp | grep -E ':(2055|4739|6343)\b'
sudo ss -lunp | grep ':2055'
```

Bat packet NetFlow tu exporter:

```bash
tcpdump -ni any 'udp port 2055 and src host 172.16.0.1' -c 20
sudo tcpdump -ni any -nn -vv 'udp dst port 2055 and src host 172.16.0.1' -c 10
```

### 10.2 Kiem tra Inlet

Lay IP container Inlet:

```bash
INLET_CONTAINER="akvorado-akvorado-inlet-1"
INLET_IP=$(docker inspect \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "$INLET_CONTAINER")
echo "$INLET_IP"
```

Kiem tra metrics:

```bash
curl -s "http://${INLET_IP}:8080/api/v0/inlet/metrics" \
  | grep -E 'akvorado_inlet_flow_input_udp|akvorado_inlet_flow.*error|akvorado_inlet_flow.*drop'

curl -s "http://${INLET_IP}:8080/api/v0/inlet/metrics" \
  | grep 'akvorado_inlet_flow_input_udp_packets_total'
```

### 10.3 Kiem tra Outlet

```bash
OUTLET_CONTAINER="akvorado-akvorado-outlet-1"
OUTLET_IP=$(docker inspect \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "$OUTLET_CONTAINER")
echo "$OUTLET_IP"

curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep -Ei 'flow|kafka|clickhouse|decode|error|drop|insert'
```

Kiem tra pipeline:

```bash
echo "=== 1. INLET TO KAFKA ==="
curl -s "http://${INLET_IP}:8080/api/v0/inlet/metrics" \
  | grep 'akvorado_inlet_kafka_sent_messages'

echo "=== 2. OUTLET FROM KAFKA ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep 'akvorado_outlet_kafka_received_messages'

echo "=== 3. OUTLET DECODE/FORWARD ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep -E 'akvorado_outlet_core_(received|forwarded)'

echo "=== 4. NETFLOW RECORD TYPES ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep 'akvorado_outlet_flow_decoder_netflow_records'

echo "=== 5. DECODER ERRORS ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep 'akvorado_outlet_flow.*errors'

echo "=== 6. PROCESSING ERRORS ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep 'akvorado_outlet_core.*errors'

echo "=== 7. CLICKHOUSE INSERT ==="
curl -s "http://${OUTLET_IP}:8080/api/v0/outlet/metrics" \
  | grep -E 'akvorado_outlet_clickhouse_(errors|flow)'
```

### 10.4 Kiem tra data trong ClickHouse

```bash
docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT
    count() AS flows,
    min(TimeReceived) AS first_flow,
    max(TimeReceived) AS last_flow
FROM default.flows
FORMAT PrettyCompact
"
```

Kiem tra delay latest flow:

```bash
CH_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i clickhouse | head -n1)

docker exec -i "$CH_CONTAINER" clickhouse-client <<'SQL'
SELECT
    max(TimeReceived) AS latest_flow,
    now() AS clickhouse_time,
    dateDiff('second', latest_flow, clickhouse_time) AS delay_seconds
FROM default.flows;
SQL
```

## 11. ClickHouse

### 11.1 Database va table

Kiem tra database/table:

```bash
docker exec akvorado-clickhouse-1 clickhouse-client \
  --query "SHOW DATABASES FORMAT PrettyCompact"

docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT database, name, engine
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, name
FORMAT PrettyCompact
"
```

Kiem tra dung luong table:

```bash
docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT
    database,
    table,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
  AND positionCaseInsensitive(table, 'flow') > 0
GROUP BY database, table
ORDER BY database, table
FORMAT PrettyCompact
"
```

### 11.2 Retention/TTL dang ap dung

Theo cau hinh da chot trong qua trinh lam:

| Bang | Do phan giai | Retention |
|---|---:|---:|
| `flows` | raw | 15 ngay |
| `flows_1m0s` | 1 phut | 7 ngay |
| `flows_5m0s` | 5 phut | 90 ngay |
| `flows_1h0m0s` | 1 gio | 360 ngay |

Luu y:

- Dashboard realtime nen dung bang chi tiet/1m.
- Dashboard dai ngay nen dung `flows_5m0s` hoac `flows_1h0m0s`.
- Neu xem `Last 30 days` ma panel van query bang 1m/raw thi chart se kho nhin va query nang.

Kiem tra TTL thuc te:

```bash
docker exec akvorado-clickhouse-1 clickhouse-client --query "
SHOW CREATE TABLE default.flows
FORMAT TSVRaw
"
```

## 12. Kafka

Kafka dung lam buffer giua Inlet va Outlet.

Theo cau hinh da chot:

| Thong so | Gia tri |
|---|---|
| Topic | `flows` |
| Partitions | `8` |
| Retention | `86400000 ms` = 1 ngay |

Kiem tra dung luong Kafka:

```bash
du -sh /data/kafka
docker compose ps kafka
docker compose logs --tail=100 kafka
```

Muc tieu retention 1 ngay de tranh Kafka tang dung luong qua nhanh.

## 13. Grafana

### 13.1 Cai Grafana va Prometheus

Grafana duoc chay tu compose profile:

```bash
cd /opt/akvorado/docker

docker compose \
  -f docker-compose.yml \
  -f docker-compose-prometheus.yml \
  -f docker-compose-grafana.yml \
  --profile prometheus \
  --profile grafana \
  up -d prometheus grafana
```

Kiem tra:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose-prometheus.yml \
  -f docker-compose-grafana.yml \
  --profile prometheus \
  --profile grafana \
  ps prometheus grafana

docker logs --tail 100 akvorado-grafana-1
```

Version trong history:

```text
grafana/grafana-oss:10.4.19
prom/prometheus:v3.12.0
```

### 13.2 ClickHouse datasource

Plugin ClickHouse duoc cai vao Grafana:

```bash
docker exec -u 0 akvorado-grafana-1 \
  grafana-cli plugins install grafana-clickhouse-datasource

docker restart akvorado-grafana-1

docker exec akvorado-grafana-1 \
  grafana-cli plugins ls | grep -i clickhouse
```

Tao user read-only trong ClickHouse cho Grafana:

```bash
read -rsp "Nhap password cho grafana_ro: " GRAFANA_RO_PASSWORD
echo

GRAFANA_RO_HASH="$(
  printf '%s' "$GRAFANA_RO_PASSWORD" |
  sha256sum |
  awk '{print $1}'
)"

printf '%s\n' \
  "CREATE USER IF NOT EXISTS grafana_ro IDENTIFIED WITH sha256_hash BY '$GRAFANA_RO_HASH';" \
  "GRANT SELECT ON default.flows TO grafana_ro;" \
  "ALTER USER grafana_ro SETTINGS readonly = 1;" \
| docker exec -i akvorado-clickhouse-1 clickhouse-client --multiquery

unset GRAFANA_RO_HASH
```

Sau do da dieu chinh:

```sql
ALTER USER grafana_ro SETTINGS readonly = 2;
```

File datasource:

```text
/opt/akvorado/docker/grafana/provisioning/datasources/clickhouse.yaml
```

Noi dung thuc te da chot, da redact password:

```yaml
---
apiVersion: 1
datasources:
  - name: Akvorado ClickHouse
    uid: akvorado-clickhouse
    type: grafana-clickhouse-datasource
    access: proxy
    editable: false
    jsonData:
      host: clickhouse
      port: 9000
      protocol: native
      username: grafana_ro
      defaultDatabase: default
      secure: false
      tlsSkipVerify: false
    secureJsonData:
      password: |-
        <REDACTED>
```

Ghi chu van hanh:

- Grafana ket noi ClickHouse bang protocol `native` qua port `9000` trong Docker network.
- User `grafana_ro` chi dung cho dashboard/query read-only.
- Khong public port ClickHouse `9000/8123` ra host/public network.
- Password trong file datasource phai duoc bao ve bang file mode chat.

Quyen file datasource:

```bash
chown 472:0 grafana/provisioning/datasources/clickhouse.yaml
chmod 600 grafana/provisioning/datasources/clickhouse.yaml
```

Kiem tra:

```bash
docker restart akvorado-grafana-1
docker logs --since 1m akvorado-grafana-1 2>&1 \
  | grep -iE 'datasource|permission denied|failed to provision|clickhouse'
```

### 13.3 User Grafana

Account `alfred` da duoc nang role len `Editor` trong Org ID `1`.

Do thoi diem do can update truc tiep SQLite, da backup DB truoc:

```bash
docker stop akvorado-grafana-1

GRAFANA_DB="$(docker inspect akvorado-grafana-1 \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Source}}{{end}}{{end}}')/grafana.db"

cp -a "$GRAFANA_DB" "${GRAFANA_DB}.bak.$(date +%Y%m%d-%H%M%S)"
```

Update role:

```python
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)

user = conn.execute(
    "SELECT id, login FROM user WHERE login = ?",
    ("alfred",)
).fetchone()

if not user:
    raise SystemExit("ERROR: Khong tim thay account alfred")

conn.execute(
    "UPDATE org_user SET role = 'Editor' WHERE user_id = ?",
    (user[0],)
)
conn.commit()
conn.close()
```

Kiem tra:

```bash
python3 - "$GRAFANA_DB" <<'PY'
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)

row = conn.execute("""
    SELECT u.login, ou.org_id, ou.role
    FROM user AS u
    JOIN org_user AS ou ON ou.user_id = u.id
    WHERE lower(u.login) = lower(?)
      AND ou.org_id = 1
""", ("alfred",)).fetchone()

if not row:
    raise SystemExit("ERROR: Khong tim thay membership cua alfred")

print(f"Account={row[0]}, Org ID={row[1]}, Role={row[2]}")
conn.close()
PY
```

## 14. Customer mapping

Da tao mapping IP customer de dashboard query theo customer/group.

File mapping:

```text
/opt/akvorado/customer-mapping/customer_ip_map.csv
```

Script dong bo:

```text
/opt/akvorado/customer-mapping/sync-customer-map.sh
```

Quyen script:

```bash
chmod 750 /opt/akvorado/customer-mapping/sync-customer-map.sh
```

Thong tin da ghi nhan:

- File CSV co format:

```csv
customer_name,customer_ip,description,enabled
```

- `enabled=1`: IP dang duoc tinh vao mapping customer.
- `enabled=0`: IP chua su dung hoac tam thoi khong map vao customer.
- Khi query tren ClickHouse, IP IPv4 co the duoc luu dang IPv6-mapped `::ffff:x.x.x.x`; dashboard can format lai de an prefix `::ffff:`.

Trich doan mapping thuc te tu file hien tai:

| customer_name | customer_ip | enabled |
|---|---:|---:|
| `SOPHOS_VPN` | `103.141.177.4` | 1 |
| `T0-DELL` | `103.141.177.5` | 1 |
|  | `103.141.177.6` | 0 |
|  | `103.141.177.7` | 0 |
| `ORG-CA` | `103.141.177.8` | 1 |
|  | `103.141.177.9` | 0 |
| `T0-HPEG10` | `103.141.177.10` | 1 |
| `T0-DELL` | `103.141.177.11` | 1 |
| `ORG-DATX` | `103.141.177.12` | 1 |
| `ORG-ECARAID` | `103.141.177.13` | 1 |
| `ORG-ECARAID` | `103.141.177.14` | 1 |
| `ORG-ECARAID` | `103.141.177.15` | 1 |
| `ORG-ECARAID` | `103.141.177.16` | 1 |
| `ORG-LUAN` | `103.141.177.17` | 1 |
| `ORG-TPCOMS` | `103.141.177.18` | 1 |
| `FFTECH` | `103.141.177.19` | 1 |
| `ORG-ECARAID` | `103.141.177.20` | 1 |
| `ORG-ACEFOODS` | `103.141.177.21` | 1 |
| `ORG-ILOTUSLAND` | `103.141.177.22` | 1 |
| `ORG-ILOTUSLAND` | `103.141.177.23` | 1 |
| `ORG-ACEFOODS` | `103.141.177.24` | 1 |
| `ORG-ECARAID` | `103.141.177.25` | 1 |
| `ORG-ECARAID` | `103.141.177.26` | 1 |
| `ORG-DATX` | `103.141.177.27` | 1 |
|  | `103.141.177.28` | 0 |
| `ORG-TVQ` | `103.141.177.29` | 1 |

Lenh xem mapping:

```bash
sed -n '1,260p' /opt/akvorado/customer-mapping/customer_ip_map.csv
```

Sau khi sua CSV, dong bo vao ClickHouse:

```bash
/opt/akvorado/customer-mapping/sync-customer-map.sh
```

## 15. Dashboard va query

### 15.1 Dashboard da tao

Dashboard chinh:

```text
DOMESTIC & INTL TRAFFIC
```

Muc dich:

- Xem bang thong theo customer.
- Tach Upload/Download.
- Tach Domestic/International.
- Don vi hien thi: Kbps/Mbps tuy panel.

### 15.2 Logic tinh bang thong

Cong thuc co ban:

```sql
sum(Bytes * SamplingRate) * 8 / seconds
```

Trong do:

- `Bytes`: so byte cua flow.
- `SamplingRate`: he so sampling cua exporter.
- `* 8`: doi byte sang bit.
- `/ seconds`: doi sang bps.
- `/ 1000` hoac `/ 1000000`: doi sang Kbps/Mbps.

Upload/Download:

- Neu `SrcAddr` thuoc IP customer => Upload.
- Neu `DstAddr` thuoc IP customer => Download.

Domestic/International:

- Upload: xet `DstCountry`.
- Download: xet `SrcCountry`.
- Country `VN` => Domestic.
- Khac `VN` => International.

### 15.3 Query mau theo IP customer

```sql
WITH
    [
        toIPv6('::ffff:103.141.177.22'),
        toIPv6('::ffff:103.141.177.23')
    ] AS customer_ips
SELECT
    if(has(customer_ips, SrcAddr), toString(SrcAddr), toString(DstAddr)) AS customer_ip,
    if(has(customer_ips, SrcAddr), 'Upload', 'Download') AS direction,
    if(
        if(has(customer_ips, SrcAddr), DstCountry, SrcCountry) = 'VN',
        'Domestic',
        'International'
    ) AS traffic_type,
    formatReadableSize(sum(Bytes * SamplingRate)) AS traffic,
    round(sum(Bytes * SamplingRate) * 8 / 3600, 2) AS avg_bps,
    count() AS flows
FROM default.flows
WHERE TimeReceived >= now() - INTERVAL 1 HOUR
  AND (
      has(customer_ips, SrcAddr)
      OR has(customer_ips, DstAddr)
  )
GROUP BY
    customer_ip,
    direction,
    traffic_type
ORDER BY
    customer_ip,
    direction,
    traffic_type
FORMAT PrettyCompact
```

### 15.4 Query cho dashboard dai ngay

Khi xem `Last 30 days`, khong nen dung raw/1m qua chi tiet. Nen dung bang aggregate theo gio:

```sql
SELECT
  toStartOfHour(TimeReceived) AS time,
  round(sum(Bytes * SamplingRate) * 8 / 3600 / 1000000, 2) AS mbps
FROM default.flows_1h0m0s
WHERE
  $__timeFilter(TimeReceived)
  AND customer_name = 'ORG-DTU'
GROUP BY time
ORDER BY time
```

Khuyen nghi table theo time range:

| Time range | Table nen dung | Bucket |
|---|---|---|
| 5m - 6h | `flows` hoac `flows_1m0s` | 1m |
| 24h - 7d | `flows_1m0s` hoac `flows_5m0s` | 5m/15m |
| 7d - 90d | `flows_1h0m0s` | 1h |
| >90d | `flows_1h0m0s` | 1d |

Khuyen nghi tao dashboard rieng:

```text
CUSTOMER TRAFFIC TREND
```

Dashboard nay dung `flows_1h0m0s`, group theo gio/ngay de xem trend dai ngay.

## 16. Traefik, domain, HTTPS 443 va Basic Auth

### 16.1 Logic domain cung IP

Hai domain:

```text
traffic.tpcloud.vn
netflow.tpcloud.vn
```

co the cung tro ve mot public IP va NAT ve cung server. NAT chi xu ly IP/port. Traefik phan biet website bang:

- TLS SNI.
- HTTP `Host` header.
- Router rule `Host(...)` hoac `PathPrefix(...)`.

Flow:

```text
Client -> DNS -> Public IP -> NAT TCP/80,443 -> 172.16.31.110 -> Traefik -> service backend
```

### 16.2 Compose/TLS dang dung

`.env` dang include ca TLS redirect va cert thu cong:

```dotenv
COMPOSE_FILE=docker/docker-compose.yml:docker/docker-compose-ipinfo.yml:docker/docker-compose-prometheus.yml:docker/docker-compose-loki.yml:docker/docker-compose-grafana.yml:docker/docker-compose-demo.yml:docker/docker-compose-local.yml:docker/docker-compose-tls.yml:docker/docker-compose-cert.yml
TLS_DOMAIN=netflow.tpcloud.vn
TLS_EMAIL=webmaster@tpcloud.vn
```

`docker-compose-tls.yml` tao entrypoint HTTPS `publicsecure` va redirect HTTP sang HTTPS. Kiem tra:

```bash
cd /opt/akvorado
sed -n '1,220p' docker/docker-compose-tls.yml

docker compose config | grep -A3 'TRAEFIK_ENTRYPOINTS_public_HTTP_REDIRECTIONS'
docker compose exec traefik env | grep '^TRAEFIK_ENTRYPOINTS_public_HTTP_REDIRECTIONS'
```

`docker-compose-cert.yml` mount certificate va dynamic provider:

```yaml
services:
  traefik:
    environment:
      TRAEFIK_PROVIDERS_FILE_DIRECTORY: /etc/traefik/dynamic
      TRAEFIK_PROVIDERS_FILE_WATCH: "true"
      TRAEFIK_ENTRYPOINTS_publicsecure_HTTP_MIDDLEWARES: "compress@docker"
    volumes:
      - /opt/akvorado/certs:/etc/traefik/certs:ro
      - /opt/akvorado/traefik-dynamic:/etc/traefik/dynamic:ro
```

Luu y: comment cu trong file ghi Basic Auth cho toan bo HTTPS, nhung gia tri cuoi da chot chi con `compress@docker`. Auth khong dat global tren entrypoint nua.

### 16.3 Cert thu cong

Thu muc cert:

```text
/opt/akvorado/certs
```

File da tao/copy vao:

```text
/opt/akvorado/certs/fullchain.pem
/opt/akvorado/certs/private.pem
```

Phan quyen da ap dung:

```bash
chmod 700 /opt/akvorado/certs
chown root:root \
  /opt/akvorado/certs/fullchain.pem \
  /opt/akvorado/certs/private.pem
chmod 644 /opt/akvorado/certs/fullchain.pem
chmod 600 /opt/akvorado/certs/private.pem
ls -lh /opt/akvorado/certs/
```

Dynamic TLS config:

```text
/opt/akvorado/traefik-dynamic/tls.yml
```

Kiem tra file provider va cert da vao container:

```bash
cd /opt/akvorado

docker compose config --quiet
docker compose config | grep -A20 -E 'traefik:|/etc/traefik/(certs|dynamic)'
docker compose exec traefik ls -l /etc/traefik/certs /etc/traefik/dynamic
```

Noi dung `tls.yml` thuc te:

```yaml
tls:
  certificates:
    - certFile: /etc/traefik/certs/fullchain.pem
      keyFile: /etc/traefik/certs/private.pem

  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/fullchain.pem
        keyFile: /etc/traefik/certs/private.pem
```

Voi cau hinh nay, Traefik load cert tu file provider va dung cert nay lam default certificate. Neu cert wildcard hoac SAN gom ca `traffic.tpcloud.vn` va `netflow.tpcloud.vn`, Traefik co the dung cung cert cho ca hai router HTTPS.

### 16.4 Port Traefik

Base compose:

```yaml
TRAEFIK_ENTRYPOINTS_private_ADDRESS: ":8080"
TRAEFIK_ENTRYPOINTS_public_ADDRESS: ":8081"
```

Override local dang dung:

```yaml
services:
  traefik:
    ports: !override
      - "127.0.0.1:8080:8080/tcp"
      - "172.16.31.110:8081:8081/tcp"
    environment:
      TRAEFIK_ENTRYPOINTS_public_HTTP_MIDDLEWARES: "compress@docker"
    labels:
      - "traefik.http.middlewares.auth.basicauth.users=akvorado:<REDACTED_BCRYPT_HASH>"
```

Khi include `docker-compose-tls.yml`, can kiem tra them port `80/443` va entrypoint `publicsecure` trong effective config:

```bash
sudo ss -lntp | grep -E ':(80|443|8080|8081)\b'
docker compose config | grep -nE 'traefik|Host\(|PathPrefix|entrypoints|certresolver|tls|8080|8081|80|443'
```

Neu firewall/NAT public dang forward TCP/80 va TCP/443 vao server, nguoi dung se truy cap qua domain HTTPS chuan. Port `8081` chi la entrypoint public noi bo cua Traefik trong compose/base path va khong nen public truc tiep neu da chot dung 443.

### 16.5 Router va Basic Auth

Ban dau Basic Auth duoc gan o entrypoint public/publicsecure, nen `traffic.tpcloud.vn` cung bi browser popup Basic Auth.

Huong da chot:

- Bo `auth@docker` khoi entrypoint chung `public` va `publicsecure`.
- Gan `auth@docker` rieng vao cac router quan tri.
- Grafana domain `traffic.tpcloud.vn` khong gan Basic Auth, de user vao man login Grafana.
- Akvorado Console `netflow.tpcloud.vn` va `/traefik` van co Basic Auth.

Trang thai cuoi da validate:

```text
TRAEFIK_ENTRYPOINTS_public_HTTP_MIDDLEWARES: compress@docker
TRAEFIK_ENTRYPOINTS_publicsecure_HTTP_MIDDLEWARES: compress@docker
traefik.http.routers.grafana.rule: Host(`traffic.tpcloud.vn`)
traefik.http.routers.traefik.middlewares: auth@docker
traefik.http.routers.traefik-metrics.middlewares: auth@docker
traefik.http.routers.akvorado-console.middlewares: auth@docker
```

Kiem tra effective config:

```bash
cd /opt/akvorado

docker compose config |
grep -E 'ENTRYPOINTS_public.*MIDDLEWARES|traefik.http.routers.(grafana|akvorado-console|traefik|traefik-metrics).(rule|middlewares):' |
sort
```

Neu `netflow.tpcloud.vn` mat popup sau khi bo auth global, them vao labels cua service `akvorado-console`:

```yaml
- traefik.http.routers.akvorado-console.middlewares=auth@docker
```

Neu `/traefik` can bao ve, them vao labels cua service `traefik`:

```yaml
- traefik.http.routers.traefik.middlewares=auth@docker
- traefik.http.routers.traefik-metrics.middlewares=auth@docker
```

### 16.6 Grafana public domain

Grafana router cuoi cung phai match rieng domain:

```text
traefik.http.routers.grafana.rule: Host(`traffic.tpcloud.vn`)
```

Khong de Grafana gan cac middleware sau neu muc tieu la vao thang login Grafana:

```text
auth@docker
console-auth
grafana-avatar
```

Cac lenh da dung de troubleshoot Grafana login:

```bash
docker compose exec grafana env | grep -E '^GF_AUTH_PROXY_|^GF_AUTH_BASIC_|^GF_SECURITY_ADMIN_'
docker inspect "$(docker compose ps -q grafana)" \
  --format '{{range $key, $value := .Config.Labels}}{{println $key "=" $value}}{{end}}' \
  | grep -iE 'router|middleware|console-auth|Remote-User'
docker compose logs --since=5m grafana | grep -iE 'login|auth|invalid|failed|user'
```

Co thoi diem reset password admin Grafana bang CLI:

```bash
docker compose exec grafana grafana cli admin reset-admin-password '<REDACTED_NEW_PASSWORD>'
```

Sau khi sua label Grafana:

```bash
docker compose config --quiet
docker compose up -d --no-deps --force-recreate grafana
```

### 16.7 Recreate sau khi sua Traefik/Grafana

```bash
cd /opt/akvorado
docker compose config --quiet
docker compose up -d --no-deps --force-recreate traefik grafana
```

Neu sua Akvorado Console auth:

```bash
docker compose up -d --no-deps --force-recreate traefik akvorado-console
```

### 16.8 Test domain

Ket qua cuoi cung da dat:

```bash
curl -Ik http://traffic.tpcloud.vn/
curl -Ik https://traffic.tpcloud.vn/
curl -Ik https://netflow.tpcloud.vn/traefik
curl -Ik https://netflow.tpcloud.vn/
```

Ky vong:

| URL | Ket qua dung |
|---|---|
| `http://traffic.tpcloud.vn/` | `308 Permanent Redirect` sang HTTPS |
| `https://traffic.tpcloud.vn/` | `302 location: /login`, khong co `www-authenticate: Basic` |
| `https://netflow.tpcloud.vn/` | Co `www-authenticate: Basic` |
| `https://netflow.tpcloud.vn/traefik` | Co `www-authenticate: Basic realm="traefik"` |

Ket qua test da ghi nhan:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://traffic.tpcloud.vn/

HTTP/2 302
location: /login

HTTP/2 401
www-authenticate: Basic realm="traefik"
```

## 17. Firewall/NAT/port can mo

Khong bao gom cau hinh router Cisco, nhung server can dam bao cac port sau:

| Huong | Port | Muc dich |
|---|---:|---|
| Router -> server | UDP 2055 | NetFlow |
| Router -> server | UDP 4739 | IPFIX neu dung |
| Router -> server | UDP 6343 | sFlow neu dung |
| Client -> public/NAT | TCP 443 | HTTPS Traefik, domain `traffic.tpcloud.vn` va `netflow.tpcloud.vn` |
| Client -> public/NAT | TCP 80 | HTTP redirect sang HTTPS |
| Internal/admin | TCP 8080 | Traefik private, bind `127.0.0.1` |
| Internal/public entry | TCP 8081 | Traefik public entrypoint noi bo, bind `172.16.31.110` |

Kiem tra listener:

```bash
ss -lntup | grep -E ':(2055|4739|6343|8080|8081|80|443)\b'
ufw status verbose
nft list ruleset | head -150
```

Security baseline:

- Public NAT chi can TCP/80 va TCP/443 neu da chot dung HTTPS chuan.
- Khong public truc tiep TCP/8080, TCP/8081 neu khong co nhu cau quan tri noi bo ro rang.
- Khong public ClickHouse/Kafka/Redis.
- Khong public Docker API.
- Traefik dashboard, Akvorado Console, metrics phai co auth.
- Grafana public domain khong dung Basic Auth, nhung van phai bat login Grafana.
- File datasource/cert private key co password/key phai mode chat: datasource `600`, `private.pem` `600`.

## 18. Van hanh hang ngay

### 18.1 Health check nhanh

```bash
cd /opt/akvorado

docker compose ps
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

docker compose logs --since=10m 2>&1 \
  | grep -iE 'error|fatal|panic|permission denied|connection refused|no space|read-only' \
  | tail -100
```

### 18.2 Disk usage

```bash
df -hT
du -sh /data/*
du -sh /data/clickhouse /data/kafka
docker system df
```

Neu nghi co file da xoa nhung process con giu:

```bash
lsof +L1
```

### 18.3 ClickHouse data freshness

```bash
CH_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i clickhouse | head -n1)

docker exec -i "$CH_CONTAINER" clickhouse-client <<'SQL'
SELECT
    max(TimeReceived) AS latest_flow,
    now() AS clickhouse_time,
    dateDiff('second', latest_flow, clickhouse_time) AS delay_seconds
FROM default.flows;
SQL
```

### 18.4 Kiem tra traffic theo country

```bash
docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT
    if(empty(DstCountry), 'EMPTY', DstCountry) AS country,
    count() AS flows,
    formatReadableSize(sum(Bytes * SamplingRate)) AS traffic
FROM default.flows
WHERE TimeReceived >= now() - INTERVAL 1 HOUR
GROUP BY country
ORDER BY sum(Bytes * SamplingRate) DESC
LIMIT 20
FORMAT PrettyCompact
"
```

### 18.5 Kiem tra SamplingRate

```bash
docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT
    SamplingRate,
    count() AS flows
FROM default.flows
WHERE TimeReceived >= now() - INTERVAL 1 HOUR
GROUP BY SamplingRate
ORDER BY flows DESC
FORMAT PrettyCompact
"
```

## 19. Loi da gap va cach xu ly

### 19.1 Basic Auth bi ap vao Grafana

Trieu chung:

- Vao `https://traffic.tpcloud.vn/` bi browser popup Basic Auth.

Nguyen nhan:

- `auth@docker` gan o Traefik entrypoint chung.

Fix:

- Sua `TRAEFIK_ENTRYPOINTS_public_HTTP_MIDDLEWARES` va `TRAEFIK_ENTRYPOINTS_publicsecure_HTTP_MIDDLEWARES` chi con `compress@docker`.
- Gan `auth@docker` truc tiep vao router quan tri: `akvorado-console`, `traefik`, `traefik-metrics`, metrics routers.

Validate:

```bash
docker compose config |
grep -E 'ENTRYPOINTS_public.*MIDDLEWARES|traefik.http.routers.(grafana|akvorado-console|traefik|traefik-metrics).(rule|middlewares):' |
sort
```

### 19.2 `netflow.tpcloud.vn` mat popup Basic Auth

Trieu chung:

- Sau khi bo auth khoi entrypoint, Akvorado Console khong con popup auth.

Nguyen nhan:

- Router `akvorado-console` chua gan middleware auth truc tiep.

Fix:

```yaml
- traefik.http.routers.akvorado-console.middlewares=auth@docker
```

Recreate:

```bash
docker compose up -d --no-deps --force-recreate traefik akvorado-console
```

### 19.3 Grafana provisioning dashboard loi title empty

Log:

```text
failed to load dashboard ... troubleshooting.json error="Dashboard title cannot be empty"
```

Tac dong:

- Grafana van chay.
- Loi lien quan dashboard JSON provisioning bi thieu title.

Huong xu ly:

- Sua/xoa dashboard JSON loi.
- Hoac quan ly dashboard truc tiep trong Grafana UI neu khong can provisioning dashboard do.

### 19.4 Grafana datasource permission denied

Nguyen nhan:

- File datasource `clickhouse.yaml` quyen/owner khong phu hop voi user Grafana.

Fix:

```bash
chown 472:0 grafana/provisioning/datasources/clickhouse.yaml
chmod 600 grafana/provisioning/datasources/clickhouse.yaml
docker restart akvorado-grafana-1
```

### 19.5 Query Grafana theo 30 ngay kho nhin

Nguyen nhan:

- Query qua chi tiet hoac dung bang raw/1m cho long range.
- Spike lon keo truc Y, traffic binh thuong bi ep sat day.

Fix:

- Tao dashboard trend rieng.
- Dung `flows_1h0m0s` cho 7d-90d.
- Group theo `toStartOfHour()` hoac `toStartOfDay()`.
- Tach panel Average va Peak neu can.

### 19.6 GeoIP co the lam sai Domestic/International

Vi du:

- IP CDN/AWS `3.162.66.67` co the hien country `VN`.

Giai thich:

- Akvorado/Grafana dang phan loai theo GeoIP country, khong phai theo duong routing thuc te.

Huong nang cap:

- Them classifier dua theo interface/provider.
- Ket hop BGP/ASN/community.
- Xay bang override IP/prefix neu can chot Domestic/International theo chinh sach noi bo.

## 20. Backup can co

Nen backup cac duong dan sau:

```text
/opt/akvorado/.env
/opt/akvorado/docker/
/opt/akvorado/config/
/opt/akvorado/customer-mapping/
/opt/akvorado/certs/
/opt/akvorado/traefik-dynamic/
/data/grafana/
```

ClickHouse va Kafka:

- `/data/clickhouse`: data chinh, dung luong lon.
- `/data/kafka`: buffer, co the khong can backup dai han neu ClickHouse da nhan flow.

Khuyen nghi:

- Backup config hang ngay.
- Backup Grafana DB/dashboard sau moi dot sua lon.
- Backup ClickHouse theo chinh sach rieng neu can truy van lich su.
- Khong backup plaintext password ra noi khong ma hoa.

## 21. Checklist sau trien khai

### OS/Docker

- [ ] Hostname dung: `netflow`.
- [ ] Timezone dung: `Asia/Ho_Chi_Minh`.
- [ ] Chrony active.
- [ ] `/data` mount XFS thanh cong.
- [ ] Docker active.
- [ ] Docker API khong expose.
- [ ] Docker log rotation da cau hinh.

### Akvorado

- [ ] `kafka`, `clickhouse`, `redis` running.
- [ ] `geoip`, `akvorado-orchestrator`, `akvorado-console`, `akvorado-inlet`, `akvorado-outlet` running.
- [ ] GeoIP co `country.mmdb` va `asn.mmdb`.
- [ ] Inlet nhan UDP packet.
- [ ] Inlet day message sang Kafka.
- [ ] Outlet doc Kafka va insert ClickHouse.
- [ ] `default.flows` co data moi.
- [ ] `delay_seconds` cua latest flow nam trong nguong chap nhan.

### Grafana

- [ ] Grafana container running.
- [ ] ClickHouse plugin installed.
- [ ] Datasource `Akvorado ClickHouse` OK.
- [ ] User `grafana_ro` chi co quyen SELECT/readonly.
- [ ] User `alfred` role Editor neu can sua dashboard.
- [ ] Dashboard Domestic/International hien data.
- [ ] Dashboard dai ngay dung table aggregate.

### Traefik/Security

- [ ] `traffic.tpcloud.vn` vao Grafana login, khong Basic Auth popup.
- [ ] `netflow.tpcloud.vn` co Basic Auth.
- [ ] `/traefik` co Basic Auth.
- [ ] Metrics/admin routes khong public unauthenticated.
- [ ] Backend ClickHouse/Kafka/Redis khong expose ra host/public.
- [ ] TLS certificate hoat dong.

## 22. Thong tin da bo sung tu cac file config cuoi

Anh da bo sung cac file quan trong sau va tai lieu nay da cap nhat theo cac file do:

| File | Trang thai trong tai lieu |
|---|---|
| `/opt/akvorado/traefik-dynamic/tls.yml` | Da dua noi dung thuc te vao muc HTTPS/cert |
| `/opt/akvorado/docker/grafana/provisioning/datasources/clickhouse.yaml` | Da dua datasource ClickHouse vao muc Grafana, password da redact |
| `/opt/akvorado/customer-mapping/customer_ip_map.csv` | Da dua mapping hien co vao muc customer mapping |

Neu can nang tai lieu len muc clone/restore gan nhu 1:1, thong tin con co the bo sung them ve sau:

```bash
docker compose config |
grep -E 'TRAEFIK_|traefik.http.routers|traefik.http.middlewares|traefik.http.services' |
sort

docker exec akvorado-clickhouse-1 clickhouse-client --query "
SELECT database, table, engine, rows, formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE active AND database = 'default'
ORDER BY table
FORMAT PrettyCompact
"
```

Hai output nay dung de chot them:

- Traefik router/middleware exact sau khi compose merge.
- Dung luong/partition ClickHouse hien tai de dua vao baseline van hanh.
