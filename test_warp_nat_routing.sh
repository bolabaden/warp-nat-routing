#!/bin/bash
set -e

docker compose down
docker network rm warp-nat-net || true
docker network create --attachable -o com.docker.network.bridge.name=br_warp-nat-net -o com.docker.network.bridge.enable_ip_masquerade=false warp-nat-net
docker compose up -d --remove-orphans --force-recreate --build \
  ip-checker-naked \
  ip-checker-warp \
  ip-checker-warp-multi-ambiguous \
  ip-checker-warp-multi-uses-warp \
  stack-network-checker \
  warp_router \
  warp-nat-gateway
docker container logs -f warp_router

echo "Waiting next update loop of ip-checkers..."
sleep 10

echo ""
echo "ip-checker-warp logs:"
docker container logs ip-checker-warp

echo ""
echo "ip-checker-warp-multi-uses-warp logs:"
docker container logs ip-checker-warp-multi-uses-warp

echo ""
echo "stack-network-checker logs:"
docker container logs stack-network-checker