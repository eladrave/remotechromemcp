#!/usr/bin/env bash

render_template() {
  if (($# < 2 || ($# - 2) % 2 != 0)); then
    echo "usage: render_template SOURCE DESTINATION [NAME VALUE ...]" >&2
    return 2
  fi

  local source=$1
  local destination=$2
  shift 2

  if [[ ! -f "$source" ]]; then
    echo "template source is not a regular file: $source" >&2
    return 1
  fi
  if [[ "$destination" != /* || "$destination" == *$'\n'* ]]; then
    echo "template destination must be an absolute single-line path: $destination" >&2
    return 1
  fi
  if [[ -L "$destination" || ! -d "$(dirname "$destination")" ]]; then
    echo "unsafe template destination: $destination" >&2
    return 1
  fi

  cp -- "$source" "$destination" || return 1
  while (($#)); do
    local name=$1 value=$2
    shift 2
    if [[ ! "$name" =~ ^[A-Z0-9_]+$ ]]; then
      echo "invalid template variable name: $name" >&2
      return 1
    fi
    if [[ "$value" == *$'\n'* ]]; then
      echo "template values must not contain newlines: $name" >&2
      return 1
    fi
    local escaped=${value//\\/\\\\}
    escaped=${escaped//&/\\&}
    escaped=${escaped//|/\\|}
    sed -i "s|@${name}@|${escaped}|g" "$destination" || return 1
  done
  if grep -Eq '@[A-Z0-9_]+@' "$destination"; then
    echo "unresolved template variable in $destination" >&2
    return 1
  fi
}
