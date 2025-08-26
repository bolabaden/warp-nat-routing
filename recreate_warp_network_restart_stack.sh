#!/bin/bash

# Disconnect all containers from the 'warp-network' network
set -xe

if [ $EUID -ne 0 ]; then
    echo "This script must be run as root (use sudo -e)"
    exit 1
fi

docker container prune -f
CONTAINERS_USING_WARP_NETWORK=$(docker network inspect warp-network -f '{{range .Containers}}{{.Name}} {{end}}')
CONTAINERS_USING_WARP_NETWORK_COUNT=$(echo "$CONTAINERS_USING_WARP_NETWORK" | wc -w)
CONTAINER_INDEX=0
for container in $CONTAINERS_USING_WARP_NETWORK; do
    CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
    echo "Disconnecting $container from warp-network ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
    docker network disconnect warp-network "$container"
done

set +e
systemctl disable warp 2>/dev/null
systemctl stop warp 2>/dev/null

docker container stop warp 2>/dev/null
docker container rm warp 2>/dev/null
docker network rm warp-network 2>/dev/null

set -e
SETUP_SCRIPT="./projects/network/warp-nat-routing/setup-warp-service.sh"
WARP_NAT_ROUTING_DIR="./projects/network/warp-nat-routing"

mkdir -p $WARP_NAT_ROUTING_DIR

if [ ! -f $SETUP_SCRIPT ]; then
    git clone https://github.com/bolabaden/warp-nat-routing.git $WARP_NAT_ROUTING_DIR
fi

bash $SETUP_SCRIPT

CONTAINER_INDEX=0
for container in $CONTAINERS_USING_WARP_NETWORK; do
    CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
    echo "Connecting $container to warp-network ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
    docker network connect warp-network "$container"
done
