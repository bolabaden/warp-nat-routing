#!/bin/bash

set -e

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
"$SCRIPT_DIR/install-warp-service.sh"

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

print_success "WARP service setup complete!"
echo ""
print_status "Next steps:"
echo "  1. If you haven't set environment variables yet, do so now"
echo "  2. Test the service: sudo systemctl start warp"
echo "  3. Check status: sudo systemctl status warp"
echo "  4. View logs: sudo journalctl -u warp -f"
echo "  5. Enable on boot: sudo systemctl enable warp"
echo ""
print_status "For more information, see /usr/local/share/warp-docker-nat/SYSTEMD_SERVICE.md"
