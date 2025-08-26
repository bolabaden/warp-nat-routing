#!/bin/bash
set -xe

# curl is already present; install jq manually if not present
if ! command -v jq >/dev/null 2>&1; then
  echo \"jq not found, installing...\"
  ARCH=$(uname -m)
  case \"$ARCH\" in
    x86_64) JQ_ARCH=\"amd64\" ;;
    aarch64|arm64) JQ_ARCH=\"aarch64\" ;;
    *) echo \"Unsupported architecture: $ARCH\"; exit 1 ;;
  esac
  # Get the latest release tag from GitHub API
  LATEST_TAG=$(curl -s https://api.github.com/repos/jqlang/jq/releases/latest | grep '\"tag_name\":' | sed -E 's/.*\"([^\"]+)\".*/\1/')
  JQ_URL=\"https://github.com/jqlang/jq/releases/download/$LATEST_TAG/jq-linux-$JQ_ARCH\"
  JQ_BIN=\"/usr/local/bin/jq\"
  curl -L -o \"${JQ_BIN}\" \"${JQ_URL}\" && chmod +x \"${JQ_BIN}\"
fi

DOCKER="docker -H ${DOCKER_HOST:-unix:///var/run/docker.sock}"

# Defaults (configurable via env)

# Track if variables were provided before setting defaults
ROUTER_CONTAINER_NAME_PROVIDED=false
if [[ -n "${ROUTER_CONTAINER_NAME+x}" ]]; then
  ROUTER_CONTAINER_NAME_PROVIDED=true
fi
ROUTER_CONTAINER_NAME="${ROUTER_CONTAINER_NAME:-warp_router}"

DOCKER_NETWORK_NAME_PROVIDED=false
if [[ -n "${DOCKER_NETWORK_NAME+x}" ]]; then
  DOCKER_NETWORK_NAME_PROVIDED=true
fi
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-}"

WARP_CONTAINER_NAME_PROVIDED=false
if [[ -n "${WARP_CONTAINER_NAME+x}" ]]; then
  WARP_CONTAINER_NAME_PROVIDED=true
fi
WARP_CONTAINER_NAME="${WARP_CONTAINER_NAME:-warp-nat-gateway}"

HOST_VETH_IP_PROVIDED=false
if [[ -n "${HOST_VETH_IP+x}" ]]; then
  HOST_VETH_IP_PROVIDED=true
fi
HOST_VETH_IP="${HOST_VETH_IP:-169.254.100.1}"

CONT_VETH_IP_PROVIDED=false
if [[ -n "${CONT_VETH_IP+x}" ]]; then
  CONT_VETH_IP_PROVIDED=true
fi
CONT_VETH_IP="${CONT_VETH_IP:-169.254.100.2}"

ROUTING_TABLE_PROVIDED=false
if [[ -n "${ROUTING_TABLE+x}" ]]; then
  ROUTING_TABLE_PROVIDED=true
fi
ROUTING_TABLE="${ROUTING_TABLE:-warp-nat-routing}"

VETH_HOST_PROVIDED=false
if [[ -n "${VETH_HOST+x}" ]]; then
  VETH_HOST_PROVIDED=true
fi
VETH_HOST="${VETH_HOST:-veth-warp-nat-host}" 

# VETH_CONT is derived from VETH_HOST, so we only need to track VETH_HOST_PROVIDED
VETH_CONT="${VETH_HOST#veth-}-nat-cont"

# Pick a free routing table id dynamically (start at 110)
pick_table_id() {
local id=110
while grep -q "^$id " /etc/iproute2/rt_tables 2>/dev/null; do
    id=$((id+1))
done
echo $id
}

# Get existing routing table ID if name exists, else pick new and add
if grep -q " $ROUTING_TABLE$" /etc/iproute2/rt_tables 2>/dev/null; then
    ROUTING_TABLE_ID=$(awk "/ $ROUTING_TABLE\$/ {print \$1}" /etc/iproute2/rt_tables)
    echo "Routing table id acquired: '$ROUTING_TABLE_ID'"
else
    ROUTING_TABLE_ID=$(pick_table_id)
    echo "$ROUTING_TABLE_ID $ROUTING_TABLE" >> /etc/iproute2/rt_tables
fi

# Determine docker network name and subnet dynamically if not provided
if [[ -z "${DOCKER_NETWORK_NAME:-}" ]]; then
    echo "Trying to find the network that ${ROUTER_CONTAINER_NAME} is connected to..."
    warp_router_networks="$($DOCKER inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf \"%s\n\" $k}}{{end}}' ${ROUTER_CONTAINER_NAME} 2>/dev/null || true)"
    if [[ -n "$warp_router_networks" ]]; then
        # Use the first network found
        DOCKER_NETWORK_NAME="${warp_router_networks%%$'\n'*}"
        echo "DOCKER_NETWORK_NAME: '$DOCKER_NETWORK_NAME'"
    else
        echo "DOCKER_NETWORK_NAME: not found nor set"
    fi
fi

# If still not set, fallback to default
if [[ -z "${DOCKER_NETWORK_NAME:-}" ]]; then
    echo "DOCKER_NETWORK_NAME: '$DOCKER_NETWORK_NAME' not set, using default 'warp-nat-net'"
    DOCKER_NETWORK_NAME="warp-nat-net"
    if ! "$(echo $($DOCKER network inspect $DOCKER_NETWORK_NAME) | jq -r '.IPAM.Config[0].Subnet')" >/dev/null 2>&1; then
        echo "Creating docker network '$DOCKER_NETWORK_NAME'"
        $DOCKER network create --driver=bridge \
        -o com.docker.network.bridge.name="br_$DOCKER_NETWORK_NAME" \
        -o com.docker.network.bridge.enable_ip_masquerade=false \
        "$DOCKER_NETWORK_NAME"
    else
        echo "DOCKER_NETWORK_NAME: '$DOCKER_NETWORK_NAME' already exists"
    fi
fi

# Only create the network if router container is not connected to any network
warp_router_network_count="$($DOCKER inspect -f '{{len .NetworkSettings.Networks}}' ${ROUTER_CONTAINER_NAME} 2>/dev/null || echo 0)"
if [[ "$warp_router_network_count" -eq 0 ]]; then
    if ! $DOCKER network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
        echo "Creating docker network '$DOCKER_NETWORK_NAME'"
        $DOCKER network create --driver=bridge \
        -o com.docker.network.bridge.name="br_$DOCKER_NETWORK_NAME" \
        -o com.docker.network.bridge.enable_ip_masquerade=false \
        "$DOCKER_NETWORK_NAME"
    fi
fi

STACK_NAME=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' ${ROUTER_CONTAINER_NAME} 2>/dev/null || echo "")
echo "STACK_NAME: $STACK_NAME"

# Strip project prefix (handles both prefixed and non-prefixed names)
# Pattern includes trailing '_' for Compose-managed networks
BASE_NETWORK_NAME="${DOCKER_NETWORK_NAME#${STACK_NAME}_}"
STACK_NETWORK_NAME="${STACK_NAME}_${BASE_NETWORK_NAME:-$DOCKER_NETWORK_NAME}"
BRIDGE_NAME="br_${BASE_NETWORK_NAME:-$DOCKER_NETWORK_NAME}"

# Dynamically get DOCKER_NET from network
DOCKER_NET="$($DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' $STACK_NETWORK_NAME 2>/dev/null || \
        $DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' $BASE_NETWORK_NAME 2>/dev/null | tr -d '[:space:]')"
echo "DOCKER_NET: \"$DOCKER_NET\""
if [[ -z "$DOCKER_NET" ]]; then
    echo "Error: DOCKER_NET not found"
    exit 1
fi

warp_pid="$($DOCKER inspect -f '{{.State.Pid}}' $WARP_CONTAINER_NAME || echo "")"

if [[ ! -e "/proc/$warp_pid/ns/net" ]]; then
    echo "Error: warp-nat-gateway container network namespace not ready"
    echo "warp-nat-gateway container network namespace not ready" >> /var/log/warp-nat-routing.log
    exit 1
fi

# Clean orphan ip rules for this routing table
ip rule show | grep "lookup $ROUTING_TABLE" | while read -r line; do
    from_cidr=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="from") print $(i+1)}')
    if [[ -z "$from_cidr" ]]; then continue; fi
    if [[ "$from_cidr" == "$DOCKER_NET" ]]; then continue; fi
    route_line=$(ip route show exact "$from_cidr" 2>/dev/null)
    if [[ -z "$route_line" ]]; then
        echo "Removing orphan rule for non-existing network: $from_cidr"
        ip rule del from "$from_cidr" table "$ROUTING_TABLE" 2>/dev/null || true
        continue
    fi
    dev=$(echo "$route_line" | awk '{print $3}')
    state=$(ip link show "$dev" 2>/dev/null | grep -oP 'state \K\w+' || echo "DOWN")
    if [[ "$state" != "UP" ]]; then
        echo "Removing orphan rule for down interface $dev: $from_cidr"
        ip rule del from "$from_cidr" table "$ROUTING_TABLE" 2>/dev/null || true
    fi
done

# Clean orphan NAT rules on host
iptables -t nat -S POSTROUTING | grep -- '-j MASQUERADE' | grep ' ! -d ' | while read -r rule; do
    s_net=$(echo "$rule" | sed -n 's/.*-s \([^ ]*\) .*/\1/p')
    d_net=$(echo "$rule" | sed -n 's/.*! -d \([^ ]*\) .*/\1/p')
    if [[ "$s_net" != "$d_net" || -z "$s_net" ]]; then continue; fi
    if [[ "$s_net" == "$DOCKER_NET" ]]; then continue; fi
    route_line=$(ip route show exact "$s_net" 2>/dev/null)
    if [[ -z "$route_line" ]]; then
        echo "Removing orphan NAT rule for non-existing network: $s_net"
        del_rule=$(echo "$rule" | sed 's/^-A/-D/')
        iptables -t nat $del_rule 2>/dev/null || true
        continue
    fi
    dev=$(echo "$route_line" | awk '{print $3}')
    state=$(ip link show "$dev" 2>/dev/null | grep -oP 'state \K\w+' || echo "DOWN")
    if [[ "$state" != "UP" ]]; then
        echo "Removing orphan NAT rule for down interface $dev: $s_net"
        del_rule=$(echo "$rule" | sed 's/^-A/-D/')
        iptables -t nat $del_rule 2>/dev/null || true
    fi
done

# Clean orphan NAT rules inside warp container
nsenter -t "$warp_pid" -n iptables -t nat -S POSTROUTING | grep -- '-j MASQUERADE' | while read -r rule; do
    s_net=$(echo "$rule" | sed -n 's/.*-s \([^ ]*\) -j MASQUERADE.*/\1/p')
    if [[ -z "$s_net" ]]; then continue; fi
    if [[ "$s_net" == "$DOCKER_NET" ]]; then continue; fi
    route_line=$(ip route show exact "$s_net" 2>/dev/null)
    if [[ -z "$route_line" ]]; then
        echo "Removing orphan NAT rule inside warp for non-existing network: $s_net"
        del_rule=$(echo "$rule" | sed 's/^-A/-D/')
        nsenter -t "$warp_pid" -n iptables -t nat $del_rule 2>/dev/null || true
        continue
    fi
    dev=$(echo "$route_line" | awk '{print $3}')
    state=$(ip link show "$dev" 2>/dev/null | grep -oP 'state \K\w+' || echo "DOWN")
    if [[ "$state" != "UP" ]]; then
        echo "Removing orphan NAT rule inside warp for down interface $dev: $s_net"
        del_rule=$(echo "$rule" | sed 's/^-A/-D/')
        nsenter -t "$warp_pid" -n iptables -t nat $del_rule 2>/dev/null || true
    fi
done

# Set up cleanup function
cleanup() {
    echo "⚠️ Error occurred. Rolling back..."

    # Remove host veth
    remove_host_veth_cmd="ip link del $VETH_HOST"
    echo "Removing host veth: '$remove_host_veth_cmd'"
    eval "$remove_host_veth_cmd 2>/dev/null || true"

    # Remove ip rules
    remove_ip_rules_cmd="ip rule del from $DOCKER_NET table $ROUTING_TABLE"
    echo "Removing ip rules: '$remove_ip_rules_cmd'"
    eval "$remove_ip_rules_cmd 2>/dev/null || true"

    # Flush routing table if exists
    if ip route show table "$ROUTING_TABLE" >/dev/null 2>&1; then
        flush_routing_table_cmd="ip route flush table $ROUTING_TABLE"
        echo "Flushing routing table: '$flush_routing_table_cmd'"
        eval "$flush_routing_table_cmd"
    fi

    # Remove NAT rules on host
    remove_nat_rules_on_host_cmd="iptables -t nat -D POSTROUTING -s $DOCKER_NET ! -d $DOCKER_NET -j MASQUERADE"
    echo "Removing NAT rules on host: '$remove_nat_rules_on_host_cmd'"
    eval "$remove_nat_rules_on_host_cmd 2>/dev/null || true"

    # Remove NAT rules inside warp container
    remove_nat_rules_inside_warp_cmd="nsenter -t $warp_pid -n iptables -t nat -D POSTROUTING -s $DOCKER_NET -j MASQUERADE"
    echo "Removing NAT rules inside warp container: '$remove_nat_rules_inside_warp_cmd'"
    eval "$remove_nat_rules_inside_warp_cmd 2>/dev/null || true"
}

# Trap any error in the critical section
trap cleanup ERR

# --- Critical setup section ---
# Remove existing veth if present (handles restarts/crashes)
ip link del "$VETH_HOST" 2>/dev/null || true

# Create veth pair
ip link add "$VETH_HOST" type veth peer name "$VETH_CONT"

# Move container end into warp namespace
ip link set "$VETH_CONT" netns "$warp_pid"

# Assign host end
ip addr add "$HOST_VETH_IP/30" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

# Assign container end
nsenter -t "$warp_pid" -n ip addr add "$CONT_VETH_IP/30" dev "$VETH_CONT"
nsenter -t "$warp_pid" -n ip link set "$VETH_CONT" up
nsenter -t "$warp_pid" -n sysctl -w net.ipv4.ip_forward=1

# NAT inside warp (add if not exists)
nsenter -t "$warp_pid" -n iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -j MASQUERADE 2>/dev/null || \
nsenter -t "$warp_pid" -n iptables -t nat -A POSTROUTING -s "$DOCKER_NET" -j MASQUERADE

# Routing rules (del if exists, then add)
ip rule del from "$DOCKER_NET" table "$ROUTING_TABLE" 2>/dev/null || true
ip rule add from "$DOCKER_NET" table "$ROUTING_TABLE"

# Flush and add routes

# Ensure routing table exists before flushing
if ip route show table "$ROUTING_TABLE" >/dev/null 2>&1; then
    ip route flush table "$ROUTING_TABLE"
fi

echo "Using bridge device: $BRIDGE_NAME"

# Flush and add routes
if ip route show table "$ROUTING_TABLE" >/dev/null 2>&1; then
    ip route flush table "$ROUTING_TABLE"
fi

# Default route(s)
ip route add "$DOCKER_NET" dev "$BRIDGE_NAME" table "$ROUTING_TABLE"  # Add network route using stripped bridge name
ip route add default via "$CONT_VETH_IP" dev "$VETH_HOST" table "$ROUTING_TABLE"  # Add default route

# NAT on host (add if not exists)
iptables -t nat -C POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE

# Confirmation
echo "✅ Warp setup complete"
echo " Network: $DOCKER_NETWORK_NAME"
echo " Veth host: $VETH_HOST ($HOST_VETH_IP)"
echo " Veth cont: $VETH_CONT ($CONT_VETH_IP)"
echo " Docker net: $DOCKER_NET"
echo " Routing table: $ROUTING_TABLE ($ROUTING_TABLE_ID)"