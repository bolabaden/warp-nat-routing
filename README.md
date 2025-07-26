# WARP Docker NAT

A comprehensive solution for routing Docker container traffic through Cloudflare WARP using NAT (Network Address Translation) instead of the traditional SOCKS5 proxy approach.

## 🎯 Problem Solved

Traditional WARP Docker setups typically use SOCKS5 proxy on port 1080, which has limitations:

- **Split tunneling is nearly impossible** when WARP is installed on the host
- **Complex routing configuration** required for selective traffic routing
- **Limited Docker network integration** - most examples only show basic proxy usage
- **Difficult NAT setup** - hard to figure out how to route through specific Docker networks

This project solves these issues by:

- **Using NAT instead of SOCKS5** for seamless traffic routing
- **Proper Docker network integration** with custom routing tables
- **Split tunneling support** through selective network routing
- **Systemd service integration** for production deployment

## 🚀 Features

- **NAT-based routing** instead of SOCKS5 proxy
- **Configurable network parameters** via CLI arguments
- **Comprehensive validation** for all network configurations
- **Systemd service integration** with proper logging
- **Optional WARP Teams support** (works with free WARP too)
- **Automatic startup** on system boot
- **Production-ready** with security hardening

## 📋 Requirements

- **Linux** with systemd
- **Docker** daemon running
- **Root privileges** for network operations
- **`bc` command** for network calculations
- **Cloudflare WARP** (free or Teams)

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Docker        │    │   WARP          │    │   Internet      │
│   Container     │───▶│   Container     │───▶│   (via WARP)    │
│   (10.45.0.0/16)│    │   (NAT Gateway) │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │
         │              ┌─────────────────┐
         └──────────────│   Custom        │
                        │   Routing       │
                        │   Table         │
                        └─────────────────┘
```

## 🚀 Quick Start

### 1. Install the Service

```bash
cd warp-docker-nat
sudo ./setup-warp-service.sh
```

### 2. Start the Service

```bash
sudo systemctl start warp
sudo systemctl enable warp  # Enable on boot
```

### 3. Check Status

```bash
sudo systemctl status warp
sudo journalctl -u warp -f  # View real-time logs
```

### 4. Test with a Container

```bash
# Run a container on the WARP network
docker run --rm --network warp-network alpine:latest sh -c "curl -s ifconfig.me"
```

## 📁 Project Structure

```
warp-docker-nat/
├── README.md                    # This file
├── warp-up.sh                   # Main setup script with CLI arguments
├── warp-down.sh                 # Cleanup script
├── warp.service                 # Systemd service file
├── warp.env.template            # Environment variables template
├── setup-warp-service.sh        # Complete setup script
├── install-warp-service.sh      # Service installation script
├── test-warp-up.sh             # CLI argument testing
├── test-service.sh             # Service functionality testing
├── WARP_CONFIGURATION.md       # CLI configuration documentation
└── SYSTEMD_SERVICE.md          # Systemd service documentation
```

## ⚙️ Configuration

### CLI Arguments (warp-up.sh)

The script supports comprehensive CLI arguments for customization:

```bash
# Basic usage with defaults
sudo ./warp-up.sh

# Custom network configuration
sudo ./warp-up.sh --network-name my-warp --docker-net 192.168.100.0/24

# Custom IP addresses
sudo ./warp-up.sh --host-ip 169.254.200.1 --container-ip 169.254.200.2

# Multiple custom values
sudo ./warp-up.sh -n my-warp -d 192.168.100.0/24 -r mytable -h 169.254.200.1 -c 169.254.200.2
```

**Available Options:**

- `-n, --network-name` - Docker network name
- `-v, --veth-host` - Host veth interface name
- `-h, --host-ip` - Host veth IP address
- `-c, --container-ip` - Container veth IP address
- `-d, --docker-net` - Docker network CIDR
- `-r, --routing-table` - Routing table name

### Environment Variables (Optional)

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_LICENSE_KEY` | WARP Teams license key | (unset) | No |
| `WARP_TUNNEL_TOKEN` | WARP Teams tunnel token | (unset) | No |
| `WARP_SLEEP` | Sleep time for WARP container | `2` | No |
| `WARP_DISABLE_IPV6` | Disable IPv6 in WARP container | `1` | No |

**Note:** All environment variables are optional. WARP will run in free mode by default.

## 🔧 Service Management

### Basic Commands

```bash
# Start/Stop/Restart
sudo systemctl start warp
sudo systemctl stop warp
sudo systemctl restart warp

# Status and Logs
sudo systemctl status warp
sudo journalctl -u warp -f
sudo journalctl -u warp --since '1 hour ago'

# Enable/Disable on Boot
sudo systemctl enable warp
sudo systemctl disable warp
```

### Logging

```bash
# Real-time logs
sudo journalctl -u warp -f

# Recent logs with timestamps
sudo journalctl -u warp -o short-iso --since '1 hour ago'

# Error logs only
sudo journalctl -u warp -p err

# Service-specific logs
sudo journalctl -t warp-service
```

## 🛡️ Security Features

The systemd service includes several security features:

- **NoNewPrivileges**: Prevents privilege escalation
- **ProtectSystem**: Protects system directories
- **ProtectHome**: Protects home directories
- **ReadWritePaths**: Explicitly allows access to needed paths
- **AmbientCapabilities**: Grants necessary network capabilities

## 🔍 Validation Features

The enhanced `warp-up.sh` script includes comprehensive validation:

- **IP Address Validation**: Format checking, octet validation, conflict detection
- **CIDR Validation**: Format checking, prefix length validation, subnet overlap detection
- **Interface Name Validation**: Character restrictions, length limits, conflict checking
- **Docker Network Validation**: Uniqueness checking, conflict detection
- **Routing Table Validation**: Uniqueness checking, table number availability

## 📖 Usage Examples

### Basic Setup (Free WARP)

```bash
# Install and start with default settings
sudo ./setup-warp-service.sh
sudo systemctl start warp

# Test with a container
docker run --rm --network warp-network alpine:latest sh -c "curl -s ifconfig.me"
```

### Custom Network Configuration

```bash
# Use custom network settings
sudo ./warp-up.sh --network-name my-warp --docker-net 192.168.100.0/24

# Run containers on custom network
docker run --rm --network my-warp alpine:latest sh -c "curl -s ifconfig.me"
```

### WARP Teams Setup

```bash
# Install with Teams credentials
WARP_LICENSE_KEY=your_key WARP_TUNNEL_TOKEN=your_token sudo ./setup-warp-service.sh
sudo systemctl start warp
```

### Split Tunneling

```bash
# Route only specific containers through WARP
docker run --rm --network warp-network app1  # Goes through WARP
docker run --rm --network bridge app2        # Goes through normal internet
```

## 🐛 Troubleshooting

### Common Issues

1. **Service Fails to Start**

   ```bash
   sudo systemctl status warp
   sudo journalctl -u warp --since '5 minutes ago'
   ```

2. **Permission Denied**

   ```bash
   sudo systemctl show warp | grep User
   ls -la /path/to/warp-up.sh
   ```

3. **Network Issues**

   ```bash
   docker network ls | grep warp
   ip route show table warp
   sudo iptables -t nat -L | grep warp
   ```

4. **WARP Container Issues**

   ```bash
   docker logs warp
   docker exec warp warp-cli status
   ```

### Manual Testing

```bash
# Test CLI arguments
./test-warp-up.sh

# Test service functionality
./test-service.sh

# Test scripts directly
sudo ./warp-up.sh --help
sudo ./warp-down.sh
```

## 📚 Documentation

- **[WARP_CONFIGURATION.md](WARP_CONFIGURATION.md)** - Detailed CLI configuration guide
- **[SYSTEMD_SERVICE.md](SYSTEMD_SERVICE.md)** - Comprehensive systemd service documentation

**Note:** After installation, documentation is available at `/usr/local/share/warp-docker-nat/`

## 🔄 Uninstallation

To completely remove the service:

```bash
# Stop and disable service
sudo systemctl stop warp
sudo systemctl disable warp

# Remove service files
sudo rm /etc/systemd/system/warp.service
sudo rm -rf /etc/systemd/system/warp.service.d

# Remove installed scripts and files
sudo rm -f /usr/local/bin/warp-up.sh
sudo rm -f /usr/local/bin/warp-down.sh
sudo rm -rf /usr/local/share/warp-docker-nat

# Reload systemd
sudo systemctl daemon-reload
sudo systemctl reset-failed
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
- Systemd developers for service management
