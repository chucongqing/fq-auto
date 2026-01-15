# auto config
1. `make init`
1. `make env`, change .env to your settings
1. `make template` let the .env fill your config file.
2. `make up-nginx`, and `make issue_cert` `make install_cert` set your domain before this.
3. `chmod + x reload.sh`
4. `./reload.sh`



if you can't bind 443 to your container's progam

```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=0
```

如果你希望永久生效，请将该行写入 `/etc/sysctl.conf`。 然后 `sysctl -p`
