#!/bin/bash
pci_list=$(lspci)
if echo "$pci_list" | grep -qi "sm8550" || echo "$pci_list" | grep -qi "8 Gen 2"; then
    export FD_DEV_FEATURES="enable_tp_ubwc_flag_hint=1"
fi
