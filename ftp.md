# HƯỚNG DẪN CÀI ĐẶT FTP SERVER

Linh tham khảo: https://tel4vn.edu.vn/blog/how-to-install-ftp-server-use-vsftpd-with-ssl-tls/

# Cài đặt hệ thống

```
apt -y update && apt -y upgrade
sudo apt install vsftpd
```

# Cấu hình Firewall
khúc này chưa enable firewall, vì enable sẽ bị ngắt ssh

```
sudo ufw allow 22/tcp
sudo ufw allow 20:21/tcp
sudo ufw allow 990/tcp
sudo ufw allow 35000:40000/tcp
```
khúc này mới enable firewall

```
sudo ufw enable
sudo ufw status

```

# Tạo user FTP
tạo user để sử dụng ftp

```
sudo adduser tpcftp
```

Thêm user vào danh sách được phép login:

```
echo "tpcftp" | sudo tee -a /etc/vsftpd.userlist
```
lưu ý:

User tpcftp chỉ được phép truy cập đúng thư mục /home/tpcftp/switch-router.

Firewall đã mở đủ cho FTP passive.

# Tạo thư mục lưu cấu hình

```
sudo mkdir -p /home/tpcftp/switch-router/upload
sudo chown -R tpcftp:tpcftp /home/tpcftp
sudo chmod 755 /home/tpcftp
sudo chmod 755 /home/tpcftp/switch-router
```

# Cấu hình vsftpd.conf

```
vi /etc/vsftpd.conf
```
dán nội dung này vào

```
listen=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO
pasv_min_port=35000
pasv_max_port=40000
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
```

# Restart dịch vụ FTP

```
sudo systemctl restart vsftpd
sudo systemctl enable vsftpd
sudo systemctl status vsftpd
```
# Trên thiết bị Cisco cấu hình archive backup

```
archive
 log config
  hidekeys
 path ftp://tpcftp:xxxxxxxxxxxx@172.22.22.24/switch-router/$h_
 write-memory
 time-period 10080
```

# Lưu ý: ở trên cisco chỉ xuất file cấu hình dạng text để đọc cấu hình, chứ ko sử dụng để import cấu hình vào router cisco được

copy cấu hình runing-config vào ftp

```
copy running-config ftp://tpcftp:xxxxxxxxx@172.22.22.24/switch-router/full-backup-ASR1000X.cfg

```

restore cấu hình từ ftp ra thiết bị

```
copy ftp://tpcftp:xxxxxxxxx@172.22.22.24/switch-router/full-backup-ASR1000X.cfg running-config
```

# Sử dụng filezila trên máy client để kết nối
![image](https://github.com/user-attachments/assets/9ac6cc6c-3a88-4773-a020-b1456b6e2bdd)


# Một số tùy chỉnh cho server
1.mặc định account tpcftp ssh vào server được, để chặn không cho account ssh vào ta làm như sau:

Thêm vào cuối /etc/ssh/sshd_config

```
DenyUsers tpcftp
```
restart service ssh

```
sudo systemctl restart ssh
```

