# WARP Docker NAT

A comprehensive solution for routing Docker container traffic through Cloudflare WARP using NAT (Network Address Translation) instead of the traditional SOCKS5 proxy approach.

## 🎯 Problem Solved

Traditional WARP setups typically use SOCKS5 proxy on port 1080, which has limitations:

- **Split tunneling is nearly impossible** when WARP is installed on the host
- **Complex routing configuration** required for selective traffic routing
- **Limited Docker network integration** - most examples only show basic proxy usage
- **Difficult NAT setup** - hard to figure out how to route through specific Docker networks

This project solves these issues by:

- **Using NAT instead of SOCKS5** for seamless traffic routing
- **Proper Docker network integration** with custom routing tables
- **Split tunneling support** through selective network routing
- **Docker Compose integration** for easy deployment and management

## 🚀 Features

- **NAT-based routing** in addition to SOCKS5
- **Docker network created** that can be assigned to your containers
- **Fully configurable parameters** via environment variables
- **Comprehensive validation** for all network configurations
- **Docker Compose deployment** with health checks and monitoring
- **Automatic network setup** via init container
- **Self-healing monitor** - automatically retries setup on failures
- **Failsafe IP leak protection** - blocks traffic if routing setup fails
- **Multi-instance support** - run multiple isolated WARP instances
- **Zero-downtime updates** - non-destructive network management
- **Dynamic discovery** - no hardcoded values, all parameters auto-detected

## 🆕 Recent Improvements

### Architecture Enhancements

**Non-Destructive Network Management**
- Old behavior: Forcefully disconnected ALL containers, deleted network, recreated - causing service disruption
- New behavior: Discovers and uses existing networks without modifications
- Result: Zero downtime, true idempotency, no container disruption

**Failsafe IP Leak Protection**
- Implements iptables DROP rules during setup to prevent IP leaks if routing fails
- Rules are only removed after successful routing configuration
- Ensures real IP is never exposed even during setup failures

**Self-Healing Monitor**
- Continuously monitors WARP health via ephemeral container tests
- Automatically re-runs setup after configurable consecutive failures (default: 12)
- Prevents tight loops while ensuring eventual recovery

**Dynamic Discovery**
- No hardcoded bridge names - queries Docker for actual configuration
- Discovers network names using Compose naming patterns
- Verifies all discovered resources exist before proceeding
- Supports both explicit bridge names and Docker's default ID-based names

**Multi-Instance Support**
- All parameters (network names, routing tables, veth names, IPs) fully configurable
- Can run multiple independent WARP instances on same host
- Stack-aware naming prevents conflicts between Compose projects
- See `warp.env.template` for multi-instance configuration examples

**Surgical Cleanup**
- Removes only specific routes/rules it manages
- Checks existence before deletion
- No bulk operations that could affect other configurations
- Detailed logging of all changes

### Configuration Improvements

All parameters now configurable via environment variables:
- Network configuration (subnet, gateway, bridge name)
- Container names (for multiple instances)
- Routing parameters (table name, veth names, IPs)
- Monitoring behavior (retry intervals, sleep times)

See `warp.env.template` for complete list of configurable parameters.

## 📋 Requirements

- **Linux** with Docker and Docker Compose
- **Docker daemon** running
- **Root privileges** for network operations (when running setup scripts)
- **`bc` command** for network calculations
- **`curl` command** for health checks (provided in containers)
- **`jq` command** for JSON parsing (provided in containers)

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Docker        │    │   WARP          │    │   Internet      │
│   Container     │───▶│   Container     │───▶│   (via WARP)    │
│   (warp-nat-net)│    │   (NAT Gateway) │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │
         │              ┌─────────────────┐
         └──────────────│   Custom        │
                        │   Routing       │
                        │   Table         │
                        └─────────────────┘
```

## 🚀 Quick Start

### 1. Clone and Navigate

```bash
git clone <repository-url>
cd warp-nat-routing
```

**Available Environment Variables:**

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_LICENSE_KEY` | WARP Teams license key | (unset) | No |
| `WARP_TUNNEL_TOKEN` | WARP Teams tunnel token | (unset) | No |
| `GOST_SOCKS5_PORT` | SOCKS5 proxy port | `1080` | No |
| `GOST_ARGS` | Additional GOST arguments | `-L :1080` | No |

**Note:** All environment variables are optional. WARP will run in free mode by default.

### 2. Start the Stack

```bash
# Start all services
docker-compose up -d

# View logs
docker-compose logs -f
```

### 3. Check Status

```bash
# Check service status
docker-compose ps

# Check WARP container health
docker-compose logs warp-nat-gateway

# Check routing setup
docker-compose logs warp_router
```

### 4. Test with a Container

```bash
# Run a container on the WARP network
docker run --rm --network warp-nat-net alpine:latest sh -c "curl -s ifconfig.me"
```

## 📁 Project Structure

```
warp-nat-routing/
├── README.md                    # This file
├── docker-compose.yml           # Main Docker Compose configuration
├── warp-nat-setup.sh           # Network setup script (embedded in compose)
├── WARP_CONFIGURATION.md       # Configuration documentation
├── recreate_warp_docker_network.sh # Network recreation script
└── tests/                      # Test scripts
    ├── test-project.sh         # Project validation tests
    ├── test-warp-up.sh         # Configuration testing guide
    └── test-interface-names.sh # Interface naming tests
```

## ⚙️ Configuration

### Docker Compose Services

The stack consists of several services:

1. **`warp-nat-gateway`** - Main WARP container with NAT enabled
2. **`warp_router`** - Init container that sets up network routing
3. **`ip-checker-*`** - Test containers for validating routing

### Network Configuration

The `warp-nat-setup.sh` script (embedded in the compose file) handles:

- **Docker Network Creation**: Creates `warp-nat-net` with custom bridge settings
- **Veth Pair Setup**: Establishes virtual ethernet connection between host and WARP container
- **Routing Table Configuration**: Sets up custom routing table for WARP traffic
- **NAT Rules**: Configures iptables rules for proper traffic flow

### Environment Variables

#### WARP Configuration
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_LICENSE_KEY` | WARP Teams/WARP+ license key | (unset) | No |
| `WARP_TUNNEL_TOKEN` | WARP Teams tunnel token | (unset) | No |
| `GOST_SOCKS5_PORT` | SOCKS5 proxy port | `1080` | No |
| `GOST_ARGS` | Additional GOST arguments | `-L :1080` | No |
| `WARP_SLEEP` | WARP daemon startup time (seconds) | `2` | No |
| `BETA_FIX_HOST_CONNECTIVITY` | Auto-fix host connectivity | `false` | No |

#### Network Configuration
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DOCKER_NETWORK_NAME` | Docker network name | `warp-nat-net` | No |
| `WARP_NAT_NET_SUBNET` | Network subnet CIDR | `10.0.2.0/24` | No |
| `WARP_NAT_NET_GATEWAY` | Network gateway IP | `10.0.2.1` | No |

#### Container Names (for multiple instances)
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_CONTAINER_NAME` | WARP gateway container name | `warp-nat-gateway` | No |
| `ROUTER_CONTAINER_NAME` | Router container name | `warp_router` | No |

#### Routing Configuration
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `ROUTING_TABLE` | Custom routing table name | `warp-nat-routing` | No |
| `HOST_VETH_IP` | Host-side VETH IP address | `169.254.100.1` | No |
| `CONT_VETH_IP` | Container-side VETH IP address | `169.254.100.2` | No |
| `VETH_HOST` | VETH interface name (max 9 chars) | `veth-warp` | No |

#### Monitoring Configuration
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `RETRY_SETUP_AFTER` | Consecutive failures before retry | `12` | No |
| `SLEEP_INTERVAL` | Seconds between health checks | `5` | No |
| `CHECK_IMAGE` | Docker image for health checks | `curlimages/curl` | No |

#### Docker Configuration
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DOCKER_SOCKET` | Docker socket path | `/var/run/docker.sock` | No |
| `DOCKER_HOST` | Docker host URL | `unix:///var/run/docker.sock` | No |

For complete configuration examples including multi-instance setups, see `warp.env.template`.

## 🔧 Service Management

### Basic Commands

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# Restart specific service
docker-compose restart warp-nat-gateway

# View logs
docker-compose logs -f
docker-compose logs warp-nat-gateway
docker-compose logs warp_router

# Check status
docker-compose ps
```

### Network Management

```bash
# Recreate the WARP network (if needed)
sudo ./recreate_warp_docker_network.sh

# Check network status
docker network ls | grep warp
docker network inspect warp-nat-net

# Check routing tables
ip route show table warp-nat-routing
```

## 🔍 Validation Features

The stack includes comprehensive testing:

- **IP Checker Naked**: Uses default Docker network (baseline)
- **IP Checker WARP**: Uses only WARP network (should get WARP IP)
- **IP Checker Multi**: Connected to both networks for testing priority

### Testing Commands

```bash
# Check all test containers
docker-compose ps ip-checker-*

# View test results
docker-compose logs ip-checker-naked
docker-compose logs ip-checker-warp
docker-compose logs ip-checker-warp-multi-uses-warp

# Manual test
docker run --rm --network warp-nat-net alpine:latest sh -c "curl -s ifconfig.me"
```

## 📖 Usage Examples

### Basic Setup (Free WARP)

```bash
# Start with default settings
docker-compose up -d

# Test routing
docker run --rm --network warp-nat-net alpine:latest sh -c "curl -s ifconfig.me"
```

### WARP Teams Setup

```bash
# Create .env file with credentials
cat > .env << EOF
WARP_LICENSE_KEY=your_key_here
WARP_TUNNEL_TOKEN=your_token_here
EOF

# Start services
docker-compose up -d
```

### Split Tunneling

```bash
# Route only specific containers through WARP
docker run --rm --network warp-nat-net app1  # Goes through WARP
docker run --rm --network bridge app2        # Goes through normal internet

# Multi-network container (WARP priority)
docker run --rm \
  --network warp-nat-net \
  --network public \
  alpine:latest sh -c "curl -s ifconfig.me"
```

### Running Multiple WARP Instances

You can run multiple independent WARP instances on the same host for different purposes:

```bash
# Instance 1: US West Region (example)
cat > .env.warp1 << EOF
DOCKER_NETWORK_NAME=warp-nat-net-1
WARP_CONTAINER_NAME=warp-nat-gateway-1
ROUTER_CONTAINER_NAME=warp_router_1
ROUTING_TABLE=warp-nat-routing-1
VETH_HOST=veth-wrp1
HOST_VETH_IP=169.254.101.1
CONT_VETH_IP=169.254.101.2
WARP_NAT_NET_SUBNET=10.0.3.0/24
WARP_NAT_NET_GATEWAY=10.0.3.1
WARP_LICENSE_KEY=license_key_1
EOF

# Start instance 1
docker-compose --env-file .env.warp1 -p warp1 up -d

# Instance 2: EU Region (example)
cat > .env.warp2 << EOF
DOCKER_NETWORK_NAME=warp-nat-net-2
WARP_CONTAINER_NAME=warp-nat-gateway-2
ROUTER_CONTAINER_NAME=warp_router_2
ROUTING_TABLE=warp-nat-routing-2
VETH_HOST=veth-wrp2
HOST_VETH_IP=169.254.102.1
CONT_VETH_IP=169.254.102.2
WARP_NAT_NET_SUBNET=10.0.4.0/24
WARP_NAT_NET_GATEWAY=10.0.4.1
WARP_LICENSE_KEY=license_key_2
EOF

# Start instance 2
docker-compose --env-file .env.warp2 -p warp2 up -d

# Test each instance
docker run --rm --network warp-nat-net-1 alpine sh -c "curl -s ifconfig.me"
docker run --rm --network warp-nat-net-2 alpine sh -c "curl -s ifconfig.me"

# Stop specific instance
docker-compose --env-file .env.warp1 -p warp1 down
```

**Key Points for Multi-Instance Setup:**
- Each instance must have unique: network name, container names, routing table, veth name, IPs, subnet
- VETH interface names must be ≤15 characters (Linux limit)
- IP subnets must not overlap
- VETH IP addresses must be in different /30 subnets
- Each instance operates completely independently with its own routing

## 🐛 Troubleshooting

### Common Issues

1. **Network Setup Fails**

   ```bash
   # Check router logs
   docker-compose logs warp_router
   
   # Check WARP container status
   docker-compose logs warp-nat-gateway
   
   # Verify network exists
   docker network ls | grep warp
   ```

2. **Permission Denied**

   ```bash
   # Ensure running with proper privileges
   sudo docker-compose up -d
   
   # Check container capabilities
   docker inspect warp_router | grep -A 10 "CapAdd"
   ```

3. **Routing Issues**

   ```bash
   # Check routing table
   ip route show table warp-nat-routing
   
   # Check iptables rules
   sudo iptables -t nat -L | grep warp
   
   # Verify veth interfaces
   ip link show | grep veth
   ```

### Debug Mode

```bash
# View detailed logs
docker-compose logs -f warp_router
docker-compose logs -f warp-nat-gateway

# Check container network configuration
docker exec warp-nat-gateway ip route
docker exec warp-nat-gateway iptables -t nat -L

# Test connectivity
docker exec warp-nat-gateway ping -c 3 8.8.8.8
```

## 🔄 Network Recreation

If you need to recreate the WARP network:

```bash
# Use the provided script
sudo ./recreate_warp_docker_network.sh

# Or manually
docker-compose down
docker network rm warp-nat-net
docker-compose up -d
```

## 📚 Documentation

- **[WARP_CONFIGURATION.md](WARP_CONFIGURATION.md)** - Detailed configuration guide
- **Docker Compose documentation** - [Official docs](https://docs.docker.com/compose/)

## 🔄 Uninstallation

To completely remove the stack:

```bash
# Stop and remove all services
docker-compose down

# Remove networks
docker network rm warp-nat-net 2>/dev/null || true

# Remove volumes
docker volume rm warp-nat-routing_warp-config-data 2>/dev/null || true

# Clean up any remaining containers
docker container prune -f
```

## 🤝 Contributing

This project is designed to solve the specific problem of WARP Docker NAT routing. Contributions are welcome for:

- Bug fixes
- Additional validation rules
- Enhanced logging
- Security improvements
- Documentation updates

## 📄 License

This project is provided as-is for educational and operational purposes.

## 🙏 Acknowledgments

- Cloudflare for WARP
- Docker community for container networking
- The `caomingjun/warp` Docker image maintainers

---

## 🔄 WARP NAT Routing Flow

### 📊 Network Architecture Diagram

```mermaid
graph TB
    subgraph "Host System"
        subgraph "Docker Networks"
            BN["br_warp-nat-net<br/>Custom WARP Network"]
            BC["bridge<br/>Default Docker Network"]
        end
        
        subgraph "Veth Pair"
            VH["veth-warp-nat-host<br/>169.254.100.1/30"]
            VC["warp-nat-host-nat-cont<br/>169.254.100.2/30"]
        end
        
        subgraph "Routing Tables"
            RT["Custom Routing Table<br/>'warp-nat-routing'"]
        end
        
        subgraph "Host Interfaces"
            EI["Host's External Interface"]
        end
    end
    
    subgraph "WARP Container"
        WC["WARP Container<br/>caomingjun/warp:latest"]
        WN["Container eth0<br/>Default Docker Network"]
    end
    
    subgraph "Test Containers"
        TC1["ip-checker-naked<br/>Default Network"]
        TC2["ip-checker-warp<br/>WARP Network Only"]
        TC3["ip-checker-warp-multi<br/>Both Networks"]
    end
    
    subgraph "Internet"
        CF["Cloudflare WARP<br/>Tunnel Endpoint"]
        EX["External Services<br/>ifconfig.me, etc."]
    end
    
    %% Docker network connections
    BN --> VH
    VH <--> VC
    VC --> WC
    WC --> WN
    
    %% Test container connections
    TC1 --> BC
    TC2 --> BN
    TC3 --> BN
    TC3 --> BC
    
    %% Routing paths
    BN --> RT
    RT --> VH
    VH --> VC
    VC --> WC
    WC --> CF
    CF --> EX
    
    %% Alternative paths
    BC --> EI
    EI --> EX
    
    %% Styling
    classDef docker fill:#e1f5fe,stroke:#01579b,stroke-width:2px
    classDef warp fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef veth fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef routing fill:#e8f5e8,stroke:#1b5e20,stroke-width:2px
    classDef test fill:#fff8e1,stroke:#f57f17,stroke-width:2px
    classDef internet fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    
    class BN,BC docker
    class WC,CF warp
    class VH,VC veth
    class RT routing
    class TC1,TC2,TC3 test
    class EX,CF internet
```

### 🔍 Detailed Flow Explanation

#### **1. Network Setup Phase**

1. **WARP Container Launch**
   - Starts `caomingjun/warp:latest` with NAT enabled
   - Container gets default Docker network
   - WARP client initializes and establishes tunnel to Cloudflare

2. **Custom Docker Network Creation**
   - Creates `warp-nat-net` with bridge `br_warp-nat-net`
   - This network will be used by containers that should route through WARP

3. **Veth Pair Creation**
   - Creates virtual ethernet pair: `veth-warp-nat-host` ↔ `warp-nat-host-nat-cont`
   - Host side: `veth-warp-nat-host` (169.254.100.1/30)
   - Container side: `warp-nat-host-nat-cont` (169.254.100.2/30)
   - Moves container end into WARP container namespace

#### **2. Routing Configuration**

1. **Custom Routing Table**
   - Creates routing table `warp-nat-routing`
   - Routes traffic from WARP network through this table
   - Default route via `169.254.100.2` (container veth IP)

2. **Policy Routing Rules**
   - Forces traffic from WARP network through custom routing
   - Ensures proper traffic flow to WARP container

3. **NAT Configuration**
   - Host: NATs traffic from WARP network out external interface
   - Container: NATs traffic from WARP network through WARP tunnel

#### **3. Traffic Flow Paths**

##### **Path A: WARP Network Traffic**
```
Container (warp-nat-net) → br_warp-nat-net → veth-warp-nat-host → veth-warp-nat-host-nat-cont → WARP Container → Cloudflare WARP → Internet
```

##### **Path B: Default Network Traffic**
```
Container → bridge → Host External Interface → Internet (direct)
```

##### **Path C: Multi-Network Priority**
- **WARP Priority**: Traffic routes through WARP network first
- **Public Priority**: Traffic routes through default network first

#### **4. IP Testing & Validation**

The stack runs comprehensive tests to verify routing:

1. **IP Checker Naked** (`ip-checker-naked`)
   - Uses default Docker network
   - Should get host's public IP
   - Establishes baseline for comparison

2. **IP Checker WARP** (`ip-checker-warp`)
   - Uses only WARP network
   - Should get WARP tunnel's external IP
   - Must differ from baseline public IP

3. **IP Checker WARP Multi** (`ip-checker-warp-multi-uses-warp`)
   - Connected to both WARP and bridge networks
   - WARP has higher priority
   - Should get WARP external IP

#### **5. Key Technical Details**

##### **Veth Pair Function**
- **Host Side**: Acts as gateway for WARP network traffic
- **Container Side**: Receives traffic and forwards to WARP process
- **Bridging**: Connects Docker network to WARP container

##### **Routing Table Logic**
- **Source-based routing**: Traffic from WARP network uses custom table
- **Interface-based routing**: Traffic entering WARP network uses custom table
- **Default gateway**: Routes via veth pair to WARP container

##### **NAT Chain**
- **Host NAT**: Masquerades WARP network traffic out external interface
- **Container NAT**: Masquerades WARP network traffic through WARP tunnel
- **No double-NAT**: Traffic flows through one NAT point only

#### **6. Network Isolation Benefits**

1. **Selective Routing**: Only containers on `warp-nat-net` use WARP
2. **Split Tunneling**: Other containers use normal internet
3. **Network Separation**: WARP traffic isolated from host traffic
4. **Configurable**: Easy to add/remove containers from WARP routing

#### **7. Troubleshooting Points**

- **WARP Container Status**: Check `docker-compose logs warp-nat-gateway`
- **Routing Table**: Verify `ip route show table warp-nat-routing`
- **NAT Rules**: Check `iptables -t nat -L`
- **Veth Status**: Verify `ip link show veth-warp-nat-host`
- **Container Connectivity**: Test with `docker exec container ping 8.8.8.8`

This architecture provides a robust, scalable solution for routing Docker container traffic through Cloudflare WARP while maintaining network isolation and enabling split tunneling capabilities.
