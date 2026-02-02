#!/bin/sh
# ZaaNet Router Metrics Collection Script
# Collects traffic data from NoDogSplash and sends to ZaaNet server
# Runs every 60 seconds via cron

set -e

# Load router config
if [ -f /etc/zaanet/config ]; then
  . /etc/zaanet/config
else
  echo "[ERROR] Config file not found: /etc/zaanet/config"
  exit 1
fi

# Configuration
LOG_FILE="/tmp/zaanet-metrics.log"
MAX_LOG_SIZE=10240  # 10KB
METRICS_ENDPOINT="${MAIN_SERVER}/api/v1/portal/metrics/data-usage"

# Function to log with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
  
  # Rotate log if too large
  if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
    tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

# Get NoDogSplash client stats in JSON format
get_client_stats() {
  # Try ndsctl json first (newer versions)
  if ndsctl json >/dev/null 2>&1; then
    ndsctl json
  else
    # Fallback: parse ndsctl clients output
    # Format: IP MAC Download Upload Duration Token State
    ndsctl clients 2>/dev/null | awk '
      NR > 1 {
        # Skip header and empty lines
        if (NF >= 7) {
          ip = $1
          mac = $2
          download = $3
          upload = $4
          duration = $5
          token = $6
          state = $7
          
          # Only include authenticated clients
          if (state == "Authenticated" || state == "authenticated") {
            print "{\"ip\":\"" ip "\",\"mac\":\"" mac "\",\"download\":" download ",\"upload\":" upload ",\"duration\":" duration ",\"token\":\"" token "\"}"
          }
        }
      }
    ' | sed 's/$/,/' | sed '$ s/,$//' | awk 'BEGIN{print "["} {print} END{print "]"}'
  fi
}

# Convert bytes to ensure numeric format
normalize_bytes() {
  # Remove any 'KB', 'MB', 'GB' suffixes and convert to bytes
  echo "$1" | awk '{
    val = $1
    if (val ~ /KB$/) {
      sub(/KB$/, "", val)
      val = val * 1024
    } else if (val ~ /MB$/) {
      sub(/MB$/, "", val)
      val = val * 1024 * 1024
    } else if (val ~ /GB$/) {
      sub(/GB$/, "", val)
      val = val * 1024 * 1024 * 1024
    }
    print int(val)
  }'
}

# Main execution
log "Starting metrics collection..."

# Check if NoDogSplash is running
if ! /etc/init.d/nodogsplash status | grep -q "running"; then
  log "[WARN] NoDogSplash is not running"
  exit 0
fi

# Get client stats
CLIENT_STATS=$(get_client_stats 2>/dev/null)

if [ -z "$CLIENT_STATS" ] || [ "$CLIENT_STATS" = "[]" ]; then
  log "[INFO] No active clients found"
  exit 0
fi

log "[INFO] Found active clients, preparing payload..."

# Build JSON payload for server
# Note: We need to map NDS clients to sessions in the database
# The server will match by IP address and active sessions
PAYLOAD=$(echo "$CLIENT_STATS" | awk -v contract_id="$CONTRACT_ID" '
BEGIN {
  print "{"
  print "  \"sessionUpdates\": ["
  first = 1
}
/"ip":/ {
  # Extract fields from JSON
  match($0, /"ip":"([^"]+)"/, ip_arr)
  match($0, /"mac":"([^"]+)"/, mac_arr)
  match($0, /"download":([0-9]+)/, dl_arr)
  match($0, /"upload":([0-9]+)/, ul_arr)
  
  ip = ip_arr[1]
  mac = mac_arr[1]
  download = dl_arr[1]
  upload = ul_arr[1]
  total = download + upload
  
  if (ip && download >= 0 && upload >= 0) {
    if (!first) print ","
    first = 0
    
    print "    {"
    print "      \"userIP\": \"" ip "\","
    print "      \"sessionId\": null,"
    print "      \"dataUsage\": {"
    print "        \"downloadBytes\": " download ","
    print "        \"uploadBytes\": " upload ","
    print "        \"totalBytes\": " total ","
    print "        \"lastUpdated\": \"" strftime("%Y-%m-%dT%H:%M:%SZ") "\""
    print "      }"
    print "    }"
  }
}
END {
  print "  ]"
  print "}"
}
')

log "[DEBUG] Payload prepared"

# Send to server
if command -v wget >/dev/null 2>&1; then
  RESPONSE=$(wget --timeout=10 --tries=2 -qO- \
    --header="Content-Type: application/json" \
    --header="X-Router-ID: $ROUTER_ID" \
    --header="X-Contract-ID: $CONTRACT_ID" \
    --post-data="$PAYLOAD" \
    "$METRICS_ENDPOINT" 2>&1)
  EXIT_CODE=$?
elif command -v curl >/dev/null 2>&1; then
  RESPONSE=$(curl -s --max-time 10 --retry 2 \
    -H "Content-Type: application/json" \
    -H "X-Router-ID: $ROUTER_ID" \
    -H "X-Contract-ID: $CONTRACT_ID" \
    -d "$PAYLOAD" \
    "$METRICS_ENDPOINT" 2>&1)
  EXIT_CODE=$?
else
  log "[ERROR] Neither wget nor curl available"
  exit 1
fi

if [ $EXIT_CODE -eq 0 ]; then
  # Check if response contains "success":true
  if echo "$RESPONSE" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    log "[SUCCESS] Metrics sent successfully"
  else
    log "[WARN] Server responded but not successful: $RESPONSE"
  fi
else
  log "[ERROR] Failed to send metrics (exit code: $EXIT_CODE)"
fi

exit 0
