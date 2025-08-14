# WARP Configuration Guide

The `warp-up.sh` script has been enhanced with comprehensive CLI argument support and validation for all configurable network parameters.

## Overview

The script now supports command-line arguments to customize:

- Docker network name
- Veth interface names
- IP addresses for veth interfaces
- Docker network CIDR
- Routing table name

All parameters are validated for format, conflicts, and system compatibility before execution.

## Command Line Options

| Option | Long Option | Description | Default |
|--------|-------------|-------------|---------|
| `-n` | `--network-name` | Docker network name | `warp-network` |
| `-v` | `--veth-host` | Host veth interface name | `veth-warp-host` |
| `-h` | `--host-ip` | Host veth IP address | `169.254.100.1` |
| `-c` | `--container-ip` | Container veth IP address | `169.254.100.2` |
| `-d` | `--docker-net` | Docker network CIDR | `10.45.0.0/16` |
| `-r` | `--routing-table` | Routing table name | `warp` |
| | `--help` | Show help message | |

## Usage Examples

### Basic Usage (Default Values)

```bash
sudo ./warp-up.sh
```

### Custom Network Configuration

```bash
sudo ./warp-up.sh --network-name my-warp --docker-net 192.168.100.0/24
```

### Custom IP Addresses

```bash
sudo ./warp-up.sh --host-ip 169.254.200.1 --container-ip 169.254.200.2
```

### Custom Routing Table

```bash
sudo ./warp-up.sh --routing-table mytable
```

### Multiple Custom Values

```bash
sudo ./warp-up.sh -n my-warp -d 192.168.100.0/24 -r mytable -h 169.254.200.1 -c 169.254.200.2
```

## Validation Rules

### IP Address Validation

- Must be valid IPv4 format (x.x.x.x)
- Each octet must be 0-255
- Cannot conflict with existing interface IPs
- Cannot be in same subnet as existing interfaces

### CIDR Validation

- Must be valid CIDR notation (x.x.x.x/y)
- Prefix length must be 0-32
- Cannot conflict with existing Docker networks
- Cannot overlap with existing network subnets

### Interface Name Validation

- Must contain only letters, numbers, hyphens, and underscores
- Maximum 15 characters
- Cannot conflict with existing interfaces

### Docker Network Validation

- Network name must be unique
- Cannot conflict with existing Docker networks

### Routing Table Validation

- Table name must be unique in `/etc/iproute2/rt_tables`
- Table number 110 must be available
- Name must contain only letters, numbers, hyphens, and underscores

## System Requirements

- Root privileges (script checks for this)
- `bc` command available (for network calculations)
- Docker daemon running

## Configuration Summary

After successful execution, the script displays a summary of the configuration used:

```shell
✅ Routing from 10.45.0.0/16 through warp container using veth gateway 169.254.100.2 is set up
📋 Configuration used:
   Docker network: warp-network
   Veth host interface: veth-warp-host
   Host veth IP: 169.254.100.1
   Container veth IP: 169.254.100.2
   Docker network CIDR: 10.45.0.0/16
   Routing table: warp
```

## Troubleshooting

### Common Issues

1. **"Error: This script must be run as root"**
   - Solution: Run with `sudo ./warp-up.sh`

2. **"Error: 'bc' command is required but not found"**
   - Solution: Install bc: `apt-get install bc` (Ubuntu/Debian) or `yum install bc` (RHEL/CentOS)

3. **"Error: Docker network 'name' already exists"**
   - Solution: Use a different network name or remove the existing network

4. **"Error: Routing table 'name' already exists"**
   - Solution: Use a different routing table name or remove the existing table entry

5. **"Error: IP conflicts with existing interface"**
   - Solution: Choose different IP addresses that don't conflict

### Validation Testing

You can test the validation without running the full script by using the `--help` option:

```bash
sudo ./warp-up.sh --help
```

This will show all available options and examples without performing any network operations.
