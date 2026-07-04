#!/bin/bash
if ! systemctl is-active --quiet sing-box.service; then
    systemctl restart sing-box.service
    logger "stable-proxy: sing-box restarted by healthcheck"
fi
