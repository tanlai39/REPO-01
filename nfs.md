## HƯỚNG DẪN CÀI NFS SERVER

## INSTALL TRÊN NFS SERVER
Trên server có add thêm 1 ổ đĩa 200G dev/sdb1 mount đến /data

```
apt -y update && apt -y upgrade
apt install -y nfs-kernel-server
```
loại bỏ tất cả phân quyền cho thư mục này để các máy trạm có thể truy cập và tạo file.

```
sudo chown nobody:nogroup /data
sudo chmod 777 /data
```

Cấu hình NFS Server
```
vi /etc/exports
```
thêm dòng này xuống cuối file
```
/data *(rw,sync,no_subtree_check,no_root_squash)
```

Áp dụng cấu hình
```
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

Kiểm tra
```
sudo exportfs -v
```

```
root@k8s-nfs:~# sudo exportfs -v
/data           <world>(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash)
root@k8s-nfs:~#
```

## INSTALL TRÊN CLINET ĐỂ SỬ DỤNG NSF SERVER

```
apt install nfs-common
```
tạo thư mục để mount đến thư mục /data của NFS server

```
root@DNS:~# mkdir data_nfs
```

mount thư mục
```
mount -t nfs 172.17.17.100:/data /root/data_nfs
```



