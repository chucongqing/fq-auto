#!/bin/bash

host=$1
reload_cmd=$2
~/.acme.sh/acme.sh --force --issue -d $1 \
  --keylength ec-256 -w /var/www/cert \
  --reloadcmd $2