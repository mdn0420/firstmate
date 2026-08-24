#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for a secondmate seed's project position.
# Source only.
#
# A project entry is either a bare `<name>`, meaning a project this home has
# cloned under projects/ and the secondmate home clones for itself, or
# `<name>=<absolute-path>`, meaning an EXISTING checkout that is REGISTERED
# rather than cloned. The `<name>=<value>` shape deliberately matches the
# `<project>=<origin-url>` convention bin/fm-remote-home-seed.sh already uses,
# so the project position has one syntax rather than two.
#
# This parser owns only the STRING shape of an entry: a safe project name, and
# for an external entry an absolute, traversal-free, delimiter-free path. It
# deliberately touches no filesystem, because the same string is parsed by the
# charter scaffold (bin/fm-brief.sh), which runs before any home exists, and by
# the seeder (bin/fm-home-seed.sh), which owns the filesystem and boundary
# validation an external checkout additionally has to pass.

FM_PROJECT_SPEC_NAME=
FM_PROJECT_SPEC_EXTERNAL=
FM_PROJECT_SPEC_ERROR=
FM_PROJECT_SPEC_NAMES=()
FM_PROJECT_SPEC_EXTERNALS=()

# Parse one entry into FM_PROJECT_SPEC_NAME plus FM_PROJECT_SPEC_EXTERNAL, which
# is empty for a cloned entry and the absolute checkout path for an external one.
fm_project_spec_parse() {
  local spec=$1 name external
  FM_PROJECT_SPEC_NAME=
  FM_PROJECT_SPEC_EXTERNAL=
  FM_PROJECT_SPEC_ERROR=
  name=${spec%%=*}
  external=
  case "$spec" in *=*) external=${spec#*=} ;; esac
  case "$name" in
    ''|*[!A-Za-z0-9._-]*)
      FM_PROJECT_SPEC_ERROR="invalid project name: $name"
      return 1
      ;;
  esac
  if [ -n "$external" ]; then
    case "$external" in
      /*) ;;
      *)
        FM_PROJECT_SPEC_ERROR="project $name external checkout must be an absolute path: $external"
        return 1
        ;;
    esac
    case "/$external/" in
      */../*|*/./*)
        FM_PROJECT_SPEC_ERROR="project $name external checkout contains traversal components: $external"
        return 1
        ;;
    esac
    # Repeated slashes are ordinary in a path assembled from an environment
    # variable and mean exactly what the single-slash form means, so collapse
    # them rather than refusing a path the filesystem accepts.
    while case "$external" in *'//'*) true ;; *) false ;; esac; do
      external=${external//\/\///}
    done
    # The path is written into a data/projects.md line and read back by name, so
    # refuse anything that would break that record or the registry suffix.
    case "$external" in
      *';'*|*')'*|*$'\n'*|*$'\r'*|*$'\t'*)
        FM_PROJECT_SPEC_ERROR="project $name external checkout contains record delimiters: $external"
        return 1
        ;;
    esac
    external=${external%/}
    [ -n "$external" ] || {
      FM_PROJECT_SPEC_ERROR="project $name external checkout cannot be the filesystem root"
      return 1
    }
  elif [ "$spec" != "$name" ]; then
    FM_PROJECT_SPEC_ERROR="project $name external checkout path is empty; pass $name=<absolute-path> or a bare $name"
    return 1
  fi
  FM_PROJECT_SPEC_NAME=$name
  FM_PROJECT_SPEC_EXTERNAL=$external
}

# Parse a whole project list into FM_PROJECT_SPEC_NAMES and
# FM_PROJECT_SPEC_EXTERNALS, refusing duplicates. A name may not appear twice,
# so a list can never be half cloned and half external for the same project.
# The results are output globals rather than caller-named arrays, matching the
# rest of bin/'s shared parsers and keeping this readable on bash 3.2.
# Usage: fm_project_spec_parse_list <spec>...
fm_project_spec_parse_list() {
  local spec i
  FM_PROJECT_SPEC_NAMES=()
  FM_PROJECT_SPEC_EXTERNALS=()
  FM_PROJECT_SPEC_ERROR=
  for spec in "$@"; do
    fm_project_spec_parse "$spec" || return 1
    for ((i = 0; i < ${#FM_PROJECT_SPEC_NAMES[@]}; i++)); do
      if [ "${FM_PROJECT_SPEC_NAMES[$i]}" = "$FM_PROJECT_SPEC_NAME" ]; then
        FM_PROJECT_SPEC_ERROR="project $FM_PROJECT_SPEC_NAME is listed more than once; each project may be cloned or registered as an external checkout, not both"
        return 1
      fi
    done
    FM_PROJECT_SPEC_NAMES+=("$FM_PROJECT_SPEC_NAME")
    FM_PROJECT_SPEC_EXTERNALS+=("$FM_PROJECT_SPEC_EXTERNAL")
  done
}
