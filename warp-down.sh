#!/bin/bash

set -e
set -x

# Define the same variables as in warp-up.sh
docker_network_name="warp-network"
docker_bridge="br_${docker_network_name}"
veth_host="veth-warp-host"
veth_container="warp-host-cont"
host_veth_ip="169.254.100.1"
cont_veth_ip="169.254.100.2"
docker_net="10.45.0.0/16"
routing_table="warp"

echo "🔧 Starting warp-down cleanup..."

# Get the local interface before we start (might fail if no default route)
local_interface=$(ip route | grep default | awk '{print $5}' | head -1) || true

# Remove iptables FORWARD rules
if [ -n "$local_interface" ]; then
    echo "Removing FORWARD rules..."
    iptables -D FORWARD -o $docker_bridge -i $local_interface -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i $docker_bridge -o $local_interface -j ACCEPT 2>/dev/null || true
fi

# Remove NAT rule on the host
echo "Removing host NAT rules..."
iptables -t nat -D POSTROUTING -s $docker_net ! -d $docker_net -j MASQUERADE 2>/dev/null || true

# Remove routing table rules and routes
echo "Removing routing table entries..."
ip route flush table $routing_table 2>/dev/null || true
ip rule del from $docker_net table $routing_table 2>/dev/null || true

# Remove NAT inside container (if container exists)
if docker ps -q -f name=warp >/dev/null 2>&1; then
    pid=$(docker inspect -f '{{.State.Pid}}' warp 2>/dev/null) || true
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        echo "Removing container NAT rules..."
        nsenter -t $pid -n iptables -t nat -D POSTROUTING -s $docker_net -j MASQUERADE 2>/dev/null || true
    fi
fi

# Remove veth pair
echo "Removing veth pair..."
if ip link show $veth_host &>/dev/null; then
    ip link del $veth_host 2>/dev/null || true
fi
# Note: Deleting one end of veth pair automatically deletes the other end

# Remove the routing table entry from rt_tables
echo "Cleaning up routing table definition..."
if grep -q "110 $routing_table" /etc/iproute2/rt_tables; then
    sed -i "/110 $routing_table/d" /etc/iproute2/rt_tables || true
fi

# Optionally remove the Docker network (commented out by default)
# Uncomment the following lines if you want to remove the Docker network
#echo "Removing Docker network..."
#docker network rm $docker_network_name 2>/dev/null || true

echo "✅ Warp routing cleanup complete"
echo ""
