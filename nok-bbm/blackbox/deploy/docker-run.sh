#!/usr/bin/zsh

docker run --rm \
  -p 9115:9115 \
  --name blackbox_exporter \
  -v $(pwd)/config:/config \
  quay.io/prometheus/blackbox-exporter:latest --config.file=/config/blackbox.yml