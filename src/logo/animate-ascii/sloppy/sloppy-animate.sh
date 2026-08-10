#!/bin/bash

frames=(
"$HOME/Projects/Skull_Animation/sloppy/skull01.txt"
"$HOME/Projects/Skull_Animation/sloppy/skull02.txt"
"$HOME/Projects/Skull_Animation/sloppy/skull03.txt"
"$HOME/Projects/Skull_Animation/sloppy/skull04.txt"
"$HOME/Projects/Skull_Animation/sloppy/skull01.txt"
"$HOME/Projects/Skull_Animation/sloppy/skull01.txt"
)

while true; do
    clear
    echo -e "\033[31m" #red
    cat "${frames[$((RANDOM % ${#frames[@]}))]}"
    sleep 0.20
done
