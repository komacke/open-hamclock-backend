#!/bin/sh

# pull down latest server data files
/usr/sbin/runuser -u www-data /opt/sync_server_data_files.sh

# start the web server
/usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf

# only needs to be primed when container is instantiated
if [ ! -e /opt/hamclock-backend/htdocs/prime_crontabs.done ]; then
    echo "Running OHB first the first time. Priming the data set ..."
    /usr/sbin/runuser -u www-data /opt/hamclock-backend/prime_crontabs.sh
    touch /opt/hamclock-backend/htdocs/prime_crontabs.done
    echo "Done! OHB data has been primed."
fi

# start cron
/usr/sbin/cron

# hold the script to keep the container running
tail --pid=$(pidof cron) -f /dev/null
