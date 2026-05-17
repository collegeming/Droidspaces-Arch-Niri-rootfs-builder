#!/bin/bash
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    echo "Using deb822 format"
else
    echo "Using traditional format"
fi
