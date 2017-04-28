#!/bin/bash

SCRIPT_NAME='octodns'

matches_debug() {
  if [ -z "$DEBUG" ]; then
    return 1
  fi
  if [[ $SCRIPT_NAME == "$DEBUG" ]]; then
    return 0
  fi
  return 1
}

debug() {
  local cyan='\033[0;36m'
  local no_color='\033[0;0m'
  local message="$@"
  matches_debug || return 0
  (>&2 echo -e "[${cyan}${SCRIPT_NAME}${no_color}]: $message")
}

script_directory(){
  local source="${BASH_SOURCE[0]}"
  local dir=""

  while [ -h "$source" ]; do # resolve $source until the file is no longer a symlink
    dir="$( cd -P "$( dirname "$source" )" && pwd )"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  done

  dir="$( cd -P "$( dirname "$source" )" && pwd )"

  echo "$dir"
}

assert_required_information() {
  local domain="$1"
  local zone_name="$2"

  if [ -n "$domain" ] && [ -n "$zone_name" ]; then
    return 0
  fi

  if [ -z "$domain" ]; then
    echo "dns.json file was missing a '.domain' property"
  fi

  if [ -z "$zone_name" ]; then
    echo "dns.json file was missing a '.zoneName' property"
  fi

  exit 1
}

assert_required_params() {
  local dns_json_path="$1"

  if [ -n "$dns_json_path" ] && [ -r "$dns_json_path" ]; then
    return 0
  fi

  usage

  if [ -z "$dns_json_path" ]; then
    echo "Missing </path/to/dns.json>"
  elif [ ! -r "$dns_json_path" ]; then
    echo "File at </path/to/dns.json> is either not a file, or is unreadable"
  fi

  exit 1
}

usage(){
  echo "USAGE: ${SCRIPT_NAME}"
  echo ''
  echo 'Description: ...'
  echo ''
  echo 'Arguments:'
  echo '  -h, --help       print this help text'
  echo '  -n, --dry-run    do a dry run'
  echo '  -v, --version    print the version'
  echo ''
  echo 'Environment:'
  echo '  DEBUG            print debug output'
  echo ''
}

version(){
  local directory
  directory="$(script_directory)"

  if [ -f "$directory/VERSION" ]; then
    cat "$directory/VERSION"
  else
    echo "unknown-version"
  fi
}

generate_change(){
  local dns_json_path name template
  dns_json_path="$1"
  name="$2"

  read -r -d '' template <<'EOF'
  {
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": null,
      "Type": "SRV",
      "TTL": 300,
      "ResourceRecords": []
    }
  }
EOF

  # domain="$(get_domain "$dns_json_path")"
  hostname="$name.$domain"
  num_entries="$(jq ".srvRecords[\"$name\"] | length" "$dns_json_path")"

  # format_change "$domain" "$hostname" "${entries[@]}"
  template="$(echo "$template" | jq --arg hostname "$hostname" '.ResourceRecordSet.Name = $hostname')"

  for i in $(seq 1 "$num_entries"); do
    let "index = i - 1"

    priority="$(jq --raw-output ".srvRecords[\"$name\"][$index] | .priority" "$dns_json_path")"
    weight="$(jq --raw-output ".srvRecords[\"$name\"][$index] | .weight" "$dns_json_path")"
    port="$(jq --raw-output ".srvRecords[\"$name\"][$index] | .port" "$dns_json_path")"
    hostname="$(jq --raw-output ".srvRecords[\"$name\"][$index] | .hostname" "$dns_json_path")"

    record="$priority $weight $port $hostname"

    template="$(echo "$template" | jq --arg record "$record" '.ResourceRecordSet.ResourceRecords += [{"Value": $record}]')"
  done

  echo "$template"
}

generate_change_batch() {
  local dns_json_path names output change
  dns_json_path="$1"

  names=( $(get_srv_names "$dns_json_path") ) || return 1
  output='{"Comment": "Stack Updating DNS", "Changes": []}'

  for name in "${names[@]}"; do
    change="$(generate_change "$dns_json_path" "$name")" || return 1
    output="$(echo "$output" | jq --argjson change "$change" '.Changes += [$change]')"
  done

  echo "$output"
}

get_domain() {
  local dns_json_path="$1"

  jq --raw-output '.domain' "$dns_json_path"
}

get_route53_hosted_zone(){
  local zone_name="$1"

  aws route53 list-hosted-zones \
  | jq --raw-output ".HostedZones | map(select(.Name == \"$zone_name\"))[0].Id"
}

get_srv_names(){
  local dns_json_path="$1"

  jq -r '.srvRecords | keys | .[]' "$dns_json_path"
}

get_zone_name() {
  local dns_json_path="$1"

  jq --raw-output '.zoneName' "$dns_json_path"
}


main() {
  # Define args up here
  local dns_json_path dry_run

  while [ "$1" != "" ]; do
    local param="$1"
    # local value="$2"
    case "$param" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        version
        exit 0
        ;;
      # Arg with value
      # -x | --example)
      #   example="$value"
      #   shift
      #   ;;
      # Arg without value
      -n | --dry-run)
        dry_run='true'
        ;;
      *)
        if [ "${param::1}" == '-' ]; then
          echo "ERROR: unknown parameter \"$param\""
          usage
          exit 1
        fi
        # Set main arguments
        if [ -z "$dns_json_path" ]; then
          dns_json_path="$param"
        # elif [ -z "$main_arg_2"]; then
        #   main_arg_2="$param"
        fi
        ;;
    esac
    shift
  done

  assert_required_params "$dns_json_path"

  domain="$(get_domain "$dns_json_path")" || exit 1
  zone_name="$(get_zone_name "$dns_json_path")" || exit 1
  assert_required_information "$domain" "$zone_name"

  route53_hosted_zone=$(get_route53_hosted_zone "$zone_name")
  if [ -z "$route53_hosted_zone" ] || [ "$route53_hosted_zone" == "null" ]; then
    echo "Could not find route53 hosted zone for: $zone_name" 2>&1
    exit 1
  fi

  change_batch="$(generate_change_batch "$dns_json_path")"

  if [ "$dry_run" == "true" ]; then
    echo "$change_batch"
    exit 0
  fi

  tmpfile="$(mktemp)"
  echo "$change_batch" > "$tmpfile"

  aws route53 \
    change-resource-record-sets \
    --hosted-zone-id "$route53_hosted_zone" \
    --change-batch "file://$tmpfile" || fatal 'Unable to create route'
}

main "$@"
