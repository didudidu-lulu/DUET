#!/bin/bash
set -e

sudo umount /mnt || true
sudo mkfs.ext4 -F /dev/nvme0n1
sudo mount -t ext4 -o rw /dev/nvme0n1 /mnt
sudo chown str508:str508 /mnt
sudo chmod 755 /mnt

PIDS=()
workloads=(a b c d e f)
for w in "${workloads[@]}"; do
    /home/str508/ycsb-0.17.0/bin/ycsb load rocksdb -P /home/str508/ycsb-0.17.0/workloads/workload${w} -p rocksdb.dir=/mnt/${w} -p recordcount=10000000 &
    PIDS+=($!)
done
wait "${PIDS[@]}"


for w in "${workloads[@]}"; do
    echo $w
    sudo umount /mnt
    sudo sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    sudo mount -t ext4 -o rw /dev/nvme0n1 /mnt
    sudo chown str508:str508 /mnt
    sudo chmod 755 /mnt
    sudo sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    if [ $w == "c" ]; then
        sudo blktrace -a read -d /dev/nvme0n1 &
    else
        sudo blktrace -d /dev/nvme0n1 &
    fi
    BLKTRACE_PID=$!

    /home/str508/ycsb-0.17.0/bin/ycsb run rocksdb -P /home/str508/ycsb-0.17.0/workloads/workloadc -p rocksdb.dir=/mnt/${w} -p operationcount=100000

    sudo kill $BLKTRACE_PID 2>/dev/null
    sleep 1

    blkparse nvme0n1 -d ${w}.bin >/dev/null
    blkparse nvme0n1 -o ${w}.txt >/dev/null
    rm nvme0n1.blktrace.* -f
done

sudo umount /mnt
