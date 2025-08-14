#!/bin/bash

set -xe

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Default values
DEFAULT_DOCKER_NETWORK_NAME="warp-network"
DEFAULT_VETH_HOST="veth-warp-host"
DEFAULT_HOST_VETH_IP="169.254.100.1"
DEFAULT_CONT_VETH_IP="169.254.100.2"
DEFAULT_DOCKER_NET="10.45.0.0/16"
DEFAULT_ROUTING_TABLE="warp"

# Initialize variables with defaults
docker_network_name="$DEFAULT_DOCKER_NETWORK_NAME"
veth_host="$DEFAULT_VETH_HOST"
host_veth_ip="$DEFAULT_HOST_VETH_IP"
cont_veth_ip="$DEFAULT_CONT_VETH_IP"
docker_net="$DEFAULT_DOCKER_NET"
routing_table="$DEFAULT_ROUTING_TABLE"

# Track whether IPs were set by CLI arguments
host_ip_set_by_cli=false
cont_ip_set_by_cli=false

# Function to display usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -n, --network-name NAME     Docker network name (default: $DEFAULT_DOCKER_NETWORK_NAME)
    -v, --veth-host NAME        Host veth interface name (default: $DEFAULT_VETH_HOST)
    -h, --host-ip IP            Host veth IP address (default: $DEFAULT_HOST_VETH_IP)
    -c, --container-ip IP       Container veth IP address (default: $DEFAULT_CONT_VETH_IP)
    -d, --docker-net CIDR       Docker network CIDR (default: $DEFAULT_DOCKER_NET)
    -r, --routing-table NAME    Routing table name (default: $DEFAULT_ROUTING_TABLE)
    --help                      Show this help message

Examples:
    $0 --network-name my-warp --docker-net 192.168.100.0/24
    $0 -n my-warp -d 192.168.100.0/24 -r mytable
    $0 --host-ip 169.254.200.1 --container-ip 169.254.200.2

EOF
}

# Function to validate IP address format
validate_ip() {
    local ip="$1"
    local name="$2"
    
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Error: $name '$ip' is not a valid IPv4 address"
        exit 1
    fi
    
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
            echo "Error: $name '$ip' contains invalid octet: $octet"
            exit 1
        fi
    done
}

# Function to validate CIDR format
validate_cidr() {
    local cidr="$1"
    local name="$2"
    
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Error: $name '$cidr' is not a valid CIDR notation"
        exit 1
    fi
    
    local ip_part="${cidr%/*}"
    local prefix_part="${cidr#*/}"
    
    validate_ip "$ip_part" "$name IP part"
    
    if [[ "$prefix_part" -lt 0 || "$prefix_part" -gt 32 ]]; then
        echo "Error: $name '$cidr' has invalid prefix length: $prefix_part"
        exit 1
    fi
}

# Function to calculate network address from IP/CIDR
calculate_network() {
    local ip_cidr="$1"
    local ip="${ip_cidr%/*}"
    local prefix="${ip_cidr#*/}"
    
    # Convert IP to binary
    IFS='.' read -r -a octets <<< "$ip"
    local binary=""
    for octet in "${octets[@]}"; do
        binary+=$(printf "%08d" $(echo "obase=2; $octet" | bc))
    done
    
    # Apply netmask
    local network_binary="${binary:0:$prefix}$(printf '%0*d' $((32-prefix)) 0)"
    
    # Convert back to decimal
    local network=""
    for i in {0..3}; do
        local octet_binary="${network_binary:$((i*8)):8}"
        local octet_decimal=$(echo "ibase=2; $octet_binary" | bc)
        network+="$octet_decimal"
        [[ $i -lt 3 ]] && network+="."
    done
    
    echo "$network"
}

# Function to check if IP is already in use
check_ip_in_use() {
    local ip="$1"
    local name="$2"
    
    # Check if IP is already assigned to any interface
    if ip addr show | grep -q "inet $ip/"; then
        return 1  # IP is in use
    fi
    
    # Check if IP is in the same subnet as any existing interface
    local ip_network=$(calculate_network "$ip/30")
    for existing_ip in $(ip addr show | grep "inet " | awk '{print $2}' | cut -d/ -f1); do
        if [[ "$existing_ip" != "$ip" ]]; then
            local existing_network=$(calculate_network "$existing_ip/30")
            if [[ "$ip_network" == "$existing_network" ]]; then
                return 1  # IP conflicts with existing IP in same subnet
            fi
        fi
    done
    
    return 0  # IP is available
}

# Function to find an available IP in the same subnet
find_available_ip() {
    local base_ip="$1"
    local name="$2"
    
    # Extract the first three octets from the base IP
    IFS='.' read -r -a octets <<< "$base_ip"
    local base_prefix="${octets[0]}.${octets[1]}.${octets[2]}"
    
    # Try IPs in the range .1 to .254 in the same subnet
    for i in {1..254}; do
        local test_ip="$base_prefix.$i"
        
        # Skip the original IP if it's the same as base_ip
        if [[ "$test_ip" == "$base_ip" ]]; then
            continue
        fi
        
        # Check if this IP is available
        if check_ip_in_use "$test_ip" "$name" 2>/dev/null; then
            echo "$test_ip"
            return 0
        fi
    done
    
    # If no IP is available, return error
    echo "Error: No available IP found in subnet $base_prefix.0/24" >&2
    return 1
}

# Function to find an available IP pair in the same /30 subnet
find_available_ip_pair() {
    local base_host_ip="$1"
    local base_cont_ip="$2"
    
    # Extract the first three octets from the base IP
    IFS='.' read -r -a octets <<< "$base_host_ip"
    local base_prefix="${octets[0]}.${octets[1]}.${octets[2]}"
    
    # Try to find a /30 subnet (4 IPs) that has at least 2 available IPs
    for i in {0..63}; do  # 64 /30 subnets in a /24
        local subnet_start=$((i * 4))
        local host_ip="$base_prefix.$((subnet_start + 1))"
        local cont_ip="$base_prefix.$((subnet_start + 2))"
        
        # Skip if either IP is the same as the base IPs (to avoid conflicts)
        if [[ "$host_ip" == "$base_host_ip" || "$host_ip" == "$base_cont_ip" || 
              "$cont_ip" == "$base_host_ip" || "$cont_ip" == "$base_cont_ip" ]]; then
            continue
        fi
        
        # Check if both IPs are available
        if check_ip_in_use "$host_ip" "Host veth IP" 2>/dev/null && 
           check_ip_in_use "$cont_ip" "Container veth IP" 2>/dev/null; then
            echo "$host_ip $cont_ip"
            return 0
        fi
    done
    
    # If no pair is available, return error
    echo "Error: No available IP pair found in subnet $base_prefix.0/24" >&2
    return 1
}

# Function to find an available IP that's compatible with an existing IP
find_compatible_ip() {
    local existing_ip="$1"
    local name="$2"
    
    # Extract the first three octets from the existing IP
    IFS='.' read -r -a octets <<< "$existing_ip"
    local base_prefix="${octets[0]}.${octets[1]}.${octets[2]}"
    local existing_last_octet="${octets[3]}"
    
    # Find which /30 subnet the existing IP belongs to
    local subnet_start=$(( (existing_last_octet / 4) * 4 ))
    
    # Try to find an available IP in the same /30 subnet
    for i in {0..3}; do
        local test_ip="$base_prefix.$((subnet_start + i))"
        
        # Skip the existing IP and .0 (network address)
        if [[ "$test_ip" == "$existing_ip" || $((subnet_start + i)) -eq 0 ]]; then
            continue
        fi
        
        # Check if this IP is available
        if check_ip_in_use "$test_ip" "$name" 2>/dev/null; then
            echo "$test_ip"
            return 0
        fi
    done
    
    # If no IP in the same /30 subnet is available, try other /30 subnets
    for i in {0..63}; do
        local subnet_start=$((i * 4))
        for j in {1..2}; do  # Only try .1 and .2 in each /30 subnet
            local test_ip="$base_prefix.$((subnet_start + j))"
            
            # Skip if it's the same as existing IP
            if [[ "$test_ip" == "$existing_ip" ]]; then
                continue
            fi
            
            # Check if this IP is available
            if check_ip_in_use "$test_ip" "$name" 2>/dev/null; then
                echo "$test_ip"
                return 0
            fi
        done
    done
    
    # If no IP is available, return error
    echo "Error: No available compatible IP found in subnet $base_prefix.0/24" >&2
    return 1
}

# Function to check if interface name is already in use
check_interface_in_use() {
    local interface="$1"
    local name="$2"
    
    if ip link show "$interface" &>/dev/null; then
        echo "Error: $name '$interface' already exists"
        exit 1
    fi
}

# Function to check if Docker network already exists
check_docker_network_exists() {
    local network="$1"
    
    if docker network inspect "$network" || true &>/dev/null; then
        echo "Error: Docker network '$network' already exists"
        exit 1
    fi
}

# Function to check if routing table already exists
check_routing_table_exists() {
    local table="$1"
    
    if grep -q "^[0-9]\+ $table$" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "Error: Routing table '$table' already exists in /etc/iproute2/rt_tables"
        exit 1
    fi
    
    # Also check if table number 110 is already used
    if grep -q "^110 " /etc/iproute2/rt_tables 2>/dev/null; then
        echo "Error: Routing table number 110 is already in use"
        exit 1
    fi
}

# Function to calculate broadcast address from IP/CIDR
calculate_broadcast() {
    local ip_cidr="$1"
    local ip="${ip_cidr%/*}"
    local prefix="${ip_cidr#*/}"
    
    # Convert IP to binary
    IFS='.' read -r -a octets <<< "$ip"
    local binary=""
    for octet in "${octets[@]}"; do
        binary+=$(printf "%08d" $(echo "obase=2; $octet" | bc))
    done
    
    # Apply netmask and set host bits to 1
    local broadcast_binary="${binary:0:$prefix}$(printf '%0*d' $((32-prefix)) 1)"
    
    # Convert back to decimal
    local broadcast=""
    for i in {0..3}; do
        local octet_binary="${broadcast_binary:$((i*8)):8}"
        local octet_decimal=$(echo "ibase=2; $octet_binary" | bc)
        broadcast+="$octet_decimal"
        [[ $i -lt 3 ]] && broadcast+="."
    done
    
    echo "$broadcast"
}

# Function to check if CIDR conflicts with existing Docker networks
check_docker_network_conflict() {
    local cidr="$1"
    
    # Get all Docker networks and their subnets
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local existing_cidr=$(echo "$line" | awk '{print $2}')
            if [[ "$existing_cidr" == "$cidr" ]]; then
                echo "Error: Docker network CIDR '$cidr' conflicts with existing network"
                exit 1
            fi
            
            # Check for subnet overlap
            local new_network=$(calculate_network "$cidr")
            local existing_network=$(calculate_network "$existing_cidr")
            local new_broadcast=$(calculate_broadcast "$cidr")
            local existing_broadcast=$(calculate_broadcast "$existing_cidr")
            
            if [[ "$new_network" < "$existing_broadcast" && "$new_broadcast" > "$existing_network" ]]; then
                echo "Error: Docker network CIDR '$cidr' overlaps with existing network '$existing_cidr'"
                exit 1
            fi
        fi
    done < <(docker network ls --format "table {{.Name}}\t{{.Subnet}}" | tail -n +2)
}

# Function to validate interface name format
validate_interface_name() {
    local name="$1"
    local var_name="$2"
    
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: $var_name '$name' contains invalid characters. Use only letters, numbers, hyphens, and underscores"
        exit 1
    fi
    
    if [[ ${#name} -gt 15 ]]; then
        echo "Error: $var_name '$name' is too long (max 15 characters)"
        exit 1
    fi
}

# Function to validate routing table name
validate_routing_table_name() {
    local name="$1"
    
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Routing table name '$name' contains invalid characters. Use only letters, numbers, hyphens, and underscores"
        exit 1
    fi
    
    if [[ ${#name} -gt 15 ]]; then
        echo "Error: Routing table name '$name' is too long (max 15 characters)"
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--network-name)
            docker_network_name="$2"
            shift 2
            ;;
        -v|--veth-host)
            veth_host="$2"
            shift 2
            ;;
        -h|--host-ip)
            host_veth_ip="$2"
            host_ip_set_by_cli=true
            shift 2
            ;;
        -c|--container-ip)
            cont_veth_ip="$2"
            cont_ip_set_by_cli=true
            shift 2
            ;;
        -d|--docker-net)
            docker_net="$2"
            shift 2
            ;;
        -r|--routing-table)
            routing_table="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1"
            show_usage
            exit 1
            ;;
    esac
done

# Check for required commands
if ! command -v bc &>/dev/null; then
    echo "Error: 'bc' command is required but not found. Please install it."
    exit 1
fi

# Validate all inputs
echo "Validating configuration..."

# Validate interface names
validate_interface_name "$veth_host" "Veth host interface name"
validate_interface_name "$docker_network_name" "Docker network name"

# Validate derived interface name
validate_interface_name "${veth_host#veth-}-cont" "Veth container interface name"

# Validate routing table name
validate_routing_table_name "$routing_table"

# Validate IP addresses
validate_ip "$host_veth_ip" "Host veth IP"
validate_ip "$cont_veth_ip" "Container veth IP"

# Validate CIDR
validate_cidr "$docker_net" "Docker network CIDR"

# Check for conflicts
echo "Checking for conflicts..."

# Check if IPs are already in use and find alternatives if needed
host_ip_conflict=false
cont_ip_conflict=false

if ! check_ip_in_use "$host_veth_ip" "Host veth IP" 2>/dev/null; then
    if [[ "$host_ip_set_by_cli" == "false" ]]; then
        host_ip_conflict=true
    else
        echo "Error: Host veth IP '$host_veth_ip' is already assigned to an interface"
        exit 1
    fi
fi

if ! check_ip_in_use "$cont_veth_ip" "Container veth IP" 2>/dev/null; then
    if [[ "$cont_ip_set_by_cli" == "false" ]]; then
        cont_ip_conflict=true
    else
        echo "Error: Container veth IP '$cont_veth_ip' is already assigned to an interface"
        exit 1
    fi
fi

# If both IPs are defaults and have conflicts, find a new pair
if [[ "$host_ip_conflict" == "true" && "$cont_ip_conflict" == "true" && 
      "$host_ip_set_by_cli" == "false" && "$cont_ip_set_by_cli" == "false" ]]; then
    echo "Both default IPs are in use, finding alternative IP pair..."
    new_ip_pair=$(find_available_ip_pair "$host_veth_ip" "$cont_veth_ip")
    if [[ $? -eq 0 ]]; then
        read -r new_host_ip new_cont_ip <<< "$new_ip_pair"
        host_veth_ip="$new_host_ip"
        cont_veth_ip="$new_cont_ip"
        echo "Using alternative IP pair: Host=$host_veth_ip, Container=$cont_veth_ip"
    else
        echo "$new_ip_pair"
        exit 1
    fi
# If only host IP has conflict and it's a default
elif [[ "$host_ip_conflict" == "true" && "$host_ip_set_by_cli" == "false" ]]; then
    echo "Host veth IP $host_veth_ip is already in use, finding compatible alternative..."
    new_host_ip=$(find_compatible_ip "$cont_veth_ip" "Host veth IP")
    if [[ $? -eq 0 ]]; then
        host_veth_ip="$new_host_ip"
        echo "Using alternative host veth IP: $host_veth_ip"
    else
        echo "$new_host_ip"
        exit 1
    fi
# If only container IP has conflict and it's a default
elif [[ "$cont_ip_conflict" == "true" && "$cont_ip_set_by_cli" == "false" ]]; then
    echo "Container veth IP $cont_veth_ip is already in use, finding compatible alternative..."
    new_cont_ip=$(find_compatible_ip "$host_veth_ip" "Container veth IP")
    if [[ $? -eq 0 ]]; then
        cont_veth_ip="$new_cont_ip"
        echo "Using alternative container veth IP: $cont_veth_ip"
    else
        echo "$new_cont_ip"
        exit 1
    fi
fi

# Ensure host and container IPs are in the same subnet and don't conflict
host_network=$(calculate_network "$host_veth_ip/30")
cont_network=$(calculate_network "$cont_veth_ip/30")

if [[ "$host_network" != "$cont_network" ]]; then
    echo "Error: Host veth IP ($host_veth_ip) and Container veth IP ($cont_veth_ip) must be in the same /30 subnet"
    exit 1
fi

if [[ "$host_veth_ip" == "$cont_veth_ip" ]]; then
    echo "Error: Host veth IP and Container veth IP cannot be the same"
    exit 1
fi

# Check if interfaces already exist
check_interface_in_use "$veth_host" "Veth host interface"
check_interface_in_use "${veth_host#veth-}-cont" "Veth container interface"

# Check if Docker network already exists
#check_docker_network_exists "$docker_network_name"

# Check if routing table already exists
#check_routing_table_exists "$routing_table"

# Check for Docker network CIDR conflicts
check_docker_network_conflict "$docker_net"

if ! command -v bc &>/dev/null; then
    echo "Error: 'bc' command is required but not found, installing now..."
    apt-get update && apt-get install -y bc
    if ! command -v bc &>/dev/null; then
        echo "Error: 'bc' command installation failed"
        exit 1
    else
        echo "✅ 'bc' command installed"
    fi
fi

echo "✅ All validations passed"

# Set derived variables
docker_bridge="br_${docker_network_name}"
# Generate container veth name properly - remove 'veth-' prefix and add '-cont' suffix
veth_container="${veth_host#veth-}-cont"

echo "Using interface names:"
echo "  Host veth: $veth_host"
echo "  Container veth: $veth_container"

# Run warp-down.sh first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/warp-down.sh"

set -xe

docker volume create warp-config-data || true 2>/dev/null
docker container stop warp || true 2>/dev/null
docker container rm warp || true 2>/dev/null

# Build docker run command with optional environment variables
docker_run_cmd="docker run --detach \
    --name warp \
    --device-cgroup-rule 'c 10:200 rwm' \
    -e WARP_SLEEP=\"\${WARP_SLEEP:-2}\" \
    -e WARP_ENABLE_NAT=1"

# Add optional license key if provided
if [[ -n "${WARP_LICENSE_KEY}" ]]; then
    docker_run_cmd="$docker_run_cmd -e WARP_LICENSE_KEY=\"${WARP_LICENSE_KEY}\""
fi

# Add optional tunnel token if provided
if [[ -n "${WARP_TUNNEL_TOKEN}" ]]; then
    docker_run_cmd="$docker_run_cmd -e TUNNEL_TOKEN=\"${WARP_TUNNEL_TOKEN}\""
fi

# Complete the docker run command
docker_run_cmd="$docker_run_cmd --cap-add MKNOD \
    --cap-add AUDIT_WRITE \
    --cap-add NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=\"\${WARP_DISABLE_IPV6:-1}\" \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv6.conf.all.accept_ra=2 \
    -v warp-config-data:/var/lib/cloudflare-warp \
    --restart always caomingjun/warp:latest"

# Execute the docker run command
eval $docker_run_cmd

warp_ip=$(docker container inspect warp --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "Warp IP detected: $warp_ip"

if [ -z "$warp_ip" ]; then
    echo "Error: Could not get IP of warp container (docker container inspect warp --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' failed)"
    exit 1
fi

# Create warp-network if missing
if ! docker network inspect $docker_network_name >/dev/null 2>&1; then
    docker network create --driver=bridge --subnet $docker_net --gateway ${docker_net%.*}.1 \
        -o com.docker.network.bridge.name=$docker_bridge $docker_network_name
fi

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Create veth pair if not already created
if ! ip link show $veth_host &>/dev/null; then
    echo "Creating veth pair: $veth_host <-> $veth_container"
    ip link add $veth_host type veth peer name $veth_container
fi

# Move one end to warp container
pid=$(docker inspect -f '{{.State.Pid}}' warp)
if [ -z "$pid" ]; then
    echo "Error: Could not get PID of warp container"
    exit 1
fi

# Move veth into container namespace
ip link set $veth_container netns $pid

# Assign IPs
ip addr add ${host_veth_ip}/30 dev $veth_host || true
ip link set $veth_host up

# Inside container: assign IP and bring up
nsenter -t $pid -n ip addr add ${cont_veth_ip}/30 dev $veth_container || true
nsenter -t $pid -n ip link set $veth_container up

# Enable forwarding inside container
nsenter -t $pid -n sysctl -w net.ipv4.ip_forward=1

# Set up NAT inside container (assuming warp is configured to use this IP)
nsenter -t $pid -n iptables -t nat -C POSTROUTING -s $docker_net -j MASQUERADE 2>/dev/null || \
nsenter -t $pid -n iptables -t nat -A POSTROUTING -s $docker_net -j MASQUERADE

# Set up custom routing table
if ! grep -q "110 $routing_table" /etc/iproute2/rt_tables; then
    echo "110 $routing_table" >> /etc/iproute2/rt_tables
fi

# Flush old rules
ip rule del from $docker_net table $routing_table 2>/dev/null || true
ip rule add from $docker_net table $routing_table

# Ensure the routing table exists before trying to flush it
if ! ip route show table $routing_table &>/dev/null; then
    # Create the table by adding a temporary route and then removing it
    ip route add unreachable default table $routing_table 2>/dev/null || true
    ip route del unreachable default table $routing_table 2>/dev/null || true
fi

ip route flush table $routing_table
ip route add $docker_net dev $docker_bridge table $routing_table
ip route add default via $cont_veth_ip dev $veth_host table $routing_table

# Add NAT on the host for the warp network
iptables -t nat -C POSTROUTING -s $docker_net ! -d $docker_net -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s $docker_net ! -d $docker_net -j MASQUERADE

# Setup forwarding
local_interface=$(ip route | grep default | awk '{print $5}' | head -1)

iptables -C FORWARD -i $docker_bridge -o $local_interface -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i $docker_bridge -o $local_interface -j ACCEPT

iptables -C FORWARD -o $docker_bridge -i $local_interface -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -o $docker_bridge -i $local_interface -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "✅ Routing from $docker_net through warp container using veth gateway $cont_veth_ip is set up"
echo "📋 Configuration used:"
echo "   Docker network: $docker_network_name"
echo "   Veth host interface: $veth_host"
echo "   Host veth IP: $host_veth_ip"
echo "   Container veth IP: $cont_veth_ip"
echo "   Docker network CIDR: $docker_net"
echo "   Routing table: $routing_table"
