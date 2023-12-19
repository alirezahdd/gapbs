#!/bin/bash
mkdir asmsrc
kernels=("bc" "bfs" "cc" "pr" "sssp" "tc")

for i in "${!kernels[@]}"
do
    objdump -S -l --visualize-jump ${kernels[$i]} > asmsrc/${kernels[$i]}.asm
done
