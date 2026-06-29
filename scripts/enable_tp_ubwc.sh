#!/bin/bash

if ! command -v lspci >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

pci_list=$(lspci 2>/dev/null || true)
if echo "$pci_list" | grep -qi "sm8550" || echo "$pci_list" | grep -qi "8 Gen 2"; then
    export FD_DEV_FEATURES="enable_tp_ubwc_flag_hint=1"
fi
