#!/bin/bash

OHB_HTDOCS=ohb-htdocs
WAS_SETUP=0

main() {

    check_was_setup
        
    echo "Setting up OHB prerequisites in docker. This only needs to be done for a fresh install."

    create_volume

    echo
    echo "Done! When you are ready, bring up the container with docker-compose:"
    echo "  docker-compose up -d"
}

check_was_setup() {
    if check_dvc; then
        WAS_SETUP=1
    fi
        
    if [ $WAS_SETUP -ne 0 ]; then
        echo "OHB prerequisites were previously set up."
        exit 1
    fi
}

check_dvc() {
    docker volume ls | grep -qsw $OHB_HTDOCS
    return $?
}

create_volume() {
    docker volume create $OHB_HTDOCS >/dev/null
}

main "$@"
