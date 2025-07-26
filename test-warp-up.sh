#!/bin/bash

echo "Testing warp-up.sh with different configurations..."

echo ""
echo "1. Testing with default values:"
echo "   ./warp-up.sh"
echo "   (This would use all default values)"

echo ""
echo "2. Testing with custom network name:"
echo "   ./warp-up.sh --network-name my-warp-network"
echo "   (This would create a Docker network named 'my-warp-network')"

echo ""
echo "3. Testing with custom IP addresses:"
echo "   ./warp-up.sh --host-ip 169.254.200.1 --container-ip 169.254.200.2"
echo "   (This would use custom veth IP addresses)"

echo ""
echo "4. Testing with custom Docker network CIDR:"
echo "   ./warp-up.sh --docker-net 192.168.100.0/24"
echo "   (This would create a Docker network with CIDR 192.168.100.0/24)"

echo ""
echo "5. Testing with custom routing table:"
echo "   ./warp-up.sh --routing-table mytable"
echo "   (This would use 'mytable' as the routing table name)"

echo ""
echo "6. Testing with multiple custom values:"
echo "   ./warp-up.sh -n my-warp -d 192.168.100.0/24 -r mytable -h 169.254.200.1 -c 169.254.200.2"
echo "   (This would set all custom values at once)"

echo ""
echo "7. Testing help:"
echo "   ./warp-up.sh --help"
echo "   (This would show the usage information)"

echo ""
echo "Note: All commands require sudo privileges and will validate:"
echo "- IP address format and conflicts"
echo "- Interface name format and conflicts"
echo "- Docker network name conflicts"
echo "- Routing table name conflicts"
echo "- CIDR format and subnet overlaps"
echo "- Required system commands (bc)" 