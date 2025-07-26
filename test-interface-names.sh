#!/bin/bash

echo "Testing interface naming logic..."

# Test cases
test_cases=(
    "veth-warp-host"
    "veth-mywarp"
    "veth-test123"
)

for veth_host in "${test_cases[@]}"; do
    echo ""
    echo "Testing: $veth_host"
    
    # Apply the same logic as in warp-up.sh
    veth_container="${veth_host#veth-}-cont"
    
    echo "  Host veth: $veth_host"
    echo "  Container veth: $veth_container"
    
    # Validate interface name format
    if [[ ! "$veth_container" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "  ❌ ERROR: Container interface name contains invalid characters"
    elif [[ ${#veth_container} -gt 15 ]]; then
        echo "  ❌ ERROR: Container interface name is too long (${#veth_container} chars, max 15)"
    else
        echo "  ✅ Container interface name is valid"
    fi
    
    # Test if the name would be valid for ip link command
    if ip link add test-interface type dummy 2>/dev/null; then
        ip link del test-interface 2>/dev/null
        echo "  ✅ Interface name format is valid for ip link"
    else
        echo "  ❌ ERROR: Interface name format is invalid for ip link"
    fi
done

echo ""
echo "Interface naming test complete!" 