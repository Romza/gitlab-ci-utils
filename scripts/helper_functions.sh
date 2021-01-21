error() {
  echo -e "\033[0;31mERROR: $1\033[0m" >&2
}

warn() {
  echo -e "\033[0;33mWARNING: $1\033[0m" >&2
}

info() {
  echo -e "\033[0;32mINFO: $1\033[0m" >&2
}

fail() {
  error "$1"
  exit 1
}

read_config() {
  local path="$CI_PROJECT_DIR/$1"
  if [ -s "$path" ]; then
    source "$path"
    if grep -q -v '^#' "$path"; then
      export $(grep -v '^#' "$path" | cut -d= -f1)
    fi
  else
    fail "Config $path does not exist or is empty"
  fi
}

check_empty_vars() {
  fail_flag=false
  for var in "$@"; do
    if [ -z "$(eval echo \$"$var")" ]; then
      error "Variable $var is not set."
      fail_flag=true
    fi
  done
  if [ "$fail_flag" = true ]; then
    exit 1
  fi
}

get_branch_config_path() {
  if [ -f "$CI_PROJECT_DIR/ci-branch-config/$CI_COMMIT_REF_NAME.env" ]; then
    echo ci-branch-config/"$CI_COMMIT_REF_NAME.env"
  else
    # Some projects use "release" branches in format `${ENVIRONMENT_NAME}-${SEMVER_TAG}`
    local environment_name=$(echo "$CI_COMMIT_REF_NAME" | sed -E 's/(.+)-[0-9x]+\.[0-9]+\.[0-9]+/\1/')
    if [ -f "$CI_PROJECT_DIR/ci-branch-config/$environment_name.env" ]; then
      echo ci-branch-config/"$environment_name.env"
    fi
  fi
}

read_branch_config() {
  read_config ci-branch-config/common.env
  local branch_config_path=$(get_branch_config_path)
  if [ -n "$branch_config_path" ]; then
    read_config "$branch_config_path"
  fi
}

# we can't do this in `variables:`, because branch configuration
# is loaded after resolving `$GCP_PROJECT_ID` variable
get_image_name() {
  read_branch_config
  echo "$DOCKER_REGISTRY_URL/$GCP_PROJECT_ID/$CI_PROJECT_NAME"
}

# because it is not possible to use variables in `rules:exist`
# see also https://gitlab.com/gitlab-org/gitlab/issues/16733
skip_if_brach_config_missing() {
  if [ -z "$(get_branch_config_path)" ]; then
    info "There is no ci-branch-config/$CI_COMMIT_REF_NAME.env for the current branch, job will be skipped."
    exit 0
  fi
}

docker_login() {
  echo "$GCP_SA_KEY" | base64 -d > "$GCP_SA_KEY_JSON_PATH"
  docker login -u _json_key --password-stdin eu.gcr.io < "$GCP_SA_KEY_JSON_PATH"
}

# run Docker Compose CI override
docker_compose_ci() {
  local command=$@

  cd "$CI_PROJECT_DIR/docker-compose"
  DOCKER_IMAGE_NAME="$(get_image_name)" docker-compose -p "$DOCKER_COMPOSE_PROJECT_NAME" \
      -f docker-compose.yml -f docker-compose.ci.yml $command
  cd "$OLDPWD"
}

init_ssh_agent() {
  if [ -n "$SECRET_GITLAB_SSH_KEY" ]; then
    eval $(ssh-agent -s) && echo "$SECRET_GITLAB_SSH_KEY" | ssh-add - && \
    mkdir -p ~/.ssh && ssh-keyscan -t rsa gitlab.ack.ee >> ~/.ssh/known_hosts
  fi
}

commits_count() {
  curl -s --HEAD --header "PRIVATE-TOKEN: $SECRET_GITLAB_ACCESS_TOKEN" "${CI_SERVER_URL}/api/v4/projects/$CI_PROJECT_ID/repository/commits?per_page=1&ref_name=$CI_COMMIT_REF_NAME" | grep x-total: | cut -d " " -f2
}

generate_changelog() {
  # fetch all commits between current SHA and SHA-1 (previous commit on autodeploy branches should be merge commit so it returns list of changes since last merge == since last version)
  curl -s -H "PRIVATE-TOKEN: ${SECRET_GITLAB_ACCESS_TOKEN}" "${CI_SERVER_URL}/api/v4/projects/${CI_PROJECT_ID}/repository/compare?from=${CI_COMMIT_SHA}~1&to=${CI_COMMIT_SHA}" |
  grep -Eo '"title":".*?",' | # find all commit titles
  sed -n 's|.*"title":"\([^"]*\)".*|• \1|p' | # extract and format commit titles
  tail -n +2 # remove first title which is duplicate of the last one (see raw output of curl above)
}

gcm_write_log() {
  local log_name=$1
  local payload=$2

  gcloud logging write $log_name "$payload" --project=$GCP_PROJECT_ID --payload-type=json
}

gcm_write_metric() {
  # metric format documentation: https://cloud.google.com/monitoring/custom-metrics/creating-metrics#writing-ts
  local metric_type=$1
  local labels=$2
  local value=$3
  local value_type=$4
  local metric_kind=${5:-GAUGE}

  curl -sS \
    -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json; charset=utf-8' \
    "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries" \
    -d "{
      \"timeSeries\": [
        {
          \"metric\": {
            \"type\":\"custom.googleapis.com/$metric_type\",
            \"labels\": $labels
          },
          \"resource\": {
            \"type\": \"global\",
            \"labels\": {
              \"project_id\":\"$GCP_PROJECT_ID\"
            }
          },
          \"metricKind\": \"$metric_kind\",
          \"points\": [
            {
              \"interval\": {
                \"endTime\":\"$(date -Iseconds)\"
              },
              \"value\": {
                \"$value_type\": $value
              }
            }
          ]
        }
      ]
    }"
}

# first parameter is slack channel name to send the status to
# second parameter is slack webhook url
# third parameter is message body
# fourth parameter is message header for success
# fifth parameter is message header for failure
# sixth parameter is message header for canceled job
send_slack_status() {
    local message_header_canceled
    local message_header_failed
    local message_header_success
    local slack_msg_header
    local slack_msg_body

   if [ -z "${6}" ]; then
   message_header_canceled=":white_check_mark: ${TARGET} for ${ENVIRONMENT} environment succeeded"
   else
   message_header_canceled=$6
   fi

   if [ -z "${5}" ]; then
   message_header_failed=":x: ${TARGET} for ${ENVIRONMENT} environment failed"
   else
   message_header_failed=$5
   fi

   if [ -z "${4}" ]; then
   message_header_success=":white_check_mark: ${TARGET} for ${ENVIRONMENT} environment succeeded"
   else
   message_header_success=$4
   fi

    # canceled status is not currently (gitlab 13.7) handled in after_script phase, but support is planned in some future release, so this if should start working once the support is added
    if [[ "${CI_JOB_STATUS}" == "canceled" ]]; then
    	slack_msg_header=${message_header_canceled}
    elif [[ "${CI_JOB_STATUS}" == "failed" ]]; then
    	slack_msg_header=${message_header_failed}
    else
        slack_msg_header=${message_header_success}
    fi

    # Populate slack message body
    if [ -z "${3}" ]; then
    slack_msg_body="<${CI_JOB_URL}|Job URL> by ${GITLAB_USER_NAME} ${CI_COMMIT_TITLE}"
    else
    slack_msg_body=$3
    fi

    payload=$(cat <<SLACK
            {
                "channel": "$1",
                "blocks": [
                  {
                          "type": "section",
                          "text": {
                                  "type": "mrkdwn",
                                  "text": "${slack_msg_header}"
                          }
                  },
                  {
                          "type": "divider"
                  },
                  {
                          "type": "section",
		                  "text": {
                                  "type": "mrkdwn",
                                  "text": "${slack_msg_body}"
                          }
                  }
                ]
}
SLACK
)

    # send status message to slack
    curl -X POST                             \
        --data-urlencode "payload=$payload"  \
        "$2"
} 