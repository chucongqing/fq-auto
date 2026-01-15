# auto config

1. `make env`, change .env to your settings
1. `make template`
2. `make up-nginx`, `make issue_cert` `make install_cert`
3. `make up`



```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=0
```
如果你希望永久生效，请将该行写入 `/etc/sysctl.conf`。 然后 `sysctl -p`