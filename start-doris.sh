#!/bin/bash

# Default version
DORIS_QUICK_START_VERSION="2.1.9"
# Custom image flag
USE_CUSTOM_IMAGES=false
CUSTOM_FE_IMAGE=""
CUSTOM_BE_IMAGE=""

# Cross-cluster shared network and config
USE_SHARED_NET=false
SHARED_NET_NAME="doris_xnet"
SHARED_NET_SUBNET="172.30.0.0/16"

# Single shared external network for all clusters (simplest mode)
USE_SINGLE_SHARED_NET=false
SINGLE_SHARED_NET_NAME="doris_shared"
SINGLE_SHARED_NET_SUBNET="172.30.0.0/16"
ACTUAL_ONE_NET_SUBNET=""
SHARED_BASE_PREFIX=""

# Cluster size
FE_NUM=1
BE_NUM=1

# Action: start (default) or stop
ACTION="start"
case "$1" in
  start)
    shift
    ;;
  stop|down)
    ACTION="stop"
    shift
    ;;
  "" )
    # default start
    ;;
  -* )
    # options only, keep default ACTION
    ;;
  *)
    echo "Invalid action: $1" >&2
    SHOW_HELP=1
    ;;
esac

# Parse parameters
MULTI_CLUSTERS_SPEC=""
while getopts "v:c:f:b:m:xXN:S:h" opt; do
  case $opt in
    v)
      DORIS_QUICK_START_VERSION="$OPTARG"
      ;;
    c)
      USE_CUSTOM_IMAGES=true
      if [[ -n "$OPTARG" ]]; then
        CUSTOM_FE_IMAGE="doris.fe:$OPTARG"
        CUSTOM_BE_IMAGE="doris.be:$OPTARG"
      else
        echo "Error: Custom version format should be like: -c 3.0.6"
        exit 1
      fi
      ;;
    f)
      FE_NUM="$OPTARG"
      ;;
    b)
      BE_NUM="$OPTARG"
      ;;
    m)
      MULTI_CLUSTERS_SPEC="$OPTARG"
      ;;
    x)
      USE_SHARED_NET=true
      ;;
    X)
      USE_SINGLE_SHARED_NET=true
      ;;
    N)
      SINGLE_SHARED_NET_NAME="$OPTARG"
      ;;
    S)
      SINGLE_SHARED_NET_SUBNET="$OPTARG"
      ;;
    h)
      SHOW_HELP=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      SHOW_HELP=1
      ;;
  esac
done

if [[ -n "$SHOW_HELP" ]]; then
  cat <<'EOF'
Usage: start-doris.sh [start|stop] [options]

Actions:
  start                    Start a Doris cluster (default)
  stop                     Stop cluster(s). With -m, stop specified cluster names

Options:
  -v <version>             Use official Apache Doris images (e.g. -v 2.1.9)
  -c <custom_version>      Use custom images doris.fe:<ver> and doris.be:<ver> (e.g. -c 3.0.6)
  -f <num>                 Number of FE instances (single-cluster mode; default: 1)
  -b <num>                 Number of BE instances (single-cluster mode; default: 1)
  -m <spec>                Multi-cluster mode. Examples:
                           -m 'cluster1=1fe3be,cluster2=1fe1be'
                           -m '1fe3be,1fe1be' (auto-named: cluster1, cluster2)
                           With 'stop', pass names: -m 'cluster1,cluster2'
  -x                       Enable cross-cluster shared network '${SHARED_NET_NAME}' (for inter-cluster BE/FE reachability)
  -X                       Run ALL clusters in ONE external network (simplest). Use with -N/-S
  -N <name>                Name of the single shared external network (default: ${SINGLE_SHARED_NET_NAME})
  -S <subnet>              Subnet of the single shared network (default: ${SINGLE_SHARED_NET_SUBNET})
  -h                       Show this help

Notes:
  - Each cluster uses its own compose file: docker-compose-doris-<name>.yaml and project name '-p <name>'
  - Subnets per cluster: 172.20.90.0/24, 172.20.91.0/24, ... in order
  - FE1 IP: <SUBNET_BASE>.2, BE1 IP: <SUBNET_BASE>.(fe_n+2)

Examples:
  # Start single cluster with custom images
  ./start-doris.sh -c 3-local -f 1 -b 3

  # Start two clusters
  ./start-doris.sh -c 3-local -m 'cluster1=1fe3be,cluster2=1fe1be'

  # Stop specific clusters
  ./start-doris.sh stop -m 'cluster1,cluster2'
EOF
  exit 0
fi

# Validate FE/BE numbers
if ! [[ "$FE_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: -f fe_num must be a positive integer"
  exit 1
fi
if ! [[ "$BE_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: -b be_num must be a positive integer"
  exit 1
fi

# Check system type (Linux only)
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" != "Linux" ]]; then
  echo "Error: Unsupported operating system [$OS_TYPE], only Linux is supported"
  exit 1
fi

# Check Docker environment
if ! command -v docker &> /dev/null; then
  echo "Error: Docker environment not detected, please install Docker first"
  exit 1
fi

# Check docker-compose
COMPOSE_CMD=""
if command -v docker-compose &> /dev/null; then
  COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null; then
  COMPOSE_CMD="docker compose"
else
  echo "Error: docker-compose plugin or docker-compose command is required"
  exit 1
fi

# Handle stop action early
if [[ "$ACTION" == "stop" ]]; then
  if [[ -n "$MULTI_CLUSTERS_SPEC" ]]; then
    IFS=',' read -ra stop_items <<< "$MULTI_CLUSTERS_SPEC"
    for raw_item in "${stop_items[@]}"; do
      item=$(echo "$raw_item" | xargs)
      [[ -z "$item" ]] && continue
      name="$item"
      compose_file="docker-compose-doris-${name}.yaml"
      if [[ -f "$compose_file" ]]; then
        $COMPOSE_CMD -p "$name" -f "$compose_file" down
        echo "Doris cluster '$name' stopped."
      else
        echo "Warning: $compose_file not found. Skipped '$name'."
      fi
    done
    exit 0
  else
    if [[ -f docker-compose-doris.yaml ]]; then
      $COMPOSE_CMD -f docker-compose-doris.yaml down
      echo "Doris cluster stopped."
      exit 0
    else
      echo "Error: docker-compose-doris.yaml not found in $(pwd). Use -m to stop specific clusters."
      exit 1
    fi
  fi
fi

# Determine which images to use
if [[ "$USE_CUSTOM_IMAGES" == "true" ]]; then
  FE_IMAGE="$CUSTOM_FE_IMAGE"
  BE_IMAGE="$CUSTOM_BE_IMAGE"
else
  FE_IMAGE="apache/doris:fe-${DORIS_QUICK_START_VERSION}"
  BE_IMAGE="apache/doris:be-${DORIS_QUICK_START_VERSION}"
fi

# Prepare shared network and config if enabled (ignored if single shared net is enabled)
if [[ "$USE_SHARED_NET" == "true" && "$USE_SINGLE_SHARED_NET" != "true" ]]; then
  # Create external shared network if not exists
  if ! docker network inspect "$SHARED_NET_NAME" &>/dev/null; then
    docker network create --driver bridge --subnet "$SHARED_NET_SUBNET" "$SHARED_NET_NAME"
  fi
  # Detect actual subnet of the shared network (in case it already existed with a different subnet)
  ACTUAL_SHARED_SUBNET=$(docker network inspect "$SHARED_NET_NAME" --format '{{ (index .IPAM.Config 0).Subnet }}')
  if [[ -z "$ACTUAL_SHARED_SUBNET" || "$ACTUAL_SHARED_SUBNET" == "<no value>" ]]; then
    ACTUAL_SHARED_SUBNET="$SHARED_NET_SUBNET"
  fi
fi

# Prepare single shared external network (one network for all clusters)
if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
  if ! docker network inspect "$SINGLE_SHARED_NET_NAME" &>/dev/null; then
    docker network create --driver bridge --subnet "$SINGLE_SHARED_NET_SUBNET" "$SINGLE_SHARED_NET_NAME"
  fi
  ACTUAL_ONE_NET_SUBNET=$(docker network inspect "$SINGLE_SHARED_NET_NAME" --format '{{ (index .IPAM.Config 0).Subnet }}')
  if [[ -z "$ACTUAL_ONE_NET_SUBNET" || "$ACTUAL_ONE_NET_SUBNET" == "<no value>" ]]; then
    ACTUAL_ONE_NET_SUBNET="$SINGLE_SHARED_NET_SUBNET"
  fi
  # Derive A.B prefix from subnet (assumes /16 for best results)
  SHARED_BASE_PREFIX=$(echo "$ACTUAL_ONE_NET_SUBNET" | awk -F"[./]" '{print $1 "." $2}')
fi

# Generate and start clusters
if [[ -n "$MULTI_CLUSTERS_SPEC" ]]; then
  IFS=',' read -ra cluster_items <<< "$MULTI_CLUSTERS_SPEC"
  idx=0
  for raw_item in "${cluster_items[@]}"; do
    item=$(echo "$raw_item" | xargs)
    [[ -z "$item" ]] && continue
    idx=$((idx+1))
    name="cluster${idx}"
    spec="$item"
    if [[ "$item" == *"="* ]]; then
      name="${item%%=*}"
      spec="${item#*=}"
    fi
    if [[ "$spec" =~ ^([0-9]+)fe([0-9]+)be$ ]]; then
      fe_n="${BASH_REMATCH[1]}"; be_n="${BASH_REMATCH[2]}"
    else
      echo "Error: invalid cluster spec '$spec'. Expected like 1fe3be" >&2
      exit 1
    fi
    third_octet=$((90 + idx - 1))
    if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
      SUBNET_BASE="${SHARED_BASE_PREFIX}.${third_octet}"
      SUBNET_CIDR="${SUBNET_BASE}.0/24"
    else
      SUBNET_BASE="172.20.${third_octet}"
      SUBNET_CIDR="${SUBNET_BASE}.0/24"
    fi

    FE_SERVERS_LIST=""
    for (( i=1; i<=fe_n; i++ )); do
      fe_ip_octet=$((1 + i))
      fe_ip="${SUBNET_BASE}.${fe_ip_octet}"
      entry="fe${i}:${fe_ip}:9010"
      if [[ -z "$FE_SERVERS_LIST" ]]; then
        FE_SERVERS_LIST="$entry"
      else
        FE_SERVERS_LIST="${FE_SERVERS_LIST},${entry}"
      fi
    done

    compose_file="docker-compose-doris-${name}.yaml"
    {
      echo "version: \"3.9\""
      echo "networks:"
      if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
        echo "  ${SINGLE_SHARED_NET_NAME}:"
        echo "    external: true"
      else
        echo "  doris_net:"
        echo "    driver: bridge"
        echo "    ipam:"
        echo "      config:"
        echo "        - subnet: ${SUBNET_CIDR}"
        if [[ "$USE_SHARED_NET" == "true" ]]; then
          echo "  ${SHARED_NET_NAME}:"
          echo "    external: true"
        fi
      fi
      echo "services:"

      for (( i=1; i<=fe_n; i++ )); do
        fe_ip_octet=$((1 + i))
        fe_ip="${SUBNET_BASE}.${fe_ip_octet}"
        echo "  fe${i}:"
        echo "    image: ${FE_IMAGE}"
        echo "    hostname: fe${i}"
        if [[ "$i" -eq 1 ]]; then
          expose_8030=true; expose_9030=true; expose_9010=true
          command -v ss &>/dev/null && {
            ss -ltn | awk '{print $4}' | grep -q ":8030$" && expose_8030=false || true
            ss -ltn | awk '{print $4}' | grep -q ":9030$" && expose_9030=false || true
            ss -ltn | awk '{print $4}' | grep -q ":9010$" && expose_9010=false || true
          }
          if [[ "$expose_8030" == true || "$expose_9030" == true || "$expose_9010" == true ]]; then
            echo "    ports:"
            if [[ "$expose_8030" == true ]]; then echo "      - 8030:8030"; fi
            if [[ "$expose_9030" == true ]]; then echo "      - 9030:9030"; fi
            if [[ "$expose_9010" == true ]]; then echo "      - 9010:9010"; fi
          fi
        fi
        echo "    environment:"
        echo "      - FE_SERVERS=${FE_SERVERS_LIST}"
        echo "      - FE_ID=${i}"
        echo "    networks:"
        if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
          echo "      ${SINGLE_SHARED_NET_NAME}:"
          echo "        ipv4_address: ${fe_ip}"
        else
          echo "      doris_net:"
          echo "        ipv4_address: ${fe_ip}"
          if [[ "$USE_SHARED_NET" == "true" ]]; then
            echo "      ${SHARED_NET_NAME}:"
          fi
        fi
      done

      for (( j=1; j<=be_n; j++ )); do
        be_ip_octet=$((1 + fe_n + j))
        be_ip="${SUBNET_BASE}.${be_ip_octet}"
        echo "  be${j}:"
        echo "    image: ${BE_IMAGE}"
        echo "    hostname: be${j}"
        if [[ "$j" -eq 1 ]]; then
          expose_8040=true; expose_9050=true
          command -v ss &>/dev/null && {
            ss -ltn | awk '{print $4}' | grep -q ":8040$" && expose_8040=false || true
            ss -ltn | awk '{print $4}' | grep -q ":9050$" && expose_9050=false || true
          }
          if [[ "$expose_8040" == true || "$expose_9050" == true ]]; then
            echo "    ports:"
            if [[ "$expose_8040" == true ]]; then echo "      - 8040:8040"; fi
            if [[ "$expose_9050" == true ]]; then echo "      - 9050:9050"; fi
          fi
        fi
        echo "    environment:"
        echo "      - FE_SERVERS=${FE_SERVERS_LIST}"
        echo "      - BE_ADDR=${be_ip}:9050"
        echo "    depends_on:"
        echo "      - fe1"
        echo "    networks:"
        if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
          echo "      ${SINGLE_SHARED_NET_NAME}:"
          echo "        ipv4_address: ${be_ip}"
        else
          echo "      doris_net:"
          echo "        ipv4_address: ${be_ip}"
          if [[ "$USE_SHARED_NET" == "true" ]]; then
            echo "      ${SHARED_NET_NAME}:"
          fi
        fi
      done
    } > "$compose_file"

    $COMPOSE_CMD -p "$name" -f "$compose_file" up -d

    if [[ "$USE_CUSTOM_IMAGES" == "true" ]]; then
      echo "[${name}] Doris cluster started successfully using custom images:"
      echo "  FE Image: ${FE_IMAGE}"
      echo "  BE Image: ${BE_IMAGE}"
    else
      echo "[${name}] Doris cluster started successfully, version: ${DORIS_QUICK_START_VERSION}"
    fi

    fe1_ip="${SUBNET_BASE}.2"
    be1_ip="${SUBNET_BASE}.$((fe_n + 2))"
    echo "[${name}] Cluster size: ${fe_n} FE(s), ${be_n} BE(s)"
    echo "[${name}] Manage commands:"
    echo "  Stop cluster: ./start-doris.sh stop -m ${name}"
    echo "  View logs: $COMPOSE_CMD -p ${name} -f ${compose_file} logs -f"
    echo "  Connect to FE (fe1): mysql -uroot -P9030 -h${fe1_ip}"
    echo "  FE Web UI: http://${fe1_ip}:8030"
    echo "  BE1 Web UI: http://${be1_ip}:8040"
  done
else
  # Single cluster path (backward compatible)
  # Generate docker-compose configuration
  if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
    SUBNET_BASE="${SHARED_BASE_PREFIX}.90"
    SUBNET_CIDR="${SUBNET_BASE}.0/24"
  else
    SUBNET_BASE="172.20.90"
    SUBNET_CIDR="${SUBNET_BASE}.0/24"
  fi

  FE_SERVERS_LIST=""
  for (( i=1; i<=FE_NUM; i++ )); do
    fe_ip_octet=$((1 + i))
    fe_ip="${SUBNET_BASE}.${fe_ip_octet}"
    entry="fe${i}:${fe_ip}:9010"
    if [[ -z "$FE_SERVERS_LIST" ]]; then
      FE_SERVERS_LIST="$entry"
    else
      FE_SERVERS_LIST="${FE_SERVERS_LIST},${entry}"
    fi
  done

  {
    echo "version: \"3.9\""
    echo "networks:"
    if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
      echo "  ${SINGLE_SHARED_NET_NAME}:"
      echo "    external: true"
    else
      echo "  doris_net:"
      echo "    driver: bridge"
      echo "    ipam:"
      echo "      config:"
      echo "        - subnet: ${SUBNET_CIDR}"
      if [[ "$USE_SHARED_NET" == "true" ]]; then
        echo "  ${SHARED_NET_NAME}:"
        echo "    external: true"
      fi
    fi
    echo "services:"

    for (( i=1; i<=FE_NUM; i++ )); do
      fe_ip_octet=$((1 + i))
      fe_ip="${SUBNET_BASE}.${fe_ip_octet}"
      echo "  fe${i}:"
      echo "    image: ${FE_IMAGE}"
      echo "    hostname: fe${i}"
      if [[ "$i" -eq 1 ]]; then
        expose_8030=true; expose_9030=true; expose_9010=true
        command -v ss &>/dev/null && {
          ss -ltn | awk '{print $4}' | grep -q ":8030$" && expose_8030=false || true
          ss -ltn | awk '{print $4}' | grep -q ":9030$" && expose_9030=false || true
          ss -ltn | awk '{print $4}' | grep -q ":9010$" && expose_9010=false || true
        }
        if [[ "$expose_8030" == true || "$expose_9030" == true || "$expose_9010" == true ]]; then
          echo "    ports:"
          if [[ "$expose_8030" == true ]]; then echo "      - 8030:8030"; fi
          if [[ "$expose_9030" == true ]]; then echo "      - 9030:9030"; fi
          if [[ "$expose_9010" == true ]]; then echo "      - 9010:9010"; fi
        fi
      fi
      echo "    environment:"
      echo "      - FE_SERVERS=${FE_SERVERS_LIST}"
      echo "      - FE_ID=${i}"
      echo "    networks:"
      if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
        echo "      ${SINGLE_SHARED_NET_NAME}:"
        echo "        ipv4_address: ${fe_ip}"
      else
        echo "      doris_net:"
        echo "        ipv4_address: ${fe_ip}"
        if [[ "$USE_SHARED_NET" == "true" ]]; then
          echo "      ${SHARED_NET_NAME}:"
        fi
      fi
    done

    for (( j=1; j<=BE_NUM; j++ )); do
      be_ip_octet=$((1 + FE_NUM + j))
      be_ip="${SUBNET_BASE}.${be_ip_octet}"
      echo "  be${j}:"
      echo "    image: ${BE_IMAGE}"
      echo "    hostname: be${j}"
      if [[ "$j" -eq 1 ]]; then
        expose_8040=true; expose_9050=true
        command -v ss &>/dev/null && {
          ss -ltn | awk '{print $4}' | grep -q ":8040$" && expose_8040=false || true
          ss -ltn | awk '{print $4}' | grep -q ":9050$" && expose_9050=false || true
        }
        if [[ "$expose_8040" == true || "$expose_9050" == true ]]; then
          echo "    ports:"
          if [[ "$expose_8040" == true ]]; then echo "      - 8040:8040"; fi
          if [[ "$expose_9050" == true ]]; then echo "      - 9050:9050"; fi
        fi
      fi
      echo "    environment:"
      echo "      - FE_SERVERS=${FE_SERVERS_LIST}"
      echo "      - BE_ADDR=${be_ip}:9050"
      echo "    depends_on:"
      echo "      - fe1"
      echo "    networks:"
      if [[ "$USE_SINGLE_SHARED_NET" == "true" ]]; then
        echo "      ${SINGLE_SHARED_NET_NAME}:"
        echo "        ipv4_address: ${be_ip}"
      else
        echo "      doris_net:"
        echo "        ipv4_address: ${be_ip}"
        if [[ "$USE_SHARED_NET" == "true" ]]; then
          echo "      ${SHARED_NET_NAME}:"
        fi
      fi
    done
  } > docker-compose-doris.yaml

  $COMPOSE_CMD -f docker-compose-doris.yaml up -d

  if [[ "$USE_CUSTOM_IMAGES" == "true" ]]; then
    echo "Doris cluster started successfully using custom images:"
    echo "  FE Image: ${FE_IMAGE}"
    echo "  BE Image: ${BE_IMAGE}"
  else
    echo "Doris cluster started successfully, version: ${DORIS_QUICK_START_VERSION}"
  fi

  fe1_ip="${SUBNET_BASE}.2"
  be1_ip="${SUBNET_BASE}.$((FE_NUM + 2))"
  echo "Cluster size: ${FE_NUM} FE(s), ${BE_NUM} BE(s)"
  echo "You can manage the cluster using the following commands:"
  echo "  Stop cluster: ./start-doris.sh stop"
  echo "  View logs: $COMPOSE_CMD -f docker-compose-doris.yaml logs -f"
  echo "  Connect to FE (fe1): mysql -uroot -P9030 -h${fe1_ip}"
  echo "  FE Web UI: http://${fe1_ip}:8030"
  echo "  BE1 Web UI: http://${be1_ip}:8040"
fi