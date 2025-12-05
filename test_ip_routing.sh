#!/bin/bash

set -x

echo "🔍 Testing IP routing configuration..."
RUN_TIMEOUT=${RUN_TIMEOUT:-45}
CURL_TIMEOUT=${CURL_TIMEOUT:-15}
DOCKER_NETWORK_NAME="warp-network"

# Function to check IP and determine if it's WARP or public
check_ip_type() {
    local ip="$1"
    local container_name="$2"
    local expected_behavior="$3"
    
    if [[ -z "$ip" ]]; then
        echo "❌ FAIL: $container_name - No IP address returned (timeout/error)"
        return 1
    fi
    
    # Check if IP is in private ranges (should never happen with ifconfig.me)
    if [[ "$ip" =~ ^(10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|169\.254\.) ]]; then
        echo "❌ FAIL: $container_name - Got private IP ($ip) instead of external IP"
        return 1
    fi
    
    # For all tests, we expect an external IP address
    # The key difference is which network path was used to reach the internet
    echo "✅ PASS: $container_name - Got external IP: $ip"
    return 0
}

# Function to run IP checker container and capture output
run_ip_checker() {
    local container_name="$1"
    local network_args="$2"
    local expected_behavior="$3"
    
    echo "🧪 Testing $container_name ($expected_behavior)..."
    
    docker rm -f $container_name 2>/dev/null || true
    
    local output
    local exit_code
    
    if [[ "$expected_behavior" == "multi_public" ]]; then
        timeout $RUN_TIMEOUT docker run -d --name $container_name --network bridge alpine:latest sh -c "sleep 3600" >/dev/null 2>&1
        docker exec $container_name sh -c "apk add --no-cache curl >/dev/null 2>&1" >/dev/null 2>&1
        docker network connect $DOCKER_NETWORK_NAME $container_name
        output=$(docker exec $container_name sh -c "curl -s --max-time $CURL_TIMEOUT ifconfig.me" 2>&1)
        exit_code=$?
        docker rm -f $container_name >/dev/null 2>&1 || true
    elif [[ "$expected_behavior" == "multi_warp" ]]; then
        timeout $RUN_TIMEOUT docker run -d --name $container_name --network $DOCKER_NETWORK_NAME alpine:latest sh -c "sleep 3600" >/dev/null 2>&1
        docker exec $container_name sh -c "apk add --no-cache curl >/dev/null 2>&1" >/dev/null 2>&1
        docker network connect bridge $container_name
        output=$(docker exec $container_name sh -c "curl -s --max-time $CURL_TIMEOUT ifconfig.me" 2>&1)
        exit_code=$?
        docker rm -f $container_name >/dev/null 2>&1 || true
    else
        if [[ -n "$network_args" ]]; then
            timeout $RUN_TIMEOUT docker run --rm --name $container_name $network_args --dns 1.1.1.1 --dns 8.8.8.8 alpine:latest sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -s --max-time $CURL_TIMEOUT ifconfig.me" | echo "no output/exit1 with no error"
            docker stop $container_name >/dev/null 2>&1 || true
            docker rm -f $container_name >/dev/null 2>&1 || true
            output=$(timeout $RUN_TIMEOUT docker run --rm --name $container_name $network_args --dns 1.1.1.1 --dns 8.8.8.8 alpine:latest sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -s --max-time $CURL_TIMEOUT ifconfig.me" 2>&1)
            exit_code=$?
        else
            timeout $RUN_TIMEOUT docker run --rm --name $container_name $network_args --dns 1.1.1.1 --dns 8.8.8.8 alpine:latest sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -s --max-time $CURL_TIMEOUT ifconfig.me" | echo "no output/exit1 with no error"
            docker stop $container_name >/dev/null 2>&1 || true
            docker rm -f $container_name >/dev/null 2>&1 || true
            output=$(timeout $RUN_TIMEOUT docker run --rm --name $container_name --dns 1.1.1.1 --dns 8.8.8.8 alpine:latest sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -s --max-time $CURL_TIMEOUT ifconfig.me" 2>&1)
            exit_code=$?
        fi
    fi
    
    if [[ $exit_code -eq 124 ]]; then
        echo "❌ FAIL: $container_name - Timeout after ${RUN_TIMEOUT}s"
        return 1
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        echo "❌ FAIL: $container_name - Curl failed with exit code $exit_code"
        echo "   Output: $output"
        return 1
    fi
    
    local ip=$(echo "$output" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    
    case "$expected_behavior" in
        "public")
            check_ip_type "$ip" "$container_name" "public" || return 1
            BASELINE_PUBLIC_IP="$ip"
            ;;
        "warp")
            check_ip_type "$ip" "$container_name" "warp" || return 1
            if [[ -n "$BASELINE_PUBLIC_IP" && "$ip" == "$BASELINE_PUBLIC_IP" ]]; then
                echo "❌ FAIL: $container_name - External IP ($ip) matches baseline public IP ($BASELINE_PUBLIC_IP); traffic likely not routed via WARP"
                return 1
            fi
            ;;
        "multi_public")
            check_ip_type "$ip" "$container_name" "multi_public" || return 1
            if [[ -n "$BASELINE_PUBLIC_IP" && "$ip" != "$BASELINE_PUBLIC_IP" ]]; then
                echo "❌ FAIL: $container_name - External IP ($ip) differs from baseline public IP ($BASELINE_PUBLIC_IP); expected public route"
                return 1
            fi
            ;;
        "multi_warp")
            check_ip_type "$ip" "$container_name" "multi_warp" || return 1
            if [[ -n "$BASELINE_PUBLIC_IP" && "$ip" == "$BASELINE_PUBLIC_IP" ]]; then
                echo "❌ FAIL: $container_name - External IP ($ip) matches baseline public IP ($BASELINE_PUBLIC_IP); expected WARP route by priority"
                return 1
            fi
            ;;
        *)
            echo "❌ FAIL: $container_name - Unknown expected behavior: $expected_behavior"
            return 1
            ;;
    esac
}

# Test 1: IP Checker Naked (default network - should use public)
echo ""
echo "🔹🔹 IP Checker Naked 🔹🔹"
run_ip_checker "ip_checker_naked" "" "public"
NAKED_RESULT=$?

# Test 2: IP Checker WARP (WARP network only - should use WARP)
echo ""
echo "🔹🔹 IP Checker WARP 🔹🔹"
run_ip_checker "ip_checker_warp" "--network warp-network" "warp"
WARP_RESULT=$?

# Test 3: IP Checker WARP Multi Uses Public (bridge first, then warp, expect public)
echo ""
echo "🔹🔹 IP Checker WARP Multi Uses Public 🔹🔹"
run_ip_checker "ip_checker_warp_multi_uses_public" "" "multi_public"
MULTI_PUBLIC_RESULT=$?

# Test 4: IP Checker WARP Multi Uses WARP (warp first, then bridge, expect warp)
echo ""
echo "🔹🔹 IP Checker WARP Multi Uses WARP 🔹🔹"
run_ip_checker "ip_checker_warp_multi_uses_warp" "" "multi_warp"
MULTI_WARP_RESULT=$?

# Summary and exit
echo ""
echo "📊 IP Routing Test Summary:"
echo "   Naked (public): $([ $NAKED_RESULT -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL")"
echo "   WARP only: $([ $WARP_RESULT -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL")"
echo "   WARP + Public (default priority): $([ $MULTI_PUBLIC_RESULT -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL")"
echo "   WARP + Public (WARP priority): $([ $MULTI_WARP_RESULT -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL")"

# Exit with failure if any test failed
if [[ $NAKED_RESULT -ne 0 || $WARP_RESULT -ne 0 || $MULTI_PUBLIC_RESULT -ne 0 || $MULTI_WARP_RESULT -ne 0 ]]; then
    echo ""
    echo "❌ One or more IP routing tests failed. Check the configuration above."
    exit 1
else
    echo ""
    echo "🎉 All IP routing tests passed! WARP NAT routing is working correctly."
fi