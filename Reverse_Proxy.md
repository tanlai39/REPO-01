# Cấu hình Reverse Proxy trên Nginx

Mô hình triển khai
```
Client (Internet)
        ↓
61.14.236.210 (Proxy server)
        ↓
Proxy forward HTTPS → 61.14.236.211:14043
        ↓
edge 61.14.236.211 DNAT 14043 vào server web có ip local
```
# Cài Nginx
```
sudo apt -y update && apt -y upgrade
sudo apt install nginx -y
```

# Cấu hình Nginx làm Reverse Proxy
```
vi /etc/nginx/sites-available/proxy
```


```
server {
    listen 443 ssl;
    server_name lab.tanlv.io.vn;

    ssl_certificate /etc/letsencrypt/live/tanlv.io.vn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tanlv.io.vn/privkey.pem;

    location / {
        proxy_pass https://61.14.236.211:14043;
        proxy_ssl_verify off;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
với cấu hình này chỉ forward traffic https, nếu server ngoài https còn các giao thức khác thì cần bổ sung cấu hình

# Kích hoạt cấu hình
```
sudo ln -s /etc/nginx/sites-available/proxy /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```
