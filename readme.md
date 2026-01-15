# auto config

## before you go

install acme.sh

[curl https://get.acme.sh | sh -s email=my@example.com](https://github.com/acmesh-official/acme.sh?tab=readme-ov-file#1%EF%B8%8F%E2%83%A3-how-to-install)

I assume you install your acme.sh to `~/.acme.sh`, and have your own domain.


## let's roll

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

if you want enable permently, write the setting to  `/etc/sysctl.conf` and run `sysctl -p`

