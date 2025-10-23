#!/bin/bash
set -xe

# Defaults (configurable via env)
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
ROUTER_CONTAINER_NAME="${ROUTER_CONTAINER_NAME:-warp_router}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-warp-nat-net}"
WARP_CONTAINER_NAME="${WARP_CONTAINER_NAME:-warp-nat-gateway}"
HOST_VETH_IP="${HOST_VETH_IP:-169.254.100.1}"
CONT_VETH_IP="${CONT_VETH_IP:-169.254.100.2}"
ROUTING_TABLE="${ROUTING_TABLE:-warp-nat-routing}"
VETH_HOST="${VETH_HOST:-veth-warp}" 

# VETH_CONT is derived from VETH_HOST
VETH_CONT="${VETH_HOST#veth-}-nat-cont"
DOCKER="docker -H $DOCKER_HOST"
DEFAULT_DOCKER_NETWORK_NAME="warp-nat-net"

echo "=========================================="
echo "Starting WARP NAT setup script"
echo "=========================================="

# ==========================================
# PHASE 1: COMPLETE CLEANUP OF OLD STATE
# ==========================================
echo ""
echo "Phase 1: Cleaning up any existing configuration..."

# Remove old veth interfaces
if ip link show "$VETH_HOST" >/dev/null 2>&1; then
    echo "Removing old veth interface: $VETH_HOST"
    ip link del "$VETH_HOST" 2>/dev/null || true
fi

# Get the subnet to clean up rules (try to get from network if it exists)
CLEANUP_SUBNET="${WARP_NAT_NET_SUBNET:-10.0.2.0/24}"
if $DOCKER network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
    EXISTING_SUBNET=$($DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$DOCKER_NETWORK_NAME" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$EXISTING_SUBNET" ]]; then
        CLEANUP_SUBNET="$EXISTING_SUBNET"
    fi
fi

# Remove old routing rules for this subnet
echo "Removing old routing rules for $CLEANUP_SUBNET"
while ip rule del from "$CLEANUP_SUBNET" table "$ROUTING_TABLE" 2>/dev/null; do
    echo "  Removed routing rule"
done

# Remove old iptables failsafe rules
echo "Removing old failsafe iptables rules"
while iptables -D FORWARD -s "$CLEANUP_SUBNET" -j DROP -m comment --comment "warp-nat-failsafe" 2>/dev/null; do
    echo "  Removed failsafe rule"
done

# Remove old NAT rules on host
echo "Removing old NAT rules on host"
iptables -t nat -D POSTROUTING -s "$CLEANUP_SUBNET" ! -d "$CLEANUP_SUBNET" -j MASQUERADE 2>/dev/null || true

echo "Phase 1 cleanup complete"

# Pick a free routing table id dynamically (start at 110)
pick_table_id() {
    local id=110
    while grep -q "^$id " /etc/iproute2/rt_tables 2>/dev/null; do
        id=$((id+1))
    done
    echo $id
}

# ==========================================
# PHASE 2: SETUP ROUTING TABLE
# ==========================================
echo ""
echo "Phase 2: Setting up routing table..."

# Get existing routing table ID if name exists, else pick new and add
if grep -q " $ROUTING_TABLE$" /etc/iproute2/rt_tables 2>/dev/null; then
    ROUTING_TABLE_ID=$(awk "/ $ROUTING_TABLE\$/ {print \$1}" /etc/iproute2/rt_tables)
    echo "Routing table exists: $ROUTING_TABLE (ID: $ROUTING_TABLE_ID)"
else
    ROUTING_TABLE_ID=$(pick_table_id)
    echo "$ROUTING_TABLE_ID $ROUTING_TABLE" >> /etc/iproute2/rt_tables
    echo "Created routing table: $ROUTING_TABLE (ID: $ROUTING_TABLE_ID)"
fi

# ==========================================
# PHASE 3: ENSURE NETWORK EXISTS AND DISCOVER WARP CONTAINER
# ==========================================
# This phase discovers the actual network name using Docker Compose naming conventions.
# Unlike the old approach that required the router container to exist and inspected its
# connected networks, this method:
# - Works independently of container state (more robust during setup/teardown)
# - Understands Compose prefixes network names with stack name (e.g., "stack_network")
# - Supports multiple WARP instances by using stack-specific naming
# - Is deterministic and idempotent (doesn't depend on container connection state)
echo ""
echo "Phase 3: Ensuring network exists and discovering WARP container..."

# Get stack name from compose labels to construct proper network name
# Tries router container first, falls back to warp container, then empty string
STACK_NAME="$(
    $DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$ROUTER_CONTAINER_NAME" 2>/dev/null \
    || $DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$WARP_CONTAINER_NAME" 2>/dev/null \
    || echo ""
)"

# NETWORK DISCOVERY (Non-Destructive Approach)
# ================================================
# OLD BEHAVIOR (removed): Would forcefully disconnect ALL containers, delete network, recreate it,
#                         then reconnect containers - causing service disruption every time script ran.
# NEW BEHAVIOR: Simply discovers and uses existing network without any modifications.
# BENEFITS:
#   - Zero downtime: containers stay connected, no service interruption
#   - True idempotency: can run multiple times safely without state changes
#   - Faster: no time wasted on disconnect/reconnect operations
#   - Simpler: no complex gw_priority preservation logic needed
#   - Multi-instance safe: different stacks can manage independent networks
# NETWORK LIFECYCLE: Managed by warp-net-init service, not this routing script.

# Check if network exists using Compose naming pattern (stack_network) first
# This allows multiple stacks to have their own warp-nat-net without conflicts
ACTUAL_NETWORK_NAME=""
if [[ -n "$STACK_NAME" ]]; then
    if $DOCKER network inspect "${STACK_NAME}_$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
        ACTUAL_NETWORK_NAME="${STACK_NAME}_$DOCKER_NETWORK_NAME"
    fi
fi

# Fallback: try plain network name (for external networks or single-stack deployments)
if [[ -z "$ACTUAL_NETWORK_NAME" ]]; then
    if $DOCKER network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
        ACTUAL_NETWORK_NAME="$DOCKER_NETWORK_NAME"
    fi
fi

# Create network only if it doesn't exist (idempotent approach)
# NOTE: This does NOT recreate/modify existing networks, avoiding disruption to connected containers.
# Previous behavior: forcefully recreated network every time, disconnecting/reconnecting all containers.
# New behavior: uses existing network as-is. To change network config, manually delete network first.
# Benefits: No container disruption, no "container not connected" errors, faster, more deterministic.
if [[ -z "$ACTUAL_NETWORK_NAME" ]]; then
    echo "Network $DOCKER_NETWORK_NAME does not exist, creating it..."
    BRIDGE_OPT_NAME="br_$DOCKER_NETWORK_NAME"
    $DOCKER network create \
        --driver=bridge \
        --attachable \
        -o com.docker.network.bridge.name="$BRIDGE_OPT_NAME" \
        -o com.docker.network.bridge.enable_ip_masquerade=false \
        --subnet="${WARP_NAT_NET_SUBNET:-10.0.2.0/24}" \
        --gateway="${WARP_NAT_NET_GATEWAY:-10.0.2.1}" \
        "$DOCKER_NETWORK_NAME"
    ACTUAL_NETWORK_NAME="$DOCKER_NETWORK_NAME"
    echo "Created network: $ACTUAL_NETWORK_NAME"
else
    echo "Found existing network: $ACTUAL_NETWORK_NAME"
fi

echo "Found network: $ACTUAL_NETWORK_NAME"

# Dynamically get network subnet
DOCKER_NET="$($DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$ACTUAL_NETWORK_NAME" 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$DOCKER_NET" ]]; then
    echo "Error: Could not determine subnet for network $ACTUAL_NETWORK_NAME"
    exit 1
fi
echo "Network subnet: $DOCKER_NET"

# Dynamically get the actual bridge name from the network
BRIDGE_NAME="$($DOCKER network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$ACTUAL_NETWORK_NAME" 2>/dev/null)"
if [[ -z "$BRIDGE_NAME" || "$BRIDGE_NAME" == "<no value>" ]]; then
    # Fallback: construct bridge name from network ID (Docker's default pattern)
    NETWORK_ID="$($DOCKER network inspect -f '{{.Id}}' "$ACTUAL_NETWORK_NAME" 2>/dev/null | cut -c1-12)"
    BRIDGE_NAME="br-$NETWORK_ID"
    echo "Bridge name not explicitly set, using Docker default: $BRIDGE_NAME"
else
    echo "Bridge device: $BRIDGE_NAME"
fi

# Verify the bridge exists
if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    echo "Error: Bridge $BRIDGE_NAME does not exist"
    echo "Available bridges:"
    ip link show type bridge
    exit 1
fi

# Get WARP container PID
warp_pid="$($DOCKER inspect -f '{{.State.Pid}}' $WARP_CONTAINER_NAME 2>/dev/null || echo \"\")"
if [[ -z "$warp_pid" || "$warp_pid" == "0" ]]; then
    echo "Error: $WARP_CONTAINER_NAME container not found or not running"
    exit 1
fi

if [[ ! -e "/proc/$warp_pid/ns/net" ]]; then
    echo "Error: $WARP_CONTAINER_NAME container network namespace not ready"
    exit 1
fi

echo "Found WARP container PID: $warp_pid"

# Clean orphan NAT rules inside warp container (for any stale subnets)
echo "Cleaning orphan NAT rules inside WARP container..."
nsenter -t "$warp_pid" -n iptables -t nat -S POSTROUTING 2>/dev/null | grep -- '-j MASQUERADE' | while read -r rule; do
    s_net=$(echo "$rule" | sed -n 's/.*-s \([^ ]*\) -j MASQUERADE.*/\1/p')
    if [[ -z "$s_net" ]]; then continue; fi
    if [[ "$s_net" == "$DOCKER_NET" ]]; then continue; fi
    echo "  Removing orphan NAT rule inside warp: $s_net"
    del_rule=$(echo "$rule" | sed 's/^-A/-D/')
    nsenter -t "$warp_pid" -n iptables -t nat $del_rule 2>/dev/null || true
done

# Set up cleanup function for error handling
cleanup() {
    echo "⚠️ Error occurred. Rolling back changes..."

    # Remove host veth if it was created
    if ip link show "$VETH_HOST" >/dev/null 2>&1; then
        echo "Removing veth interface: $VETH_HOST"
        ip link del "$VETH_HOST" 2>/dev/null || true
    fi

    # Remove ip rule if it was added
    if ip rule show | grep -q "from $DOCKER_NET lookup $ROUTING_TABLE"; then
        echo "Removing routing rule: from $DOCKER_NET lookup $ROUTING_TABLE"
        ip rule del from "$DOCKER_NET" table "$ROUTING_TABLE" 2>/dev/null || true
    fi

    # Remove specific routes from routing table if they exist
    if ip route show table "$ROUTING_TABLE" | grep -q "^default via $CONT_VETH_IP dev $VETH_HOST"; then
        echo "Removing default route from $ROUTING_TABLE"
        ip route del default via "$CONT_VETH_IP" dev "$VETH_HOST" table "$ROUTING_TABLE" 2>/dev/null || true
    fi
    if ip route show table "$ROUTING_TABLE" | grep -q "^$DOCKER_NET dev $BRIDGE_NAME"; then
        echo "Removing network route from $ROUTING_TABLE"
        ip route del "$DOCKER_NET" dev "$BRIDGE_NAME" table "$ROUTING_TABLE" 2>/dev/null || true
    fi

    # Remove NAT rule on host if it exists
    if iptables -t nat -C POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE 2>/dev/null; then
        echo "Removing NAT rule on host"
        iptables -t nat -D POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE 2>/dev/null || true
    fi

    # Remove NAT rule inside warp container if it exists
    if [[ -n "$warp_pid" ]] && [[ -e "/proc/$warp_pid/ns/net" ]]; then
        if nsenter -t "$warp_pid" -n iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -j MASQUERADE 2>/dev/null; then
            echo "Removing NAT rule inside WARP container"
            nsenter -t "$warp_pid" -n iptables -t nat -D POSTROUTING -s "$DOCKER_NET" -j MASQUERADE 2>/dev/null || true
        fi
    fi
    
    # CRITICAL: Ensure failsafe DROP rule is in place to prevent IP leaks
    if ! iptables -C FORWARD -s "$DOCKER_NET" -j DROP -m comment --comment "warp-nat-failsafe" 2>/dev/null; then
        echo "Re-enabling failsafe DROP rule to prevent IP leaks"
        iptables -I FORWARD -s "$DOCKER_NET" -j DROP -m comment --comment "warp-nat-failsafe" 2>/dev/null || true
    fi
}

# ==========================================
# PHASE 4: CRITICAL SETUP WITH FAILSAFE
# ==========================================
echo ""
echo "Phase 4: Setting up VETH tunnel and routing..."

# Trap any error in the critical section
trap cleanup ERR

# CRITICAL FAILSAFE: Block all traffic from warp-nat-net by default
# This prevents IP leaks if setup fails. Rule will be removed at the end if setup succeeds.
echo "Installing failsafe DROP rule to prevent IP leaks during setup"
# Add failsafe rule at the top of FORWARD chain (already cleaned in Phase 1)
iptables -I FORWARD -s "$DOCKER_NET" -j DROP -m comment --comment "warp-nat-failsafe"

# Create veth pair (host side: $VETH_HOST, container side: $VETH_CONT)
echo "Creating veth pair: $VETH_HOST <-> $VETH_CONT"
ip link add "$VETH_HOST" type veth peer name "$VETH_CONT"

# Move container end into warp namespace
echo "Moving $VETH_CONT into WARP container namespace"
ip link set "$VETH_CONT" netns "$warp_pid"

# Configure host end of veth
echo "Configuring host veth: $VETH_HOST ($HOST_VETH_IP/30)"
ip addr add "$HOST_VETH_IP/30" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

# Configure container end of veth
echo "Configuring container veth: $VETH_CONT ($CONT_VETH_IP/30)"
nsenter -t "$warp_pid" -n ip addr add "$CONT_VETH_IP/30" dev "$VETH_CONT"
nsenter -t "$warp_pid" -n ip link set "$VETH_CONT" up
nsenter -t "$warp_pid" -n sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Setup NAT inside warp container
echo "Setting up NAT inside WARP container for $DOCKER_NET"
nsenter -t "$warp_pid" -n iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -j MASQUERADE 2>/dev/null || \
nsenter -t "$warp_pid" -n iptables -t nat -A POSTROUTING -s "$DOCKER_NET" -j MASQUERADE

# Setup routing rules
echo "Adding routing rule: from $DOCKER_NET lookup $ROUTING_TABLE"
ip rule add from "$DOCKER_NET" table "$ROUTING_TABLE"

# Setup routing table entries (delete specific routes first if they exist)
echo "Configuring routes in routing table $ROUTING_TABLE"

# Remove existing network route if present
if ip route show table "$ROUTING_TABLE" | grep -q "^$DOCKER_NET dev $BRIDGE_NAME"; then
    echo "  Removing existing network route for $DOCKER_NET"
    ip route del "$DOCKER_NET" dev "$BRIDGE_NAME" table "$ROUTING_TABLE" 2>/dev/null || true
fi

# Remove existing default route if present
if ip route show table "$ROUTING_TABLE" | grep -q "^default via $CONT_VETH_IP dev $VETH_HOST"; then
    echo "  Removing existing default route"
    ip route del default via "$CONT_VETH_IP" dev "$VETH_HOST" table "$ROUTING_TABLE" 2>/dev/null || true
fi

# Add the routes
echo "  Adding network route: $DOCKER_NET dev $BRIDGE_NAME"
ip route add "$DOCKER_NET" dev "$BRIDGE_NAME" table "$ROUTING_TABLE"
echo "  Adding default route: default via $CONT_VETH_IP dev $VETH_HOST"
ip route add default via "$CONT_VETH_IP" dev "$VETH_HOST" table "$ROUTING_TABLE"

# Setup NAT on host
echo "Setting up NAT on host for $DOCKER_NET"
iptables -t nat -C POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE

# CRITICAL: Remove failsafe DROP rule now that routing is properly configured
echo "Removing failsafe DROP rule - routing is now active"
while iptables -D FORWARD -s "$DOCKER_NET" -j DROP -m comment --comment "warp-nat-failsafe" 2>/dev/null; do 
    echo "  Removed failsafe rule"
done

# Disable error trap now that setup completed successfully
trap - ERR

# ==========================================
# SETUP COMPLETE
# ==========================================
echo ""
echo "=========================================="
echo "✅ WARP NAT setup complete"
echo "=========================================="
echo "Network:        $DOCKER_NETWORK_NAME"
echo "Subnet:         $DOCKER_NET"
echo "Veth host:      $VETH_HOST ($HOST_VETH_IP)"
echo "Veth container: $VETH_CONT ($CONT_VETH_IP)"
echo "Routing table:  $ROUTING_TABLE (ID: $ROUTING_TABLE_ID)"
echo "Bridge:         $BRIDGE_NAME"
echo "=========================================="
