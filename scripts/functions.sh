#!/bin/bash

MESH_CONTAINER_NAME="dstack-service-mesh"
VPC_CLIENT_CONTAINER_NAME="dstack-vpc-client"
VPC_API_SERVER_CONTAINER_NAME="dstack-vpc-api-server"
VPC_SERVER_CONTAINER_NAME="vpc-server"

HEALTHCHECK_SCRIPT="/var/run/dstack-healthcheck.sh"

node_name_for_instance() {
    local configured_name="${1:-node}"
    local instance_id="${2:-}"
    local instance_suffix
    local normalized_name
    local max_name_length

    instance_suffix=$(printf '%s' "$instance_id" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]//g' \
        | cut -c1-12)
    if [ -z "$instance_suffix" ]; then
        return 1
    fi

    normalized_name=$(printf '%s' "$configured_name" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-*//; s/-*$//')
    if [ -z "$normalized_name" ]; then
        normalized_name="node"
    fi

    max_name_length=$((63 - 1 - ${#instance_suffix}))
    normalized_name=$(printf '%s' "$normalized_name" \
        | cut -c1-"$max_name_length" \
        | sed 's/-*$//')

    printf '%s-%s\n' "$normalized_name" "$instance_suffix"
}

healthcheck_cmd() {
    local cmd=$1
    cat >$HEALTHCHECK_SCRIPT <<EOF
$cmd || exit 1
EOF
    chmod +x $HEALTHCHECK_SCRIPT
}

healthcheck_cmd_append() {
    local cmd=$1
    cat >>$HEALTHCHECK_SCRIPT <<EOF
$cmd || exit 1
EOF
}

healthcheck() {
    local append=false
    
    # Check for -a flag
    if [ "$1" = "-a" ]; then
        append=true
        shift
    fi
    
    local kind=$1
    local arg=$2
    
    # Build the command based on kind
    case $kind in
        container)
            local cmd="[ \"\$(docker inspect --format='{{.State.Health.Status}}' $arg 2>/dev/null)\" = \"healthy\" ]"
            ;;
        url)
            local cmd="wget --quiet --tries=1 --spider '$arg'"
            ;;
        cmd)
            shift # Remove 'cmd'
            local cmd="$*" # Everything else is the command
            ;;
        *)
            echo "Usage: healthcheck [-a] container|url|cmd <args>"
            return 1
            ;;
    esac
    
    # Use existing functions
    if [ "$append" = true ]; then
        healthcheck_cmd_append "$cmd"
    else
        healthcheck_cmd "$cmd"
    fi
}
