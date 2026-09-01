echo bfq | sudo tee /sys/block/nvme0n1/queue/scheduler
make

./bdev_set_bytes /dev/nvme0n1 0 8388608 8388608
sudo fio example.fio &
PID=$!
sleep 1

burst_pid=$(ps aux | grep fio | tail -n2 | head -n1 | awk '{print $2}')
./ioprio_override $burst_pid

while kill -0 "$PID" 2>/dev/null; do
    bytes=$(./bdev_get_bytes /dev/nvme0n1 2>/dev/null)
    if [[ "$bytes" =~ ^-?[0-9]+$ ]]; then
        mb=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1000 / 1000 }')
        printf '[%s] queue_MB=%s\n' "$(date '+%H:%M:%S')" "$mb"
    else
        printf '[%s] queue_bytes=ERR (%s)\n' "$(date '+%H:%M:%S')" "$bytes"
    fi
    sleep 1
done

wait $PID