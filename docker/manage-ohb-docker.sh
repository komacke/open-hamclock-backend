#!/bin/bash

OHB_HTDOCS_DVC=ohb-htdocs
IMAGE_BASE=komacke/open-hamclock-backend

# Get our directory locations in order
HERE="$(realpath -s "$(dirname "$0")")"
THIS="$(basename "$0")"
cd $HERE

DOCKER_PROJECT=${THIS%.*}
DEFAULT_TAG=latest
GIT_TAG=$(git describe --exact-match --tags 2>/dev/null)
CONTAINER=${IMAGE_BASE##*/}
DEFAULT_HTTP_PORT=:80
RETVAL=0

main() {
    COMMAND=$1
    case $COMMAND in
        -h|--help|help)
            usage
            ;;
        check-docker)
            check_docker_installed
            ;;
        install)
            shift && get_compose_opts "$@"
            install_ohb
            ;;
        upgrade)
            shift && get_compose_opts "$@"
            upgrade_ohb
            ;;
        full-reset)
            shift
            get_compose_opts "$@"
            recreate_ohb
            ;;
        remove)
            remove_ohb
            ;;
        restart)
            shift && get_compose_opts "$@"
            docker_compose_down
            docker_compose_up
            ;;
        up)
            shift && get_compose_opts "$@"
            docker_compose_up
            ;;
        down)
            shift && get_compose_opts "$@"
            docker_compose_down
            ;;
        generate-docker-compose)
            shift
            get_compose_opts "$@"
            generate_docker_compose
            ;;
        *)
            echo "Invalid or missing option. Try using '$THIS help'."
            RETVAL=1
            ;;
    esac
}

get_compose_opts() {
    while getopts ":p:t:" opt; do
        case $opt in
            p)
                REQUESTED_HTTP_PORT="$OPTARG"
                ;;
            t)
                REQUESTED_TAG="$OPTARG"
                ;;
            \?) # Handle invalid options
                echo "Command '$COMMAND': Invalid option: -$OPTARG" >&2
                exit 1
                ;;
            :) # Handle options requiring an argument but none provided
                echo "Command '$COMMAND': Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done
}

usage () {
    cat<<EOF
$THIS <COMMAND> [options]:
    help: 
            This message

    check-docker:
            checks docker requirements and shows version

    install [-p <port>] [-t <tag>]
            do a fresh install and optionally provide the version
            -p: set the HTTP port
            -t: set image tag

    upgrade [-p <port>] [-t <tag>]
            upgrade ohb; defaults to current git tag if there is one. Otherwise you can provide one.
            -p: set the HTTP port (defaults to current setting)
            -t: set image tag

    full-reset [-p <port>] [-t <tag>]: 
            clear out all data and start fresh
            -p: set the HTTP port (defaults to current setting)
            -t: set image tag

    remove: 
            stop and remove the docker container, docker storage and docker image

    restart:
            restart OHB

    generate-docker-compose [-p <port>] [-t <tag>]: 
            writes the docker compose file to STDOUT
            -p: set the HTTP port (defaults to current setting)
            -t: set image tag
EOF
}

install_ohb() {
    check_docker_installed >/dev/null || return $?
    check_dvc_created || return $?

    echo "Installing OHB ..."

    echo "Creeating persistent storage ..."
    if create_dvc; then
        echo "Persistent storage created successfully."
    else
        echo "ERROR: failed to create persistence storage."
        return $RETVAL
    fi

    echo "Starting the container ..."
    if docker_compose_up; then
        echo "Container started successfully."
    else
        echo "ERROR: failed to start OHB with docker compose up"
        return $RETVAL
    fi
    return $RETVAL
}

upgrade_ohb() {
    check_docker_installed >/dev/null || return $?

    echo "Upgrading OHB ..."

    echo "Starting the container ..."
    if docker_compose_up; then
        echo "Container started successfully."
    else
        echo "ERROR: failed to start OHB with docker compose up"
        return $RETVAL
    fi
    return $RETVAL
}

check_docker_installed() {
    DOCKERD_VERSION=$(dockerd -v 2>/dev/null)
    DOCKERD_RETVAL=$?
    DOCKER_COMPOSE_VERSION=$(docker compose version 2>/dev/null)
    DOCKER_COMPOSE_RETVAL=$?

    if [ $DOCKERD_RETVAL -ne 0 ]; then
        echo "ERROR: docker is not installed. Could not find dockerd." >&2
        RETVAL=$DOCKERD_RETVAL
    elif [ $DOCKER_COMPOSE_RETVAL -ne 0 ]; then
        echo "ERROR: docker compose is not installed but we found docker. Try installing docker compose." >&2
        echo "  docker version found: '$DOCKERD_VERSION'" >&2
        RETVAL=$DOCKER_COMPOSE_RETVAL
    else
        echo "$DOCKERD_VERSION"
        echo "$DOCKER_COMPOSE_VERSION"
    fi
    return $RETVAL
}

check_dvc_created() {
    if is_dvc_exists; then
        echo "This doesn't appear to be a fresh install. A docker volume container"
        echo "was found."
        echo
        echo "Maybe you wanted to upgrade:"
        echo "  $THIS upgrade"
        echo "or"
        echo "Maybe you wanted to reset the system and all its data:"
        echo "  $THIS full-reset"
        RETVAL=1
    fi
    return $RETVAL
}

docker_compose_up() {
    docker compose -f <(docker_compose_yml) up -d
    RETVAL=$?
    return $RETVAL
}

docker_compose_down() {
    docker compose -f <(docker_compose_yml) down -v
    RETVAL=$?

    docker ps --format '{{.Names}}' | grep -wqs $CONTAINER
    if [ $? -eq 0 ]; then
        RUNNING_PROJECT=$(docker inspect open-hamclock-backend | jq -r '.[0].Config.Labels."com.docker.compose.project"')
        if [ "$RUNNING_PROJECT" != "$DOCKER_PROJECT" ]; then
            echo "ERROR: this OHB was created with a different docker-compsose file. Please run"
            echo "    'docker compose down -v'"
            echo "before running this utility."
        else
            echo "ERROR: OHB failed to stop."
        fi
        RETVAL=1
    fi
    
    return $RETVAL
}

generate_docker_compose() {
    docker_compose_yml
}

remove_ohb() {
    echo "Stopping the container ..."
    if docker_compose_down; then
        echo "Container stopped successfully."
    else
        echo "ERROR: failed to stop OHB with docker compose down"
        return $RETVAL
    fi
    echo "Removing persistent storage ..."
    if rm_dvc; then
        echo "Persistent storage removed successfully."
    else
        echo "ERROR: failed to remove persistence storage."
        return $RETVAL
    fi
}

recreate_ohb() {
    remove_ohb || return $RETVAL
    install_ohb || return $RETVAL
}

is_dvc_exists() {
    docker volume ls | grep -qsw $OHB_HTDOCS_DVC
    return $?
}

create_dvc() {
    docker volume create $OHB_HTDOCS_DVC >/dev/null
    RETVAL=$?
    return $RETVAL
}

rm_dvc() {
    docker volume rm $OHB_HTDOCS_DVC >/dev/null
    RETVAL=$?
    return $RETVAL
}

get_current_http_port() {
    DOCKER_HTTP_PORT=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort')
    DOCKER_HTTP_IP=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostIp')
    if [ "$DOCKER_HTTP_PORT" != 'null' ]; then
        if [ "$DOCKER_HTTP_IP" != 'null' ]; then
            CURRENT_HTTP_PORT=$DOCKER_HTTP_IP:$DOCKER_HTTP_PORT
        else
            CURRENT_HTTP_PORT=:$DOCKER_HTTP_PORT
        fi
    fi
}

get_current_image_tag() {
    DOCKER_IMAGE=$(docker inspect open-hamclock-backend 2>/dev/null | jq -r '.[0].Config.Image')
    if [ "$DOCKER_IMAGE" != 'null' ]; then
        CURRENT_TAG=${DOCKER_IMAGE#*:}
    fi
}

docker_compose_yml() {
    get_current_http_port
    get_current_image_tag

    if [ -n "$REQUESTED_HTTP_PORT" ]; then
        # first precedence
        HTTP_PORT=$REQUESTED_HTTP_PORT
    elif [ -n "$CURRENT_HTTP_PORT" -a "$CURRENT_HTTP_PORT" != ':' ]; then
        # second precedence
        HTTP_PORT=$CURRENT_HTTP_PORT
    else
        # third precedence
        HTTP_PORT=$DEFAULT_HTTP_PORT
    fi
    # if there was a :, it was probably IP:PORT; otherwise make sure there's a colon for port only
    [[ $HTTP_PORT =~ : ]] || HTTP_PORT=":$HTTP_PORT"

    if [ -n "$REQUESTED_TAG" ]; then
        # first precedence
        TAG=$REQUESTED_TAG
    elif [ -n "$GIT_TAG" ]; then 
        # second precedence
        TAG=$GIT_TAG
    elif [ -n "$CURRENT_TAG" ]; then
        # third precedence
        TAG=$CURRENT_TAG
    else
        # forth precedence
        TAG=$DEFAULT_TAG
    fi

    IMAGE=$IMAGE_BASE:$TAG

    docker_compose_yml_tmpl | 
        sed "s/__DOCKER_PROJECT__/$DOCKER_PROJECT/" |
        sed "s|__IMAGE__|$IMAGE|" |
        sed "s/__CONTAINER__/$CONTAINER/" |
        sed "s/__HTTP_PORT__/$HTTP_PORT/"
}

docker_compose_yml_tmpl() {
    cat<<EOF
name: __DOCKER_PROJECT__
services:
  web:
    container_name: __CONTAINER__
    image: __IMAGE__
    restart: unless-stopped
    networks:
      - ohb
    ports:
      - __HTTP_PORT__:80
    volumes:
      - ohb-htdocs:/opt/hamclock-backend/htdocs
    healthcheck:
      test: ["CMD", "curl", "-f", "-A", "healthcheck/1.0", "http://localhost:80/ham/HamClock/version.pl"]
      timeout: "5s"
      start_period: "20s"
    logging:
      options:
        max-size: "10m"
        max-file: "2"

networks:
  ohb:
    driver: bridge
    name: ohb
    enable_ipv6: true
    ipam:
     driver: default
    driver_opts:
      com.docker.network.bridge.name: ohb

volumes:
  ohb-htdocs:
    external: true
EOF

}

main "$@"
exit $RETVAL
