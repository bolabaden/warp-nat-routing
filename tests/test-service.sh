#!/bin/bash

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

echo "Testing WARP systemd service functionality..."
echo ""

# Check if service file exists
if [[ -f "/etc/systemd/system/warp.service" ]]; then
    print_success "Service file found at /etc/systemd/system/warp.service"
else
    print_warning "Service file not found. Run: sudo ./install-warp-service.sh"
    exit 1
fi

# Check service status
print_status "Checking service status..."
if systemctl is-enabled warp >/dev/null 2>&1; then
    print_success "Service is enabled"
else
    print_warning "Service is not enabled. Run: sudo systemctl enable warp"
fi

# Check if service is active
if systemctl is-active warp >/dev/null 2>&1; then
    print_success "Service is active"
else
    print_warning "Service is not active"
fi

echo ""
print_status "Service information:"
systemctl show warp --property=Description,ExecStart,WorkingDirectory,User,Group | grep -E "(Description|ExecStart|WorkingDirectory|User|Group)"

echo ""
print_status "Recent logs (last 10 lines):"
journalctl -u warp -n 10 --no-pager

echo ""
print_status "Available commands:"
echo "  Check status:    systemctl status warp"
echo "  Start service:   systemctl start warp"
echo "  Stop service:    systemctl stop warp"
echo "  Restart service: systemctl restart warp"
echo "  View logs:       journalctl -u warp -f"
echo "  View all logs:   journalctl -u warp --no-pager"

echo ""
print_status "To test the service:"
echo "  1. Set environment variables (see /usr/local/share/warp-docker-nat/SYSTEMD_SERVICE.md)"
echo "  2. Start: sudo systemctl start warp"
echo "  3. Check status: sudo systemctl status warp"
echo "  4. View logs: sudo journalctl -u warp -f" 