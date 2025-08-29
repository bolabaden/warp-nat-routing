# WARP Configuration Guide

The WARP Docker NAT stack is configured through Docker Compose and environment variables, providing a clean and maintainable way to customize the network setup.

## Overview

The stack supports comprehensive configuration through:

- **Environment Variables** for WARP credentials and settings
- **Docker Compose** for service orchestration
- **Embedded Scripts** for network setup and validation
- **Health Checks** for monitoring service status

All parameters are validated for format, conflicts, and system compatibility before execution.

## Environment Variables

### WARP Configuration

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_LICENSE_KEY` | WARP Teams license key | (unset) | No |
| `WARP_TUNNEL_TOKEN` | WARP Teams tunnel token | (unset) | No |
| `GOST_SOCKS5_PORT` | SOCKS5 proxy port | `1080` | No |
| `GOST_ARGS` | Additional GOST arguments | `-L :1080` | No |
| `BETA_FIX_HOST_CONNECTIVITY` | Auto-fix host connectivity | `false` | No |

### Network Configuration

The network setup is handled automatically by the `warp-nat-setup.sh` script with these defaults:

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| Docker Network | `warp-nat-net` | Custom WARP network name |
| Veth Host Interface | `veth-warp-nat-host` | Host veth interface name |
| Host Veth IP | `169.254.100.1/30` | Host veth IP address |
| Container Veth IP | `169.254.100.2/30` | Container veth IP address |
| Routing Table | `warp-nat-routing` | Custom routing table name |

## Usage Examples

### Basic Setup (Free WARP)

```bash
# Start with default settings
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

### WARP Teams Setup

```bash
# Create .env file with credentials
cat > .env << EOF
WARP_LICENSE_KEY=your_license_key_here
WARP_TUNNEL_TOKEN=your_tunnel_token_here
EOF

# Start services
docker-compose up -d
```

### Custom SOCKS5 Port

```bash
# Set custom port
echo "GOST_SOCKS5_PORT=1081" >> .env

# Restart services
docker-compose down
docker-compose up -d
```

### Advanced GOST Configuration

```bash
# Custom GOST arguments
echo "GOST_ARGS=-L :1080 -L :8080" >> .env

# Restart services
docker-compose down
docker-compose up -d
```

## Docker Compose Services

### 1. warp-nat-gateway

The main WARP container with NAT enabled:

```yaml
services:
  warp-nat-gateway:
    # 🔹🔹 WARP in Docker (with NAT)🔹
    image: docker.io/caomingjun/warp:latest
    container_name: warp-nat-gateway
    hostname: warp-nat-gateway
    extra_hosts:
      - host.docker.internal:host-gateway
    expose:
      - ${GOST_SOCKS5_PORT:-1080}  # SOCKS5 proxy port
    # add removed rule back (https://github.com/opencontainers/runc/pull/3468)
    device_cgroup_rules:
      - 'c 10:200 rwm'
    cap_add:
      # Docker already have them, these are for podman users
      - MKNOD
      - AUDIT_WRITE
      # additional required cap for warp, both for podman and docker
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.all.accept_ra=2
    volumes:
      - warp-config-data:/var/lib/cloudflare-warp
    environment:
      BETA_FIX_HOST_CONNECTIVITY: false
      GOST_ARGS: ${GOST_ARGS:--L :${GOST_SOCKS5_PORT:-1080}}
      WARP_ENABLE_NAT: true
      WARP_LICENSE_KEY: ${WARP_LICENSE_KEY}
      WARP_SLEEP: 2  # The default is 2 seconds.
    restart: always
```

**Key Features:**
- **NAT Enabled**: `WARP_ENABLE_NAT=true` enables Layer 3 routing
- **Health Checks**: Monitors WARP connection status
- **Configurable Ports**: SOCKS5 proxy port via environment variables
- **Automatic Restart**: Always restarts on failure

### 2. warp_router

The init container that sets up network routing:

```yaml
services:
  warp_router:
    depends_on:
      warp-nat-gateway:
        condition: service_healthy
    build:
      context: .
      dockerfile: Dockerfile
    image: docker.io/bolabaden/warp-nat-routing:latest
    container_name: warp_router
    privileged: true
    network_mode: host
    configs:
      - source: warp-nat-setup.sh
        target: /usr/local/bin/warp-nat-setup.sh
        mode: 777
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /etc/iproute2/rt_tables:/etc/iproute2/rt_tables:rw
      - /proc:/proc:rw
    environment:
      DOCKER_HOST: unix:///var/run/docker.sock
      DOCKER_NETWORK_NAME: warp-nat-net
      WARP_CONTAINER_NAME: warp-nat-gateway
      HOST_VETH_IP: 169.254.100.1
      CONT_VETH_IP: 169.254.100.2
      ROUTING_TABLE: warp-nat-routing
      VETH_HOST: veth-warp  # 9 character maximum
    restart: no
```

**Key Features:**
- **Network Setup**: Runs `warp-nat-setup.sh` to configure routing
- **Host Network**: Uses host networking for system-level access
- **Privileged Mode**: Required for network operations
- **One-shot**: Runs once and exits after setup

### 3. Test Containers

Multiple test containers for validation:

```yaml
ip-checker-naked:      # Uses default network (baseline)
ip-checker-warp:       # Uses only WARP network
ip-checker-warp-multi-uses-warp:  # Both networks, WARP priority
ip-checker-warp-multi-ambiguous:  # Both networks, default priority
```

Details:

```yaml


  ip-checker-naked:
    # 🔹🔹 IP Checker Naked 🔹🔹
    # This is a service that checks the IP address of the container.
    # It uses the default network interface of the host.
    profiles:
      - testing
    build: &ip-checker-dockerfile
      dockerfile_inline: |
        FROM alpine:latest
        RUN apk add --no-cache curl ipcalc
    container_name: ip-checker-naked
    command: "/bin/sh -c 'while true; do echo \"$$(date): $$(curl -s ifconfig.me)\"; sleep 60; done'"
  ip-checker-warp:
    # 🔹🔹 IP Checker WARP 🔹🔹
    # This is a service that checks the IP address of the container.
    # It uses the WARP network interface.
    profiles:
      - testing
    build: *ip-checker-dockerfile
    container_name: ip-checker-warp
    networks:
      - warp-nat-net
    command: "/bin/sh -c 'while true; do echo \"$$(date): $$(curl -s ifconfig.me)\"; sleep 60; done'"
    healthcheck:
      test: [
        "CMD-SHELL",
        "sh -c \"if curl -s https://cloudflare.com/cdn-cgi/trace | grep -qE '^warp=on|warp=plus$'; then echo \\\"Cloudflare WARP is active.\\\" && exit 0; else echo \\\"Cloudflare WARP is not active.\\\" && exit 1; fi\""
      ]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: always
  ip-checker-warp-multi-ambiguous:
    # 🔹🔹 IP Checker WARP Multi Uses Public 🔹🔹
    # This is a service that checks the IP address of the container.
    # As shown, without `gw_priority` set the network chosen for the default route of this container uses some funky non-intuitive logic:
    # - Docker's default route uses the subnet of the last connected network, per old info.
    # - In Docker Compose, setting gw_priority to a high number, like 100, makes a network the default gateway.
    # - Default gateway depends on the order networks are connected, with the last one often becoming default.
    profiles:
      - testing
    build: *ip-checker-dockerfile
    container_name: ip-checker-warp-multi-uses-ambiguous
    networks:
      - warp-nat-net  # list order doesn't matter
      - public
    command: "/bin/sh -c 'while true; do echo \"$$(date): $$(curl -s ifconfig.me)\"; sleep 60; done'"
    restart: always
  ip-checker-warp-multi-uses-warp:
    # 🔹🔹 IP Checker WARP Multi Uses WARP 🔹🔹
    # This is a service that checks the IP address of the container.
    # `warp_network` gateway priority 1, higher than public, so warp will be used by default.
    profiles:
      - testing
    build: *ip-checker-dockerfile
    container_name: ip-checker-warp-multi-uses-warp
    networks:
      warp-nat-net:
        # Default gateway is set by the last connected network or by gw_priority (e.g., 100), with Docker using the last network by default unless gw_priority is specified.
        gw_priority: 1  # https://docs.docker.com/engine/network/#connecting-to-multiple-networks
      public: {}
    command: "/bin/sh -c 'while true; do echo \"$$(date): $$(curl -s ifconfig.me)\"; sleep 60; done'"
    healthcheck:
      test: [
        "CMD-SHELL",
        "sh -c \"if curl -s https://cloudflare.com/cdn-cgi/trace | grep -qE '^warp=on|warp=plus$'; then echo \\\"Cloudflare WARP is active.\\\" && exit 0; else echo \\\"Cloudflare WARP is not active.\\\" && exit 1; fi\""
      ]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
```

## Network Architecture

### Custom Docker Network

The stack creates a custom network with specific bridge settings:

```yaml
networks:
  warp-nat-net:
    external: true
    attachable: true
    driver_opts:
      com.docker.network.bridge.name: br_warp-nat-net
      com.docker.network.bridge.enable_ip_masquerade: "false"
```

**Key Settings:**
- **External Network**: Must be created before starting services
- **Custom Bridge Name**: `br_warp-nat-net` for easy identification
- **IP Masquerade Disabled**: Allows custom NAT control
- **Attachable**: Enables containers to join after creation

### Veth Pair Configuration

The `warp-nat-setup.sh` script creates a virtual ethernet pair:

1. **Host Interface**: `veth-warp-nat-host` (169.254.100.1/30)
2. **Container Interface**: `warp-nat-host-nat-cont` (169.254.100.2/30)
3. **Namespace Integration**: Container end moved to WARP container

### Routing Table Setup

Custom routing table `warp-nat-routing` with:

- **Source-based routing**: Traffic from WARP network uses custom table
- **Default gateway**: Routes via veth pair to WARP container
- **Network isolation**: Separates WARP traffic from host traffic

## Configuration Validation

### Automatic Validation

The setup script validates:

- **IP Address Format**: Valid IPv4 format and octet ranges
- **Interface Names**: Character restrictions and length limits
- **Network Conflicts**: Prevents overlapping subnets
- **Routing Table Availability**: Ensures unique table names
- **Docker Network Status**: Verifies network existence and configuration

### Manual Validation

```bash
# Check network status
docker network ls | grep warp
docker network inspect warp-nat-net

# Verify routing
ip route show table warp-nat-routing
ip rule show | grep warp

# Check interfaces
ip link show | grep veth
ip addr show | grep 169.254.100

# Validate NAT rules
sudo iptables -t nat -L | grep warp
```

## Troubleshooting

### Common Configuration Issues

1. **Environment Variables Not Set**

   ```bash
   # Check current environment
   docker-compose config
   
   # Verify .env file
   cat .env
   
   # Check container environment
   docker exec warp-nat-gateway env | grep WARP
   ```

2. **Network Creation Fails**

   ```bash
   # Check router logs
   docker-compose logs warp_router
   
   # Verify network exists
   docker network ls | grep warp
   
   # Recreate network if needed
   sudo ./recreate_warp_docker_network.sh
   ```

3. **Routing Issues**

   ```bash
   # Check routing table
   ip route show table warp-nat-routing
   
   # Verify veth interfaces
   ip link show veth-warp-nat-host
   
   # Check container connectivity
   docker exec warp-nat-gateway ping -c 3 169.254.100.1
   ```

### Debug Configuration

```bash
# Enable debug logging
docker-compose logs -f warp_router
docker-compose logs -f warp-nat-gateway

# Check container configuration
docker inspect warp-nat-gateway | jq '.Config.Env'
docker inspect warp_router | jq '.Config.Cmd'

# Verify network setup
docker exec warp_router ip route show table warp-nat-routing
docker exec warp_router iptables -t nat -L
```

## Advanced Configuration

### Custom Network Names

To use custom network names, modify the compose file:

```yaml
networks:
  my-warp-network:
    external: true
    attachable: true
    driver_opts:
      com.docker.network.bridge.name: br_my-warp-network
      com.docker.network.bridge.enable_ip_masquerade: "false"

services:
  warp_router:
    environment:
      DOCKER_NETWORK_NAME: my-warp-network
```

### Multiple WARP Instances

For multiple WARP instances, create separate compose files:

```yaml
# docker-compose.warp1.yml
services:
  warp-nat-gateway-1:
    container_name: warp-nat-gateway-1
    environment:
      WARP_LICENSE_KEY: ${WARP1_LICENSE_KEY}
  warp_router_1:
    container_name: warp_router_1
    environment:
      WARP_CONTAINER_NAME: warp-nat-gateway-1
      DOCKER_NETWORK_NAME: warp-nat-net-1

# docker-compose.warp2.yml
services:
  warp-nat-gateway-2:
    container_name: warp-nat-gateway-2
    environment:
      WARP_LICENSE_KEY: ${WARP2_LICENSE_KEY}
  warp_router_2:
    container_name: warp_router_2
    environment:
      WARP_CONTAINER_NAME: warp-nat-gateway-2
      DOCKER_NETWORK_NAME: warp-nat-net-2
```

### Custom Veth IP Ranges

Modify the router environment variables:

```yaml
services:
  warp_router:
    environment:
      HOST_VETH_IP: 169.254.200.1
      CONT_VETH_IP: 169.254.200.2
      VETH_HOST: veth-warp-custom
```

## Best Practices

### Security

- **Use .env files**: Keep credentials out of version control
- **Limit privileges**: Only grant necessary capabilities
- **Network isolation**: Separate WARP traffic from host traffic
- **Regular updates**: Keep WARP image updated

### Performance

- **Health checks**: Monitor service status automatically
- **Resource limits**: Set appropriate memory and CPU limits
- **Network optimization**: Use appropriate MTU settings
- **Logging**: Configure appropriate log levels

### Maintenance

- **Regular testing**: Use test containers to validate routing
- **Backup configuration**: Keep .env files backed up
- **Documentation**: Document custom configurations
- **Monitoring**: Set up alerts for service failures

## Configuration Summary

After successful execution, the stack provides:

- **WARP Container**: Running with NAT enabled
- **Custom Network**: `warp-nat-net` for WARP-routed containers
- **Routing Setup**: Custom routing table and rules
- **Test Containers**: Validation of routing configuration
- **Health Monitoring**: Automatic health checks and restart

The configuration is managed entirely through Docker Compose and environment variables, providing a clean, maintainable, and scalable solution for WARP Docker NAT routing.
