#!/usr/bin/env bash

build_auth_header_args() {
  AUTH_ARGS=()

  if [[ -n "${AUTH_HEADER:-}" ]]; then
    AUTH_ARGS=(-H "${AUTH_HEADER}")
    return
  fi

  if [[ -n "${AUTH_TOKEN:-}" ]]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${AUTH_TOKEN}")
  fi
}

describe_auth_mode() {
  if [[ -n "${AUTH_HEADER:-}" ]]; then
    echo "custom header"
    return
  fi

  if [[ -n "${AUTH_TOKEN:-}" ]]; then
    echo "bearer token"
    return
  fi

  echo "none"
}

print_response_or_fail() {
  local response=$1
  local status_code=${response##*$'\n'HTTP_STATUS:}
  local response_body=${response%$'\n'HTTP_STATUS:*}

  if [[ -n "${response_body}" ]]; then
    printf '%s\n' "${response_body}"
  fi

  if [[ ! "${status_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "Request failed with HTTP ${status_code}" >&2
    exit 1
  fi
}