#!/usr/bin/bash

# script to create 12 files; one for each month

path=$1

for i in {1..12}; do
  if [[ $i -le 9 ]]; then
    prefix="0"
    month="${prefix}${i}"
    else
      month=$i
  fi
  touch -t "${month}010101" $path"/backup${month}.db"
done
