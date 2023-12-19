#!/bin/bash

# This script runs gapbs $kernels on $graphs with $available_memory
# and overcommitting factor of $ocfs. While running them, it counts
# and measures major-faults, minor-faults, cycles:u, cycles:k,
# context-switches, instructions:u, instructions:k, L3MPKI:u, L3MPKI:k,
# IPC, swap_ra, swap_ra_hits, PPMI.
# It also read and measure disk statistics every second in
# /sys/block/<device>/<partition>/stat including swap ins, swap outs,
# swap ins(sectors), swap outs(sectors)
# Disk average queue is also monitored every second using dstat tool

RESULT_DIR="log"  # "." for current folder

kernels=("bc" "bfs" "cc" "pr" "sssp" "tc")  #("bc" "bfs" "cc" "pr" "sssp" "tc")
graphs=("road")  #("road" "kron" "twitter" "urand" "web")

# MAKE SURE 100 IS ALWAYS SELECTED IN ORDER TO CORRECTLY MEASURE 'NP TIME'
available_memory=("30") #("100" "90" "80" "70" "60" "50" "40" "30")

# MAKE SURE 1 IS ALWAYS SELECTED IN ORDER TO CORRECTLY MEASURE 'NP TIME'
ocfs=("1") #("1" "2" "4" "8" "16" "32" "64" "128")

swap_readahead="ON" # "ON" or "OFF"
file_readahead="ON" # "ON" or "OFF"
NUM_SWAP_PARTITIONS=1   #can be 1, 2, 3, and 4 in our system (terra)
NUM_CORES=$(lscpu | grep -w "CPU(s):" |grep  -v "NUMA"| awk '{print $2}') #8
GRAPH_DIR="/share/graphs"
file_partition="nvme1n1p2"  #might be nvme0n1p2. use lsblk to figure it out
#file_partition="nvme0n1p2"  #might be nvme1n1p2. use lsblk to figure it out

perf_events="-e major-faults"

declare -A kernel_args
kernel_args["bc"]="-i4 -n5"            # Default "-i4 -n16"
kernel_args["bfs"]="-n5"               # Default "-n64"
kernel_args["cc"]="-n5"                # Default "-n16"
kernel_args["pr"]="-i1000 -t1e-4 -n5"  # Default "-i1000 -t1e-4 -n16"
kernel_args["sssp"]="-n3 -d2"          # Default "-n64 -d2"
kernel_args["tc"]="-n1"                # Default "-n3"

########################################  FUNCTIONS  ###############################

# Enables lock stats gathering
function enable_lock_stats(){
    # Disabling lock stat gathering
    sudo sh -c "echo 0 > /proc/sys/kernel/lock_stat"
    
    # Clearing already gather lock stats
    sudo sh -c "echo 0 > /proc/lock_stat"

    # Enabling lock stat gathering
    sudo sh -c "echo 1 > /proc/sys/kernel/lock_stat"
}

# Disables lock stats gathering
function disable_lock_stats(){
    # Disabling lock stat gathering
    sudo sh -c "echo 0 > /proc/sys/kernel/lock_stat"
}

# measures the workload size in MB
function measure_workload_size(){
    local kernel=$1
    local graph_path=$2
    local max_rss=0
    /usr/bin/time -v -o max_rss.txt ../$kernel -f $graph_path -n 1 > /dev/null
    max_rss=$(grep Maximum max_rss.txt | awk '{print $6}')   # max_rss in kB
    max_rss=$((max_rss/1000))   #max_rss in MB
    rm max_rss.txt
    echo $max_rss
}
#turns on swap readheads
function turn_on_swap_ra(){
    echo 3 > /proc/sys/vm/page-cluster #swap readahead is turned on with 2^3=8 pages
}
#turns off swap readheads
function turn_off_swap_ra(){
    echo 0 > /proc/sys/vm/page-cluster #swap readahead is turned off
}
#turns on file readheads
function turn_on_file_ra(){
    sudo blockdev --setra 256 /dev/$file_partition #file readahead is turned on with 256 sectors = 32 pages
}
#turns off file readheads
function turn_off_file_ra(){
    sudo blockdev --setra 0 /dev/$file_partition #file readahead is turned off
}


function adjust_the_settings(){
    echo "Number of cores: $NUM_CORES"
    printf "Kernels: "
    printf "%s " "${kernels[@]}"
    echo
    printf "Graphs: "
    printf "%s " "${graphs[@]}"
    echo
    printf "Available memories: "
    printf "%s " "${available_memory[@]}"
    echo
    printf "Over Committing Factors: "
    printf "%s " "${ocfs[@]}"
    echo
    printf "Swap Readahead: "
    printf "%s " "$swap_readahead"
    echo
    if [ "$swap_readahead" == "ON" ]; then
        turn_on_swap_ra
        echo "swap readhead turned on"
    else
        turn_off_swap_ra
        echo "swap readhead turned off"
    fi
    printf "File Readahead: "
    printf "%s " "$file_readahead"
    echo
    if [ "$file_readahead" == "ON" ]; then
        turn_on_file_ra
        echo "file readhead turned on"
    else
        turn_off_file_ra
        echo "file readhead turned off"
    fi

    echo "Graph Directory: $GRAPH_DIR"
    echo
}
################################################################################################
# requirement: creation of a cgroup named 'myGroup'. you can use the following command to do it: 'cgcreate -g memory:myGroup'
mkdir $RESULT_DIR
sudo cgcreate -g memory:myGroup
adjust_the_settings

for i in "${!kernels[@]}"
do
    kernel=${kernels[$i]}
    mkdir $RESULT_DIR/$kernel                       #creating a directory named after the kernel for its results
    for j in "${!graphs[@]}"
    do
        #selecting the graph and its corresponding path
        graph=${graphs[$j]}
        if [ "$kernel" == "sssp" ]; then
            graph_path=$GRAPH_DIR/$graph.wsg        # sssp uses weighted graphs (.wsg)
        elif [ "$kernel" == "tc" ]; then
            graph_path=$GRAPH_DIR/${graph}U.sg      # tc uses undirected graphs (.sg)
        else
            graph_path=$GRAPH_DIR/$graph.sg         # other kernels use non-weighted graphs (.sg)
        fi

        #measuring kernel(graph) workload size 
        workload_size=$(measure_workload_size $kernel $graph_path)
        echo "($kernel,$graph) workload_size = $workload_size MB"

        #for all percentages 
        for k in "${!available_memory[@]}"
        do
            percentage=${available_memory[$k]}
            
            #adjusting available memory to a certain percentage
            mem_size=$((workload_size*percentage/100))

            #limiting the memory available to the process to $mem_size_M
            echo "${mem_size}M" > /sys/fs/cgroup/memory/myGroup/memory.limit_in_bytes      
            cat /sys/fs/cgroup/memory/myGroup/memory.limit_in_bytes
            sleep 1
            echo memory limit is set to ${mem_size} MB

            #for all ocfs
            for o in "${!ocfs[@]}"
            do
                ocf=${ocfs[$o]}
            
                #calculate the number of threads
                threads=$((ocf*NUM_CORES))

                #set output file name
                output_file_name=$kernel-$graph-$percentage-$ocf-$NUM_SWAP_PARTITIONS-$mem_size.txt
                if [ "$swap_readahead" == "OFF" ]; then
                    output_file_name=$kernel-$graph-$percentage-$ocf-$NUM_SWAP_PARTITIONS-$mem_size-RAOFF.txt
                fi

                #echo the what you are doing
                echo "Running ($kernel,$graph,$percentage,$ocf)"
                echo "sudo OMP_NUM_THREADS=$threads \
                cgexec -g memory:myGroup \
                ../$kernel -f $graph_path ${kernel_args[$kernel]}"

                #Enabling lock stats gathering
                #enable_lock_stats
                                
                #running the benchmark
                sudo OMP_NUM_THREADS=$threads \
                perf trace --pf=maj \
                -o $RESULT_DIR/$kernel/perf_$output_file_name \
                cgexec -g memory:myGroup \
                ../$kernel -f $graph_path ${kernel_args[$kernel]}  
                
                #Dumping the lock stats
                #sudo cat /proc/lock_stat > $RESULT_DIR/$kernel/$output_file_name
                                
                #Disabling lock stats gathering
                #disable_lock_stats

            done
        done
    done
done

turn_on_swap_ra
turn_on_file_ra
