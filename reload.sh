#!/bin/bash

compose="docker compose"

$compose -f server/nginx/docker-compose.yml down
$compose -f server/hy2/docker-compose.yml down
$compose -f server/xray/docker-compose.yml down

$compose -f server/nginx/docker-compose.yml up -d
$compose -f server/hy2/docker-compose.yml up -d
$compose -f server/xray/docker-compose.yml up -d