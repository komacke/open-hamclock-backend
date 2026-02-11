# Multi-stage build

#######################################################
# Build voacap
FROM debian:13.3-slim AS build-voacap

USER root
WORKDIR /opt

# Install voap build prerequisites
COPY docker/package-list-voacap.txt /opt
COPY docker/voacap-v.0.7.6.tgz /opt
# Build the voacap artifacts
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list-voacap.txt) && \
    apt-get clean && \
    rm -rf package-list.txt /var/lib/apt/lists/* && \
    # \
    # Build and install voacap \
    # \
    # tarball \
    tar xzf voacap-v.0.7.6.tgz && \
    cd voacapl-v.0.7.6 && \
    # \
    # build it \
    ./configure && \
    make install && \
    # \
    # clean up \
    cd .. && \
    rm -Rf voacapl-v.0.7.6 voacap-v.0.7.6.tgz

#######################################################
# This is the real image
FROM debian:13.3-slim

USER root
WORKDIR /opt

# Install prerequisites
COPY docker/package-list.txt /opt
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list.txt) && \
    apt-get clean && \
    rm -rf package-list.txt /var/lib/apt/lists/* 

# Install voacap after lighttpd was installed above
COPY --from=build-voacap /usr/local/bin/* /usr/local/bin/
COPY --from=build-voacap /usr/local/share/voacapl /usr/local/share/voacapl
COPY --from=build-voacap /usr/local/share/doc/voacapl/README.md /usr/local/share/doc/voacapl/README.md
COPY --from=build-voacap /usr/local/share/doc/voacapl/AUTHORS /usr/local/share/doc/voacapl/AUTHORS
COPY --from=build-voacap /usr/local/share/doc/voacapl/COPYING /usr/local/share/doc/voacapl/COPYING
RUN cd /opt && \
    # \
    # configure it \
    mkdir /var/www/itshfbc && \
    chown www-data:www-data /var/www/itshfbc && \
    runuser -u www-data makeitshfbc

# Install hamclock-backend
COPY . /opt/hamclock-backend/
RUN cd /opt/hamclock-backend && \
    # \
    # make directory structure \
    mkdir -p \
        tmp \
        logs \
        cache \
        data \
        htdocs && \
    mv  docker/run.sh /opt && \
    sed 's/^\([^ #]\+[ ]\+\)\{5\}\([^>]\+\)\([> ]\+\)\?\([^ ]*\).*$/\2\3\4/' scripts/crontab > prime_crontabs.sh && \
    # \
    # set permissions \
    chown -R www-data:www-data . && \
    chmod +x scripts/* prime_crontabs.sh /opt/run.sh && \
    # \
    # fontconfig needs a writeable cache directory \
    mkdir -p /var/www/.fontconfig && \
    chown -R www-data:www-data /var/www/.fontconfig && \
    # \
    # set up cron \
    mv scripts/crontab /var/spool/cron/crontabs/www-data && \
    chown www-data:crontab /var/spool/cron/crontabs/www-data && \
    chmod 600 /var/spool/cron/crontabs/www-data && \
    # \
    # set up logrotate \
    mv ohb.logrotate /etc/logrotate.d/ohb && \
    # \
    # set up lighttpd \
    mv 50-hamclock.conf /etc/lighttpd/conf-available/50-hamclock.conf && \
    /usr/sbin/lighty-enable-mod accesslog && \
    /usr/sbin/lighttpd-enable-mod hamclock && \
    rm -f /var/www/html/index.lighttpd.html && \
    cp ham/HamClock/favicon.ico /var/www/html/ && \
    cat <<EOF >>/etc/lighttpd/lighttpd.conf
server.modules += (
  "mod_cgi"
)
EOF

# let's rock!
CMD ["/opt/run.sh"]
