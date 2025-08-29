#!/bin/bash

# Disconnect all containers from the 'warp-nat-net' network
set -xe

if [ $EUID -ne 0 ]; then
    echo "This script must be run as root (use sudo -e)"
    exit 1
fi

docker container prune -f
CONTAINERS_USING_WARP_NETWORK=$(docker network inspect warp-nat-net -f '{{range .Containers}}{{.Name}} {{end}}')
CONTAINERS_USING_WARP_NETWORK_COUNT=$(echo "$CONTAINERS_USING_WARP_NETWORK" | wc -w)
CONTAINER_INDEX=0
for container in $CONTAINERS_USING_WARP_NETWORK; do
    CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
    echo "Disconnecting $container from warp-nat-net ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
    docker network disconnect warp-nat-net "$container"
done

docker network rm warp-nat-net 2>/dev/null

docker network create --attachable -o com.docker.network.bridge.name=br_warp-nat-net -o com.docker.network.bridge.enable_ip_masquerade=false warp-nat-net

CONTAINER_INDEX=0
for container in $CONTAINERS_USING_WARP_NETWORK; do
    CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
    echo "Connecting $container to warp-nat-net ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
    docker network connect warp-nat-net "$container"
done
