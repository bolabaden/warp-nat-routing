
#!/bin/bash
set -e

# Defaults (configurable via env)
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
ROUTER_CONTAINER_NAME="${ROUTER_CONTAINER_NAME:-warp_router}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-}"
WARP_CONTAINER_NAME="${WARP_CONTAINER_NAME:-warp-nat-gateway}"
HOST_VETH_IP="${HOST_VETH_IP:-169.254.100.1}"
CONT_VETH_IP="${CONT_VETH_IP:-169.254.100.2}"
ROUTING_TABLE="${ROUTING_TABLE:-warp-nat-routing}"
VETH_HOST="${VETH_HOST:-veth-warp-nat-host}" 

# VETH_CONT is derived from VETH_HOST, so we only need to track VETH_HOST_PROVIDED
VETH_CONT="${VETH_HOST#veth-}-nat-cont"
DOCKER="docker -H $DOCKER_HOST"
DEFAULT_DOCKER_NETWORK_NAME="warp-nat-net"

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
    echo "Routing table id acquired: \`$ROUTING_TABLE_ID\`"
else
    ROUTING_TABLE_ID=$(pick_table_id)
    echo "$ROUTING_TABLE_ID $ROUTING_TABLE" >> /etc/iproute2/rt_tables
fi

if docker ps -a --format '{{.Names}}' | grep -w "${ROUTER_CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container '${ROUTER_CONTAINER_NAME}' exists."
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
fi

# If not set, fallback to default
if [[ -z "${DOCKER_NETWORK_NAME:-}" ]]; then
    echo "DOCKER_NETWORK_NAME: \`$DOCKER_NETWORK_NAME\` not set, using default \`$DEFAULT_DOCKER_NETWORK_NAME\`"
    DOCKER_NETWORK_NAME="$DEFAULT_DOCKER_NETWORK_NAME"
fi

# Create docker network if it doesn't exist
if $DOCKER network inspect $DOCKER_NETWORK_NAME --format '{{.Name}}' | grep -q "^$DOCKER_NETWORK_NAME$"; then
    echo "Docker network \`$DOCKER_NETWORK_NAME\` already exists, recreating it"
    RECREATED_WARP_NETWORK=1

    # Store original gw_priority for each container
    CONTAINERS_USING_WARP_NETWORK=$($DOCKER network inspect $DOCKER_NETWORK_NAME -f '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}')
    CONTAINERS_USING_WARP_NETWORK_COUNT=$(echo "$CONTAINERS_USING_WARP_NETWORK" | wc -w)
    CONTAINER_INDEX=0

    # Map: container_name:gw_priority
    declare -A ORIGINAL_GW_PRIORITY

    # Get original gw_priority for each container
    for container in $CONTAINERS_USING_WARP_NETWORK; do
        # Get the container's network info as JSON
        container_json="$($DOCKER inspect "$container" 2>/dev/null)"
        # Extract the gw_priority for this network
        gw_priority=$(echo "$container_json" | jq -r --arg net "$DOCKER_NETWORK_NAME" '.[0].NetworkSettings.Networks[$net].GwPriority // empty')
        ORIGINAL_GW_PRIORITY["$container"]="$gw_priority"
    done

    for container in $CONTAINERS_USING_WARP_NETWORK; do
        CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
        echo "Disconnecting \`$container\` from \`$DOCKER_NETWORK_NAME\` ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
        $DOCKER network disconnect $DOCKER_NETWORK_NAME "$container"
    done

    $DOCKER network rm $DOCKER_NETWORK_NAME 2>/dev/null || true
fi

echo "Creating docker network \`$DOCKER_NETWORK_NAME\`"
$DOCKER network create --driver=bridge \
    --attachable \
    -o com.docker.network.bridge.name=br_$DOCKER_NETWORK_NAME \
    -o com.docker.network.bridge.enable_ip_masquerade=false \
    $DOCKER_NETWORK_NAME

if [[ -n "${RECREATED_WARP_NETWORK:-}" ]]; then
    echo "Connecting containers to \`$DOCKER_NETWORK_NAME\`"
    CONTAINER_INDEX=0
    for container in $CONTAINERS_USING_WARP_NETWORK; do
        CONTAINER_INDEX=$((CONTAINER_INDEX + 1))
        # Use original gw_priority if available, else fallback to 0x7FFFFFFFFFFFFFFF
        gw_priority="${ORIGINAL_GW_PRIORITY[$container]}"
        if [[ -n "$gw_priority" && "$gw_priority" != "null" ]]; then
            echo "Connecting \`$container\` to \`$DOCKER_NETWORK_NAME\` with original gw_priority=$gw_priority ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
            $DOCKER network connect --gw-priority "$gw_priority" "$DOCKER_NETWORK_NAME" "$container" || true
        else
            echo "Connecting \`$container\` to \`$DOCKER_NETWORK_NAME\` with default gw_priority ($CONTAINER_INDEX out of $CONTAINERS_USING_WARP_NETWORK_COUNT )"
            $DOCKER network connect --gw-priority 0x7FFFFFFFFFFFFFFF "$DOCKER_NETWORK_NAME" "$container" || true
        fi
    done
fi

# Get stack name from eithe warp_router, or if script was ran on host, get from warp-nat-gateway
STACK_NAME="$(
    $DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$ROUTER_CONTAINER_NAME" 2>/dev/null \
    || $DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$WARP_CONTAINER_NAME" 2>/dev/null
)"
# Strip project prefix (handles both prefixed and non-prefixed names)
# Pattern includes trailing '_' for Compose-managed networks
BASE_NETWORK_NAME="${DOCKER_NETWORK_NAME#$STACK_NAME_}"
STACK_NETWORK_NAME="$STACK_NAME_${BASE_NETWORK_NAME:-$DOCKER_NETWORK_NAME}"
BRIDGE_NAME="br_${BASE_NETWORK_NAME:-$DOCKER_NETWORK_NAME}"

# Dynamically get DOCKER_NET from network
DOCKER_NET="$(
    (
        $DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$STACK_NETWORK_NAME" 2>/dev/null \
        || $DOCKER network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$BASE_NETWORK_NAME" 2>/dev/null
    ) | tr -d '[:space:]'
)"
if [[ -z "$DOCKER_NET" ]]; then
    echo "Error: \`\$DOCKER_NET\` not found"
    exit 1
fi

# Remove existing veth if present (handles restarts/crashes)
ip link del "$VETH_HOST" 2>/dev/null || true

# Create veth pair
ip link add "$VETH_HOST" type veth peer name "$VETH_CONT"

warp_pid="$($DOCKER inspect -f '{{.State.Pid}}' $WARP_CONTAINER_NAME || echo \"\")"
if [[ -z "$warp_pid" ]]; then
    echo ""
    echo "Error: \`$WARP_CONTAINER_NAME\` container not found"
    echo "\`$WARP_CONTAINER_NAME\` container not found" >> /var/log/warp-nat-routing.log
    echo ""
    exit 1
fi

if [[ ! -e "/proc/$warp_pid/ns/net" ]]; then
    echo ""
    echo "Error: \`$WARP_CONTAINER_NAME\` container network namespace not ready"
    echo "\`$WARP_CONTAINER_NAME\` container network namespace not ready" >> /var/log/warp-nat-routing.log
    echo ""
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
    state=$(ip link show "$dev" 2>/dev/null | grep -E -o 'state \K\w+' || echo "DOWN")
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
    state=$(ip link show "$dev" 2>/dev/null | grep -E -o 'state \K\w+' || echo "DOWN")
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
    state=$(ip link show "$dev" 2>/dev/null | grep -E -o 'state \K\w+' || echo "DOWN")
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

# Ensure routing table exists before flushing
if ip route show table "$ROUTING_TABLE" >/dev/null 2>&1; then
    ip route flush table "$ROUTING_TABLE"
fi
echo "Using bridge device: \`$BRIDGE_NAME\`"

# Default route(s)
ip route add "$DOCKER_NET" dev "$BRIDGE_NAME" table "$ROUTING_TABLE"  # Add network route using stripped bridge name
ip route add default via "$CONT_VETH_IP" dev "$VETH_HOST" table "$ROUTING_TABLE"  # Add default route

# NAT on host (add if not exists)
iptables -t nat -C POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$DOCKER_NET" ! -d "$DOCKER_NET" -j MASQUERADE

# Confirmation
echo "✅ Warp setup complete"
echo " Network: \`$DOCKER_NETWORK_NAME\`"
echo " Veth host: \`$VETH_HOST\` ($HOST_VETH_IP)"
echo " Veth cont: \`$VETH_CONT\` ($CONT_VETH_IP)"
echo " Docker net: \`$DOCKER_NET\`"
echo " Routing table: \`$ROUTING_TABLE\` ($ROUTING_TABLE_ID)"
