#!/usr/bin/zsh

# ./clab-scripts/file_sd_gen.zsh
# Error: This script requires exactly 2 arguments.
# Usage: ./clab-scripts/file_sd_gen.zsh <clab_name> <clab_node_kind>

# sros_bngt targets
echo "--> Adding sros_bngt targets..."
./clab-scripts/file_sd_gen.zsh sros_bngt nokia_srsim > ./prometheus/configmap/ds_file_nokia_srsim-sros_bngt.yaml
./clab-scripts/file_sd_gen.zsh sros_bngt linux > ./prometheus/configmap/ds_file_linux-sros_bngt.yaml

# Add new clab here...