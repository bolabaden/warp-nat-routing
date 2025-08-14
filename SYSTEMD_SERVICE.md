# WARP Systemd Service

This document describes the systemd service for the Cloudflare WARP network setup.

## Overview

The `warp.service` is a systemd service that manages the Cloudflare WARP network configuration. It provides:

- Automatic startup on boot
- Proper logging to systemd journal
- Clean startup and shutdown procedures
- Service status monitoring

## Installation

### Quick Install

```bash
sudo ./install-warp-service.sh
```

### Manual Install

1. Copy the service file:

   ```bash
   sudo cp warp.service /etc/systemd/system/
   ```

2. Copy scripts to system directories:

   ```bash
   sudo cp warp-up.sh /usr/local/bin/
   sudo cp warp-down.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/warp-up.sh
   sudo chmod +x /usr/local/bin/warp-down.sh
   ```

3. Reload systemd and enable:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable warp
   ```

## Configuration

### Environment Variables

The service supports the following environment variables:

**Note:** All environment variables are optional. WARP will run in free mode by default.

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WARP_SLEEP` | Sleep time for WARP container | `2` | No |
| `WARP_DISABLE_IPV6` | Disable IPv6 in WARP container | `1` | No |
| `WARP_LICENSE_KEY` | Your WARP license key | (unset) | No |
| `WARP_TUNNEL_TOKEN` | Your WARP tunnel token | (unset) | No |

### Setting Environment Variables

#### Method 1: Edit Service File

```bash
sudo nano /etc/systemd/system/warp.service
```

Uncomment and set the environment variables:

```ini
Environment=WARP_LICENSE_KEY=your_license_key_here
Environment=WARP_TUNNEL_TOKEN=your_tunnel_token_here
```

#### Method 2: Environment File (Recommended)

```bash
sudo mkdir -p /etc/systemd/system/warp.service.d
sudo nano /etc/systemd/system/warp.service.d/env.conf
```

Add:

```ini
[Service]
Environment=WARP_LICENSE_KEY=your_license_key_here
Environment=WARP_TUNNEL_TOKEN=your_tunnel_token_here
```

Then reload:

```bash
sudo systemctl daemon-reload
```

## Service Management

### Basic Commands

```bash
# Start the service
sudo systemctl start warp

# Stop the service
sudo systemctl stop warp

# Restart the service
sudo systemctl restart warp

# Check service status
sudo systemctl status warp

# Enable service on boot
sudo systemctl enable warp

# Disable service on boot
sudo systemctl disable warp
```

### Logging and Monitoring

#### View Service Status

```bash
sudo systemctl status warp
```

#### View Real-time Logs

```bash
sudo journalctl -u warp -f
```

#### View Recent Logs

```bash
# Last 100 lines
sudo journalctl -u warp -n 100

# Last hour
sudo journalctl -u warp --since '1 hour ago'

# Today
sudo journalctl -u warp --since today

# Specific time range
sudo journalctl -u warp --since '2024-01-01 10:00:00' --until '2024-01-01 11:00:00'
```

#### View Logs with Timestamps

```bash
sudo journalctl -u warp -o short-iso
```

#### Filter Logs by Priority

```bash
# Only errors
sudo journalctl -u warp -p err

# Errors and warnings
sudo journalctl -u warp -p warning
```

#### View Logs with Service Name

```bash
sudo journalctl -t warp-service
```

## Service Details

### Service Type

- **Type**: `oneshot`
- **RemainAfterExit**: `yes`

This means the service runs once and exits, but systemd considers it "active" after successful completion.

### Dependencies

- `docker.service` - Required
- `network-online.target` - Wanted

### Security Features

- `NoNewPrivileges=true` - Prevents privilege escalation
- `ProtectSystem=strict` - Protects system directories
- `ProtectHome=true` - Protects home directories
- `ReadWritePaths` - Explicitly allows access to needed paths
- `AmbientCapabilities` - Grants necessary network capabilities

### Timeouts

- `TimeoutStartSec=300` - 5 minutes to start
- `TimeoutStopSec=60` - 1 minute to stop

## Troubleshooting

### Common Issues

#### 1. Service Fails to Start

```bash
# Check detailed status
sudo systemctl status warp

# View startup logs
sudo journalctl -u warp --since '5 minutes ago'

# Check if Docker is running
sudo systemctl status docker
```

#### 2. Permission Denied

```bash
# Check if running as root
sudo systemctl show warp | grep User

# Check file permissions
ls -la /path/to/warp-up.sh
ls -la /path/to/warp-down.sh
```

#### 3. Environment Variables Not Set

```bash
# Check environment variables
sudo systemctl show warp | grep Environment

# Verify environment file
sudo cat /etc/systemd/system/warp.service.d/env.conf
```

#### 4. Network Issues

```bash
# Check if Docker network exists
docker network ls | grep warp

# Check routing tables
ip route show table warp

# Check iptables rules
sudo iptables -t nat -L | grep warp
```

### Debug Mode

To run the service in debug mode:

```bash
# Set debug logging
sudo systemctl set-environment WARP_DEBUG=1

# Restart service
sudo systemctl restart warp

# View debug logs
sudo journalctl -u warp -f
```

### Manual Testing

Test the scripts manually before using the service:

```bash
# Test warp-up.sh
sudo ./warp-up.sh

# Test warp-down.sh
sudo ./warp-down.sh
```

## Service File Structure

```ini
[Unit]
Description=Cloudflare WARP Network Service
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
Group=root

# Environment variables
Environment=WARP_SLEEP=2
Environment=WARP_DISABLE_IPV6=1

# Working directory
WorkingDirectory=/path/to/scripts

# Start command with logging
ExecStart=/bin/bash -c '...'

# Stop command with logging
ExecStop=/bin/bash -c '...'

# Reload command
ExecReload=/bin/bash -c '...'

# Security and capabilities
NoNewPrivileges=true
ProtectSystem=strict
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN

# Logging
StandardOutput=journal
StandardError=journal
LogLevelMax=debug

[Install]
WantedBy=multi-user.target
```

## Integration with Other Services

### Dependencies

If other services depend on WARP:

```ini
[Unit]
After=warp.service
Requires=warp.service
```

### Reverse Dependencies

To see what depends on WARP:

```bash
systemctl list-dependencies --reverse warp.service
```

## Monitoring and Alerts

### Health Check Script

Create a health check script:

```bash
#!/bin/bash
if ! systemctl is-active --quiet warp; then
    echo "WARP service is not running"
    exit 1
fi

if ! docker ps | grep -q warp; then
    echo "WARP container is not running"
    exit 1
fi

echo "WARP service is healthy"
exit 0
```

### Cron Job for Monitoring

```bash
# Add to crontab
*/5 * * * * /path/to/health-check.sh || systemctl restart warp
```

## Uninstallation

To remove the service:

```bash
# Stop and disable service
sudo systemctl stop warp
sudo systemctl disable warp

# Remove service file
sudo rm /etc/systemd/system/warp.service

# Remove environment file (if exists)
sudo rm -rf /etc/systemd/system/warp.service.d

# Remove installed scripts and files
sudo rm -f /usr/local/bin/warp-up.sh
sudo rm -f /usr/local/bin/warp-down.sh
sudo rm -rf /usr/local/share/warp-docker-nat

# Reload systemd
sudo systemctl daemon-reload

# Reset failed units
sudo systemctl reset-failed
```
