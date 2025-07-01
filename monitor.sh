#!/bin/bash

# Container name to monitor
CONTAINER_NAME="agitated_cannon"

# Log file for debugging (persistent in repository)
LOG_FILE="/workspaces/chain/docker_events.log"

# Path to stop.sh script
STOP_SCRIPT="/workspaces/gofly/stop.sh"

# Memory threshold (6.3Gi in bytes)
MEMORY_THRESHOLD=$((6 * 1024 * 1024 * 1024 + 322122547))  # 6.3 GiB


# Runtime threshold (3 hours 58 minutes = 14280 seconds)
RUNTIME_THRESHOLD=14250
RUNTIME_LIMIT=3250
# Ensure log file directory exists and is writable
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
if [ ! -w "$LOG_FILE" ]; then
    echo "Error: Cannot write to $LOG_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

# Ensure stop.sh exists and is executable
if [ ! -f "$STOP_SCRIPT" ]; then
    echo "Error: $STOP_SCRIPT does not exist" | tee -a "$LOG_FILE"
    exit 1
fi
if [ ! -x "$STOP_SCRIPT" ]; then
    chmod +x "$STOP_SCRIPT"
fi

echo "Starting Docker container crash and memory monitoring for $CONTAINER_NAME..." | tee -a "$LOG_FILE"

# Clear temporary file for Docker events
: > /tmp/docker_status.tmp

# Function to run stop.sh and log execution
run_stop_script() {
    local reason=$1
    echo "Executing $STOP_SCRIPT due to $reason at $(date)" | tee -a "$LOG_FILE"
    bash "$STOP_SCRIPT" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo "Successfully executed $STOP_SCRIPT" | tee -a "$LOG_FILE"
    else
        echo "Error: Failed to execute $STOP_SCRIPT" | tee -a "$LOG_FILE"
    fi
}

# Background process to monitor memory usage, runtime, and replit.txt
(
    while true; do
        # Get used memory in bytes
        USED_MEM=$(free -b | awk '/Mem:/ {print $3}')
        echo "DEBUG: Used memory: $USED_MEM bytes at $(date)" >> "$LOG_FILE"

        if [ "$USED_MEM" -ge "$MEMORY_THRESHOLD" ]; then
            echo "ALERT: Used memory ($USED_MEM bytes) exceeded threshold at $(date)!" | tee -a "$LOG_FILE"
            run_stop_script "high memory usage"
            sleep 60
        fi

        # Check Codespace runtime
        RUNTIME_SECONDS=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
        echo "DEBUG: Codespace runtime: $RUNTIME_SECONDS seconds at $(date)" >> "$LOG_FILE"
        if [ "$RUNTIME_SECONDS" -ge "$RUNTIME_THRESHOLD" ]; then
            echo "ALERT: Codespace runtime ($RUNTIME_SECONDS seconds) exceeded threshold at $(date)!" | tee -a "$LOG_FILE"
            run_stop_script "runtime threshold reached (3 hours 58 minutes)"
            sleep 60  # Prevent immediate re-trigger
        fi

         # Check Codespace runtime again
        RUNTIME_SECONDS=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
        echo "DEBUG: Codespace runtime: $RUNTIME_SECONDS seconds at $(date)" >> "$LOG_FILE"
        if [ "$RUNTIME_SECONDS" -ge "$RUNTIME_LIMIT" ]; then
            echo "ALERT: Codespace runtime ($RUNTIME_SECONDS seconds) exceeded threshold at $(date)!" | tee -a "$LOG_FILE"
            run_stop_script "runtime threshold limit reached"
            sleep 60  # Prevent immediate re-trigger
        fi
        
        # Check if failure.txt exists inside the container
        FILE_EXISTENCE=$(docker exec "$CONTAINER_NAME" bash -c '[ -f /root/failure.txt ] && echo "exists" || echo "not_exists"')
        echo "DEBUG: failure.txt existence check: $FILE_EXISTENCE at $(date)" >> "$LOG_FILE"

        if [ "$FILE_EXISTENCE" = "exists" ]; then
            echo "ALERT: failure.txt detected inside container at $(date)!" | tee -a "$LOG_FILE"
            run_stop_script "failure.txt detected"
            sleep 60  # Prevent immediate re-trigger
        fi

        # Check if replit.txt exists and copy it
        if docker exec "$CONTAINER_NAME" test -f /root/Desktop/replit.txt; then
            echo "INFO: replit.txt found inside container at $(date), copying to /tmp/replit.txt" | tee -a "$LOG_FILE"
            docker cp "$CONTAINER_NAME":/root/Desktop/replit.txt /tmp/replit.txt
            sleep 2
        fi

        sleep 10
    done
) &

# Monitor Docker events (smart crash detection)
stdbuf -oL docker events \
    --filter "container=$CONTAINER_NAME" \
    --filter "event=die" \
    --filter "event=start" \
    --format '{{json .}}' | while read -r event_json; do

    if [ -z "$event_json" ]; then
        continue
    fi

    # Parse event
    event_status=$(echo "$event_json" | jq -r '.status')
    event_time=$(echo "$event_json" | jq -r '.timeNano')
    exit_code=$(echo "$event_json" | jq -r '.Actor.Attributes.exitCode // empty')

    # Convert timeNano to seconds
    event_time_sec=$((event_time / 1000000000))

    echo "DEBUG: Event received: $event_status at $(date -d @$event_time_sec), exit code: $exit_code" | tee -a "$LOG_FILE"

    if [ "$event_status" = "die" ]; then
        echo "DEBUG: Container died with exit code $exit_code at $(date -d @$event_time_sec)" | tee -a "$LOG_FILE"

        if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
            echo "ALERT: Docker container '$CONTAINER_NAME' crashed (exit code $exit_code) at $(date -d @$event_time_sec)!" | tee -a "$LOG_FILE"
            run_stop_script "container crash (exit code $exit_code)"
        else
            echo "INFO: Container '$CONTAINER_NAME' stopped manually (exit code 0) at $(date -d @$event_time_sec), no action taken." | tee -a "$LOG_FILE"
        fi
    fi

    if [ "$event_status" = "start" ]; then
        echo "INFO: Docker container '$CONTAINER_NAME' started at $(date -d @$event_time_sec)" | tee -a "$LOG_FILE"
    fi

    # Save event to temporary file
    echo "$event_status $event_time_sec" >> /tmp/docker_status.tmp
    tail -n 2 /tmp/docker_status.tmp > /tmp/docker_status_latest.tmp
    mv /tmp/docker_status_latest.tmp /tmp/docker_status.tmp

    # Detect quick die -> start (crash recovery)
    if [ $(wc -l < /tmp/docker_status.tmp) -eq 2 ]; then
        prev_event=$(head -n 1 /tmp/docker_status.tmp)
        last_event=$(tail -n 1 /tmp/docker_status.tmp)

        prev_status=$(echo "$prev_event" | awk '{print $1}')
        last_status=$(echo "$last_event" | awk '{print $1}')
        prev_time=$(echo "$prev_event" | awk '{print $2}')
        last_time=$(echo "$last_event" | awk '{print $2}')

        if [ "$prev_status" = "die" ] && [ "$last_status" = "start" ]; then
            time_diff=$((last_time - prev_time))
            echo "DEBUG: Previous event: $prev_status at $prev_time, Current event: $last_status at $last_time (diff ${time_diff}s)" | tee -a "$LOG_FILE"

            if [ "$time_diff" -le 15 ]; then
                echo "ALERT: Docker container '$CONTAINER_NAME' crashed and restarted quickly at $(date)" | tee -a "$LOG_FILE"
                # No need to run stop.sh again — already handled on die event
            fi
        fi
    fi
done
