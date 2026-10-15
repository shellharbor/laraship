#!/bin/sh
# Local FPM liveness only; application/DB readiness is checked by the deployer.
set -eu
REPLY=$(SCRIPT_NAME=/_laraship/fpm-ping SCRIPT_FILENAME=/_laraship/fpm-ping REQUEST_METHOD=GET \
    timeout 3 cgi-fcgi -bind -connect 127.0.0.1:9000)
printf '%s\n' "$REPLY" | tail -n 1 | grep -qx pong
