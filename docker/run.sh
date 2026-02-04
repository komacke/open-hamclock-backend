#!/bin/sh

lighttpd -D -f /etc/lighttpd/lighttpd.conf
cron
