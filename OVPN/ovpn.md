# HƯỚNG DẪN CÀI OPEN VPN

cần DNAT port UDP 1194 từ ngoài vào server open vpn

# Cập nhật hệ thống

```
apt -y update && apt -y upgrade
```
# Tải và cài đặt OpenVPN từ Script

```
wget https://raw.githubusercontent.com/tanlai39/LINUX/main/ubuntu-22.04-lts-vpn-server.sh
```

cấp quyền thực thi

```
chmod +x ubuntu-22.04-lts-vpn-server.sh
```

chạy script

```
./ubuntu-22.04-lts-vpn-server.sh
```

```
root@OPENVPN:~# ./ubuntu-22.04-lts-vpn-server.sh
Welcome to the OpenVPN installer!
The git repository is available at: https://github.com/angristan/openvpn-install

I need to ask you a few questions before starting the setup.
You can leave the default options and just press enter if you are okay with them.

I need to know the IPv4 address of the network interface you want OpenVPN listening to.
Unless your server is behind NAT, it should be your public IPv4 address.
IP address: 172.22.22.100

It seems this server is behind NAT. What is its public IPv4 address or hostname?
We need it for the clients to connect to the server.
Public IPv4 address or hostname: 61.14.236.211

Checking for IPv6 connectivity...

Your host does not appear to have IPv6 connectivity.

Do you want to enable IPv6 support (NAT)? [y/n]: n

What port do you want OpenVPN to listen to?
   1) Default: 1194
   2) Custom
   3) Random [49152-65535]
Port choice [1-3]: 1

What protocol do you want OpenVPN to use?
UDP is faster. Unless it is not available, you shouldn't use TCP.
   1) UDP
   2) TCP
Protocol [1-2]: 1

What DNS resolvers do you want to use with the VPN?
   1) Current system resolvers (from /etc/resolv.conf)
   2) Self-hosted DNS Resolver (Unbound)
   3) Cloudflare (Anycast: worldwide)
   4) Quad9 (Anycast: worldwide)
   5) Quad9 uncensored (Anycast: worldwide)
   6) FDN (France)
   7) DNS.WATCH (Germany)
   8) OpenDNS (Anycast: worldwide)
   9) Google (Anycast: worldwide)
   10) Yandex Basic (Russia)
   11) AdGuard DNS (Anycast: worldwide)
   12) NextDNS (Anycast: worldwide)
   13) Custom
DNS [1-12]: 9

Do you want to use compression? It is not recommended since the VORACLE attack makes use of it.
Enable compression? [y/n]: n

Do you want to customize encryption settings?
Unless you know what you're doing, you should stick with the default parameters provided by the script.
Note that whatever you choose, all the choices presented in the script are safe (unlike OpenVPN's defaults).
See https://github.com/angristan/openvpn-install#security-and-encryption to learn more.

Customize encryption settings? [y/n]: n

Okay, that was all I needed. We are ready to setup your OpenVPN server now.
You will be able to generate a client at the end of the installation.
Press any key to continue...

```

Nhập tên client. có tùy chọn chỉ đăng nhập bằng profile, không nhập password (1) . đăng nhập bằng profile + password(2)
```
Tell me a name for the client.
The name must consist of alphanumeric character. It may also include an underscore or a dash.
Client name: admin_vpn

Do you want to protect the configuration file with a password?
(e.g. encrypt the private key with a password)
   1) Add a passwordless client
   2) Use a password for the client
Select an option [1-2]: 1

* Using SSL: openssl OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)

* Using Easy-RSA configuration: /etc/openvpn/easy-rsa/vars

* The preferred location for 'vars' is within the PKI folder.
  To silence this message move your 'vars' file to your PKI
  or declare your 'vars' file with option: --vars=<FILE>

```
profile được tạo ra và lưu ở đường dẫn
```
The configuration file has been written to /home/ubuntu/admin_vpn.ovpn.
Download the .ovpn file and import it in your OpenVPN client.
```

# Cấu hình mặc định trên server

```
vi /etc/openvpn/server.conf

```

```
port 1194
proto udp
dev tun
user nobody
group nogroup
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
push "redirect-gateway def1 bypass-dhcp"
dh none
ecdh-curve prime256v1
tls-crypt tls-crypt.key
crl-verify crl.pem
ca ca.crt
cert server_I6w4V2ZCLELzH8Dn.crt
key server_I6w4V2ZCLELzH8Dn.key
auth SHA256
cipher AES-128-GCM
ncp-ciphers AES-128-GCM
tls-server
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
client-config-dir /etc/openvpn/ccd
status /var/log/openvpn/status.log
verb 3
```
mặc định server sẽ push DNS và default gateway xuống client, nên client sẽ sử dụng đường vpn làm default gateway

Nếu muốn client ko sử dụng vpn làm default gateway ta cần chỉnh lại trên profile của client

```
# setenv opt block-outside-dns # Prevent Windows 10 DNS leak
route-nopull
route 172.22.22.0 255.255.255.0
```
ý nghĩa là client sẽ không sử dụng bất cứ cái gì của server pull xuống
chỉ route mạng 172.22.22.0/24 đi qua đường VPN

```
vi /home/ubuntu/admin_vpn.ovpn
```

```
client
proto udp
explicit-exit-notify
remote 61.14.236.211 1194
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server_I6w4V2ZCLELzH8Dn name
auth SHA256
auth-nocache
cipher AES-128-GCM
tls-client
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
ignore-unknown-option block-outside-dns
# setenv opt block-outside-dns # Prevent Windows 10 DNS leak
route-nopull
route 172.22.22.0 255.255.255.0
verb 3
```
lưu lại và tải profile về để sử dụng
Có thể tùy chỉnh template profile để mặc định tạo các profile khác đều đã edit sẵn
```
vi /etc/openvpn/client-template.txt
```
cấu hình profile template như trên

# restart service

```
systemctl restart openvpn@server.service
```

# Add thêm profile

```
root@OPENVPN:~# ./ubuntu-22.04-lts-vpn-server.sh
Welcome to OpenVPN-install!
The git repository is available at: https://github.com/angristan/openvpn-install

It looks like OpenVPN is already installed.

What do you want to do?
   1) Add a new user
   2) Revoke existing user
   3) Remove OpenVPN
   4) Exit
Select an option [1-4]:
```















