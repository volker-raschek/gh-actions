#!/usr/bin/env bash
#
# Copyright 2021 The terraform-docs Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail
set -o errtrace

cmd_args=()

IFS=' ' read -r -a output_format_args <<< "${INPUT_OUTPUT_FORMAT}"
cmd_args+=("${output_format_args[@]}")

IFS=' ' read -r -a extra_args <<< "${INPUT_ARGS}"
cmd_args+=("${extra_args[@]}")

if [ "${INPUT_CONFIG_FILE}" == "disabled" ]; then
    case "${INPUT_OUTPUT_FORMAT}" in
    "asciidoc" | "asciidoc table" | "asciidoc document")
        cmd_args+=("--indent" "${INPUT_INDENTION}")
    ;;

    "markdown" | "markdown table" | "markdown document")
        cmd_args+=("--indent" "${INPUT_INDENTION}")
    ;;
    *)
        echo "::error No output format defined" 1>&2 && exit 1
    ;;
    esac

    if [ -z "${INPUT_TEMPLATE}" ]; then
        default_template="<!-- BEGIN_TF_DOCS -->\n{{ .Content }}\n<!-- END_TF_DOCS -->"
        echo "::debug Define default template: ${default_template}"
        INPUT_TEMPLATE="${default_template}"
    fi
fi

INPUT_GIT_PUSH_USER_NAME="${INPUT_GIT_PUSH_USER_NAME:-"github-actions[bot]"}"
INPUT_GIT_PUSH_USER_EMAIL="${INPUT_GIT_PUSH_USER_EMAIL:-"github-actions[bot]@users.noreply.github.com"}"

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-"$(pwd)"}"
if [ -n "${INPUT_GIT_SUB_DIR}" ]; then
    GITHUB_WORKSPACE="${GITHUB_WORKSPACE}/${INPUT_GIT_SUB_DIR}"
    echo "::info Using non-standard GITHUB_WORKSPACE of ${GITHUB_WORKSPACE}"
fi


# trap_add is a function that allows `trap` to be extended with additional function calls. By default, the trap program
# can only execute or reserve one function per process signal.
#
# For example, the following trap_add commands leads to the following trap command:
#
#   $ trap_add 'echo "foo"' EXIT ERR SIGINT
#   $ trap_add 'echo "bar"' EXIT ERR SIGINT
#   $ trap 'echo "foo"\necho "bar"' EXIT ERR SIGINT
function trap_add() {
    local trap_command
    trap_command="${1}"

    shift 1
    for trap_add_name in "${@}"; do
        trap -- "$(
            # helper function to get existing trap command from output of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; }
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
            # print the new trap command
            printf '%s\n' "${trap_command}"
        )" "${trap_add_name}" || echo "ERROR: unable to add to trap ${trap_add_name}"
    done
}

function git_setup() {
    # When the runner maps the $GITHUB_WORKSPACE mount, it is owned by the runner
    # user while the created folders are owned by the container user, causing this
    # error. Issue description here: https://github.com/actions/checkout/issues/766
    git config --global --add safe.directory "${GITHUB_WORKSPACE}"

    # Check whether Git user information is available. If so, compare it with the
    # passed information. If they match, do nothing. If they do not match, save
    # them temporarily, change them to the passed values and restore the
    # original state when exiting the script.
    BACKUP_GIT_PUSH_USER_NAME="$(git config --global user.name)"
    if [ "${BACKUP_GIT_PUSH_USER_NAME}" != "${INPUT_GIT_PUSH_USER_NAME}" ]; then
        git_config "user.name" "${INPUT_GIT_PUSH_USER_NAME}"
        trap_add 'git_config "user.name" "${BACKUP_GIT_PUSH_USER_NAME}"' EXIT ERR INT
    fi

    BACKUP_GIT_PUSH_USER_EMAIL="$(git config --global user.email)"
    if [ "${BACKUP_GIT_PUSH_USER_EMAIL}" != "${INPUT_GIT_PUSH_USER_EMAIL}" ]; then
        git_config "user.email" "${INPUT_GIT_PUSH_USER_EMAIL}"
        trap_add 'git_config "user.email" "${BACKUP_GIT_PUSH_USER_EMAIL}"' EXIT ERR INT
    fi

    git fetch --depth=1 origin +refs/tags/*:refs/tags/* || true
}

function git_config() {
    local attribute
    attribute=$1

    local value
    value=$2

    git config --global "${attribute}" "${value}"
    echo "::debug git config --global '${attribute}' '${value}'"
}

function git_add() {
    local file
    file="$1"
    git add "${file}"
    if [ "$(git status --porcelain | grep "$file" | grep -c -E '([MA]\W).+')" -eq 1 ]; then
        echo "::debug Added ${file} to git staging area"
    else
        echo "::debug No change in ${file} detected"
    fi
}

function git_status() {
    git status --porcelain | grep -c -E '([MA]\W).+' || true
}

function git_commit() {
    if [ "$(git_status)" -eq 0 ]; then
        echo "::debug No files changed, skipping commit"
        exit 0
    fi

    echo "::debug Following files will be committed"
    git status -s

    local args=(
        -m "${INPUT_GIT_COMMIT_MESSAGE}"
    )

    if [ "${INPUT_GIT_PUSH_SIGN_OFF}" = "true" ]; then
        args+=("-s")
    fi

    git commit "${args[@]}"
}

function update_doc() {
    local working_dir
    working_dir="$1"
    echo "::debug working_dir=${working_dir}"

    local exec_args
    exec_args=( "${cmd_args[@]}" )

    if [ -n "${INPUT_CONFIG_FILE}" ] && [ "${INPUT_CONFIG_FILE}" != "disabled" ]; then
        local config_file

        if [ -f "${INPUT_CONFIG_FILE}" ]; then
            config_file="${INPUT_CONFIG_FILE}"
        else
            config_file="${working_dir}/${INPUT_CONFIG_FILE}"
        fi

        echo "::debug config_file=${config_file}"
        exec_args+=(--config "${config_file}")
    fi

    if [ "${INPUT_OUTPUT_METHOD}" == "inject" ] || [ "${INPUT_OUTPUT_METHOD}" == "replace" ]; then
        echo "::debug output_mode=${INPUT_OUTPUT_METHOD}"
        exec_args+=(--output-mode "${INPUT_OUTPUT_METHOD}")

        echo "::debug output_file=${INPUT_OUTPUT_FILE}"
        exec_args+=(--output-file "${INPUT_OUTPUT_FILE}")
    fi

    if [ -n "${INPUT_TEMPLATE}" ]; then
        exec_args+=("--output-template" "${INPUT_TEMPLATE}")
    fi

    if [ "${INPUT_RECURSIVE}" = "true" ]; then
        if [ -n "${INPUT_RECURSIVE_PATH}" ]; then
            exec_args+=(--recursive)
            exec_args+=(--recursive-path "${INPUT_RECURSIVE_PATH}")
        fi
    fi

    exec_args+=("${working_dir}")

    echo "::debug terraform-docs" "${exec_args[@]}"
    if ! terraform-docs "${exec_args[@]}"; then
        exit $?
    fi

    if [ "${INPUT_OUTPUT_METHOD}" == "inject" ] || [ "${INPUT_OUTPUT_METHOD}" == "replace" ]; then
        git_add "${working_dir}/${OUTPUT_FILE}"
    fi
}

# go to git repository
cd "${GITHUB_WORKSPACE}"

git_setup

if [ -f "${GITHUB_WORKSPACE}/${INPUT_ATLANTIS_FILE}" ]; then
    # Parse an atlantis yaml file
    for line in $(yq e '.projects[].dir' "${GITHUB_WORKSPACE}/${INPUT_ATLANTIS_FILE}"); do
        update_doc "${line//- /}"
    done
elif [ -n "${INPUT_FIND_DIR}" ] && [ "${INPUT_FIND_DIR}" != "disabled" ]; then
    # Find all tf
    for project_dir in $(find "${INPUT_FIND_DIR}" -name '*.tf' -exec dirname {} \; | uniq); do
        update_doc "${project_dir}"
    done
else
    # Split INPUT_WORKING_DIR by commas
    for project_dir in ${INPUT_WORKING_DIR//,/ }; do
        update_doc "${project_dir}"
    done
fi

# always set num_changed output
set +e
num_changed=$(git_status)
set -e

if [ -n "${GITHUB_OUTPUT}" ]; then
    echo "num_changed=${num_changed}" >> "${GITHUB_OUTPUT}"
fi

if [ "${INPUT_GIT_PUSH}" = "true" ]; then
    git_commit
    git push
else
    if [ "${INPUT_FAIL_ON_DIFF}" = "true" ] && [ "${num_changed}" -ne 0 ]; then
        echo "::error ::Uncommitted change(s) has been found!" 1>&2
        exit 1
    fi
fi

exit 0
