#!/bin/bash

set -xe

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_status "Setting up WARP systemd service..."

# Get the current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install the service
print_status "Installing service..."
#!/bin/bash

set -xe

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_status "Installing WARP systemd service..."

# Get the current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/warp.service"
SERVICE_NAME="warp.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

# Check if service file exists
if [[ ! -f "$SERVICE_FILE" ]]; then
    print_error "Service file not found: $SERVICE_FILE"
    exit 1
fi

# Check if warp-up.sh and warp-down.sh exist
if [[ ! -f "$SCRIPT_DIR/warp-up.sh" ]]; then
    print_error "warp-up.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/warp-down.sh" ]]; then
    print_error "warp-down.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Make scripts executable
print_status "Making scripts executable..."
chmod +x "$SCRIPT_DIR/warp-up.sh"
chmod +x "$SCRIPT_DIR/warp-down.sh"

# Copy scripts to /usr/local/bin
print_status "Installing scripts to /usr/local/bin..."
cp "$SCRIPT_DIR/warp-up.sh" /usr/local/bin/
cp "$SCRIPT_DIR/warp-down.sh" /usr/local/bin/
chmod +x /usr/local/bin/warp-up.sh
chmod +x /usr/local/bin/warp-down.sh

# Copy template and documentation to /usr/local/share
print_status "Installing templates and documentation to /usr/local/share/warp-docker-nat..."
mkdir -p /usr/local/share/warp-docker-nat
cp "$SCRIPT_DIR/warp.env.template" /usr/local/share/warp-docker-nat/
cp "$SCRIPT_DIR/README.md" /usr/local/share/warp-docker-nat/
cp "$SCRIPT_DIR/WARP_CONFIGURATION.md" /usr/local/share/warp-docker-nat/
cp "$SCRIPT_DIR/SYSTEMD_SERVICE.md" /usr/local/share/warp-docker-nat/

# Copy service file to systemd directory
print_status "Installing service file..."
cp "$SERVICE_FILE" "$SERVICE_PATH"

# Reload systemd daemon
print_status "Reloading systemd daemon..."
systemctl daemon-reload

# Enable the service
print_status "Enabling WARP service..."
systemctl enable "$SERVICE_NAME"

print_success "WARP service installed successfully!"
echo ""
print_status "Service information:"
echo "  Service file: $SERVICE_PATH"
echo "  Scripts location: /usr/local/bin"
echo "  Templates location: /usr/local/share/warp-docker-nat"
echo "  Service name: $SERVICE_NAME"
echo ""
print_status "Available commands:"
echo "  Start service:   systemctl start warp"
echo "  Stop service:    systemctl stop warp"
echo "  Restart service: systemctl restart warp"
echo "  Check status:    systemctl status warp"
echo "  View logs:       journalctl -u warp -f"
echo "  View recent logs: journalctl -u warp --since '1 hour ago'"
echo ""
print_warning "Before starting the service, note:"
echo "  1. WARP will run in free mode by default (no license key required)"
echo "  2. For WARP Teams features, set WARP_LICENSE_KEY and WARP_TUNNEL_TOKEN environment variables"
echo "  3. Edit $SERVICE_PATH to uncomment and set the environment variables"
echo "  4. Or create a separate environment file: /etc/systemd/system/warp.service.d/env.conf"
echo ""
print_status "To create an environment file for WARP Teams, run:"
echo "  mkdir -p /etc/systemd/system/warp.service.d"
echo "  cat > /etc/systemd/system/warp.service.d/env.conf << 'EOF'"
echo "  [Service]"
echo "  Environment=WARP_LICENSE_KEY=your_license_key_here"
echo "  Environment=WARP_TUNNEL_TOKEN=your_tunnel_token_here"
echo "  EOF"
echo "  systemctl daemon-reload"
echo ""
print_success "Installation complete!"

# Check if environment variables are provided
if [[ -n "$WARP_LICENSE_KEY" || -n "$WARP_TUNNEL_TOKEN" ]]; then
    print_status "Creating environment file with provided variables..."
    
    mkdir -p /etc/systemd/system/warp.service.d
    
    cat > /etc/systemd/system/warp.service.d/env.conf << EOF
[Service]
EOF
    
    if [[ -n "$WARP_LICENSE_KEY" ]]; then
        echo "Environment=WARP_LICENSE_KEY=$WARP_LICENSE_KEY" >> /etc/systemd/system/warp.service.d/env.conf
    fi
    
    if [[ -n "$WARP_TUNNEL_TOKEN" ]]; then
        echo "Environment=WARP_TUNNEL_TOKEN=$WARP_TUNNEL_TOKEN" >> /etc/systemd/system/warp.service.d/env.conf
    fi
    
    systemctl daemon-reload
    print_success "Environment file created with provided variables"
else
    print_warning "No environment variables provided - WARP will run in free mode"
    print_status "To set environment variables for WARP Teams, either:"
    echo "  1. Run this script with environment variables:"
    echo "     WARP_LICENSE_KEY=your_key WARP_TUNNEL_TOKEN=your_token sudo ./setup-warp-service.sh"
    echo ""
    echo "  2. Or manually create the environment file:"
    echo "     sudo mkdir -p /etc/systemd/system/warp.service.d"
    echo "     sudo cp /usr/local/share/warp-docker-nat/warp.env.template /etc/systemd/system/warp.service.d/env.conf"
    echo "     sudo nano /etc/systemd/system/warp.service.d/env.conf"
    echo "     sudo systemctl daemon-reload"
fi

echo "Starting WARP service..."
systemctl restart warp || true
systemctl enable warp || true
systemctl status warp || true

print_success "WARP service setup complete!"
echo ""
print_status "For more information, see /usr/local/share/warp-docker-nat/SYSTEMD_SERVICE.md"
