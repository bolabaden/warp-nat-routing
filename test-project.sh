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

echo "Testing WARP Docker NAT project..."
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "Docker is running"

# Check if bc is available
if ! command -v bc &>/dev/null; then
    print_error "'bc' command is required but not found. Please install it."
    exit 1
fi

print_success "'bc' command is available"

# Test warp-up.sh help
print_status "Testing warp-up.sh help..."
if ./warp-up.sh --help &>/dev/null; then
    print_success "warp-up.sh help works"
else
    print_error "warp-up.sh help failed"
    exit 1
fi

# Test validation
print_status "Testing validation with invalid IP..."
if ./warp-up.sh --host-ip 999.999.999.999 &>/dev/null; then
    print_error "Validation should have failed for invalid IP"
    exit 1
else
    print_success "Validation correctly rejected invalid IP"
fi

# Test warp-down.sh
print_status "Testing warp-down.sh..."
if ./warp-down.sh &>/dev/null; then
    print_success "warp-down.sh runs successfully"
else
    print_warning "warp-down.sh had issues (this might be normal if nothing is set up)"
fi

print_success "All basic tests passed!"
echo ""

print_status "Next steps:"
echo "  1. Install the service: sudo -E ./setup-warp-service.sh"
echo "  2. Start the service: sudo -E systemctl start warp"
echo "  3. Test with a container:"
echo "     docker build . --tag ip-checker-image && \\"
echo "     docker run -d \\"
echo "       --name ip-checker \\"
echo "       --hostname ip-checker \\"
echo "       --restart always \\"
echo "       --network name=warp-network \\"
echo "       ip-checker-image \\"
echo "       /bin/sh -c 'while true; do echo \"\$(date): \$(curl -s ifconfig.me)\"; sleep 60; done' && \\"
echo "     docker container logs ip-checker"
echo ""
echo "  4. Further Tests:"
echo ""
echo "     Multiple networks (publicnet takes priority):"
echo "     (docker container stop ip-checker || true) && \\"
echo "     (docker container rm ip-checker || true) && \\"
echo "     docker run -d \\"
echo "       --name ip-checker \\"
echo "       --hostname ip-checker \\"
echo "       --restart always \\"
echo "       --network name=warp-network \\"
echo "       --network publicnet \\"
echo "       ip-checker-image \\"
echo "       /bin/sh -c \"while true; do echo \\\"\$(date): \$(curl -s ifconfig.me)\\\"; sleep 60; done\" && \\"
echo "     docker container logs ip-checker"
echo ""
echo "     NOTE: Should return your public IP due to publicnet taking priority"
echo ""
echo "     WARP network with priority:"
echo "     (docker container stop ip-checker || true) && \\"
echo "     (docker container rm ip-checker || true) && \\"
echo "     docker run -d \\"
echo "       --name ip-checker \\"
echo "       --hostname ip-checker \\"
echo "       --restart always \\"
echo "       --network name=warp-network,gw-priority=1 \\"
echo "       --network publicnet \\"
echo "       ip-checker-image \\"
echo "       /bin/sh -c \"while true; do echo \\\"\$(date): \$(curl -s ifconfig.me)\\\"; sleep 60; done\" && \\"
echo "     docker container logs ip-checker"

print_status "For more information, see /usr/local/share/warp-docker-nat/README.md"
