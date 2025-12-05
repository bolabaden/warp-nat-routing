#!/usr/bin/env bash
set -euo pipefail

# Configurable via env
DOCKER_CMD="${DOCKER_CMD:-docker -H ${DOCKER_HOST:-unix:///var/run/docker.sock}}"
CHECK_IMAGE="${CHECK_IMAGE:-curlimages/curl}"   # image that includes curl
NETWORK="${NETWORK:-warp-nat-net}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-5}"                  # seconds between checks

# Healthcheck command to run inside the ephemeral container.
# This mirrors your warp-healthcheck logic: exit 0 when WARP active, nonzero otherwise.
HEALTHCHECK_INSIDE='sh -c "if curl -s --max-time 4 https://cloudflare.com/cdn-cgi/trace | grep -qE \"^warp=on|warp=plus$\"; then echo WARP_OK && exit 0; else echo WARP_NOT_OK && exit 1; fi"'

echo "warp-monitor: checking WARP via ephemeral container on network '${NETWORK}'."
echo "Using image: ${CHECK_IMAGE}"
prev_ok=1  # assume healthy initially so we don't run setup at startup
fail_count=0
RETRY_SETUP_AFTER="${RETRY_SETUP_AFTER:-12}"  # retry setup after N consecutive failures

while true; do
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] running health probe..."
  if ${DOCKER_CMD} run --rm --network "${NETWORK}" --entrypoint sh "${CHECK_IMAGE}" -c "${HEALTHCHECK_INSIDE}"; then
    # check succeeded
    if [[ "${prev_ok}" -eq 0 ]]; then
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] health probe recovered -> marking healthy"
    fi
    prev_ok=1
    fail_count=0
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] health probe failed (consecutive failures: $((fail_count + 1)))"
    fail_count=$((fail_count + 1))
    
    # Run setup on first failure OR after N consecutive failures
    if [[ "${prev_ok}" -eq 1 ]] || [[ "${fail_count}" -ge "${RETRY_SETUP_AFTER}" ]]; then
      if [[ "${prev_ok}" -eq 1 ]]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] detected healthy->unhealthy transition; running /usr/local/bin/setup-warp-service.sh"
      else
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] still unhealthy after $fail_count failures; retrying /usr/local/bin/setup-warp-service.sh"
        fail_count=0  # reset counter after retry
      fi
      # Run setup, but do not let its failure kill the monitor. Log failures.
      if /usr/local/bin/setup-warp-service.sh; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] setup-warp-service.sh completed"
      else
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] setup-warp-service.sh failed (exit nonzero)."
      fi
      # mark as unhealthy until probe says otherwise
      prev_ok=0
      # Wait a little before probing again to avoid tight loops
      sleep "${SLEEP_INTERVAL}"
      # continue to next iteration (which will probe again and wait for recovery)
    else
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] still unhealthy ($fail_count failures); will retry setup after $RETRY_SETUP_AFTER consecutive failures"
    fi
  fi

  sleep "${SLEEP_INTERVAL}"
done

