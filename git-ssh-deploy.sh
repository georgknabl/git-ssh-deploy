#!/bin/bash

CONFIG_FILE=".git/config"
LOG_FILE=".git-ssh-deploy-state-commit-id.log"

function ensure_git_repo_root() {
    if [[ ! -d ".git" ]]; then
        echo "Error: This script must be run from the root of a Git repository."
        exit 1
    fi
}

function is_repository_dirty() {
    [[ -n "$(git status --porcelain)" ]]
}

function abort_if_dirty_repository() {
    if is_repository_dirty; then
        echo "Error: The local repository has uncommitted changes. Please commit or stash them before proceeding."
        exit 1
    fi
}

# $1: environment name
function is_valid_environment_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# $1: commit_id
function is_valid_commit_id() {
    # regex check
    if [[ ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
      return 1
    fi

    return 0
}

# $1: commit_id
function does_commit_id_exist_locally() {
    local commit_id="$1"

    # Check if the commit ID exists in the repository
    if git cat-file -e "$commit_id" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# $1: remote_commit_id
function abort_if_remote_commit_not_found_locally() {
    local remote_commit_id="$1"

    if ! does_commit_id_exist_locally "$remote_commit_id"; then
        echo "Error: Remote commit ID $remote_commit_id not found locally."
        exit 1
    fi
}

# $1: syncroot
# other args: file paths
function filter_by_syncroot() {
    local syncroot="$1"
    shift            # shift off the first argument
    local filelist=("$@")
    local result=()

    # If syncroot is empty, do nothing special
    if [[ -z "$syncroot" ]]; then
        echo "${filelist[@]}"
        return
    fi

    for file in "${filelist[@]}"; do
        # Keep only files that begin with syncroot
        if [[ "$file" == "$syncroot"* ]]; then
            result+=("$file")
        fi
    done

    echo "${result[@]}"
}

# $1: syncroot
# $2: exclude_list
# other args: file paths
function filter_excludes() {
    local syncroot="$1"
    local exclude_list="$2"
    shift 2
    local filelist=("$@")
    local result=()

    local dir=""
    if [[ -n "$syncroot" ]]; then
        dir="$syncroot/"
    fi

    # If exclude_list is empty, we can just return filelist untouched
    if [[ -z "$exclude_list" ]]; then
        echo "${filelist[@]}"
        return
    fi

    IFS=',' read -ra excludes <<< "$exclude_list"
    for file in "${filelist[@]}"; do
        local keep=true
        for exclude_entry in "${excludes[@]}"; do
            local exclude_path="${dir}${exclude_entry}"  # Full path to exclude
            if [[ -d "$exclude_path" ]]; then
                # If exclude is a directory, remove files inside it
                # If file starts with that directory, exclude it
                if [[ "$file" == "$exclude_path"* ]]; then
                    keep=false
                    break
                fi
            elif [[ -f "$exclude_path" ]]; then
                # If exclude is a file, remove only that exact file
                if [[ "$file" == "$exclude_path" ]]; then
                    keep=false
                    break
                fi
#            else
#                # The exclude path might not exist locally as a dir or file;
#                # some users just provide a string.
#                if [[ "$file" == "$exclude_path"* ]]; then
#                    keep=false
#                    break
#                fi
            fi
        done
        if [[ "$keep" == true ]]; then
            result+=("$file")
        fi
    done

    echo "${result[@]}"
}

# $1: syncroot
# $2: includes_list
# other args: file paths
function apply_includes() {
    local syncroot="$1"
    local includes_list="$2"
    shift 2
    local filelist=("$@")
    local result=("${filelist[@]}")  # Start with existing list

    # If includes_list is empty, return as is
    if [[ -z "$includes_list" ]]; then
        echo "${result[@]}"
        return
    fi

    IFS=',' read -ra includes <<< "$includes_list"
    for include_entry in "${includes[@]}"; do
        local include_path="${syncroot}${include_entry}"
        if [[ -d "$include_path" ]]; then
            # Add all files under this directory
            while IFS= read -r found_file; do
                result+=("$found_file")
            done < <(find "$include_path" -type f)
        elif [[ -f "$include_path" ]]; then
            # Add single file
            result+=("$include_path")
#        else
#            # Possibly user provided a path that doesn't exist locally,
#            # or is a pattern, etc.
#            :
        fi
    done

    echo "${result[@]}"
}

# $@: list of file paths
function deduplicate_and_filter() {
    local inputfiles=("$@")

    # Deduplicate by sorting + unique
    local unique=($(printf "%s\n" "${inputfiles[@]}" | sort -u))

    local filtered=()
    for file in "${unique[@]}"; do
        # Filter out dangerous paths: ../
        if [[ "$file" =~ (^|/)../ ]]; then
            continue
        fi
        filtered+=("$file")
    done

    echo "${filtered[@]}"
}

# $1: environment name
# $2: remote_commit_id
# ECHOES: two arrays, separated by '|':
#         1) files_to_upload
#         2) files_to_remove
function get_file_paths_list_to_push_or_delete() {
    local env_name="$1"
    local remote_commit_id="$2"

    local local_commit_id=$(git rev-parse HEAD)
    # If commit IDs match, no changes at all
    if [[ -n "$remote_commit_id" && "$remote_commit_id" == "$local_commit_id" ]]; then
        echo ""
        return
    fi

    local syncroot=$(get_config "$env_name" "syncroot")
    local excluded_paths_raw=$(get_config "$env_name" "excludedpaths" || echo "")
    local included_paths_raw=$(get_config "$env_name" "includedpaths")

    # Ensure syncroot ends with a slash if set
    if [[ -n "$syncroot" && "${syncroot: -1}" != "/" ]]; then
        syncroot="$syncroot/"
    fi

    # Prepare arrays for changed files (A/M) and removed files (D, or old side of R)
    local changed_files=()
    local deleted_files=()

    # If no remote_commit_id, treat all tracked files as new
    if [[ -z "$remote_commit_id" ]]; then
        while IFS= read -r file; do
            changed_files+=("$file")
        done < <(git ls-tree --name-only -r HEAD)
    else
        # Use --find-renames to detect renames
        while IFS=$'\t' read -r status old_path new_path; do
            case "$status" in
                A|M)
                    # old_path is the file
                    changed_files+=("$old_path")
                    ;;
                D)
                    deleted_files+=("$old_path")
                    ;;
                R*)
                    # For rename lines, we get status like R100 plus two paths
                    # old_path -> new_path
                    deleted_files+=("$old_path")
                    changed_files+=("$new_path")
                    ;;
            esac
        done < <(git diff --find-renames --name-status "$remote_commit_id")
    fi

    # Filter by syncroot
    if [[ -n "$syncroot" ]]; then
        changed_files=($(filter_by_syncroot "$syncroot" "${changed_files[@]}"))
        deleted_files=($(filter_by_syncroot "$syncroot" "${deleted_files[@]}"))
    fi

    # Excludes
    if [[ -n "$excluded_paths_raw" ]]; then
        changed_files=($(filter_excludes "$syncroot" "$excluded_paths_raw" "${changed_files[@]}"))
        deleted_files=($(filter_excludes "$syncroot" "$excluded_paths_raw" "${deleted_files[@]}"))
    fi

    # Includes
    if [[ -n "$included_paths_raw" ]]; then
        changed_files=($(apply_includes "$syncroot" "$included_paths_raw" "${changed_files[@]}"))
    fi

    # Remove duplicates, filter for dangerous paths, etc.
    changed_files=($(deduplicate_and_filter "${changed_files[@]}"))
    deleted_files=($(deduplicate_and_filter "${deleted_files[@]}"))

    # Return them as a single string: changed|deleted
    echo "${changed_files[*]}|${deleted_files[*]}"
}

# $1: environment name
# $2: config key
function get_config() {
    local env_name="$1"
    local config_key="$2"

    local value=$(git config --get "git-ssh-deploy.$env_name.$config_key")
    # echo "git-ssh-deploy.$env_name.$config_key -> $value"

    # set defaults
    if [[ -z "$value" ]]; then
        case "$config_key" in
            "port")
                value="22"
                ;;
            "predeploycommand")
                value=""
                ;;
            "postdeploycommand")
                value=""
                ;;
            "syncroot")
                value=""
                ;;
            "excludedpaths")
                value=""
                ;;
            "includedpaths")
                value=""
                ;;
        esac
    fi

    echo "$value"
}

# $1: environment name
function abort_if_environment_is_not_properly_configured() {
    local env_name="$1"

    # check if environment does only contain valid characters
    if ! is_valid_environment_name "$env_name"; then
        echo "Error: Environment name $env_name contains invalid characters. Only alphanumeric characters, dashes and underscores are allowed."
        exit 1
    fi

    local host=$(get_config "$env_name" "host")
    local user=$(get_config "$env_name" "user")
    local port=$(get_config "$env_name" "port")
    local remote_directory=$(get_config "$env_name" "remotedirectory")
    local syncroot=$(get_config "$env_name" "syncroot")
    local healthcheckurl=$(get_config "$env_name" "healthcheckurl")
    local excluded_paths=$(get_config "$env_name" "excludedpaths")
    local included_paths=$(get_config "$env_name" "includedpaths")

    local dir=$(pwd)
    if [ -n "$syncroot" ]; then
        dir="$dir/$syncroot"
    fi

    if [[ -z "$host" || -z "$user" || -z "$remote_directory" || ! -d "$dir" ]]; then
        echo "Error: Environment $env_name is not properly configured. host, user, remotedirectory must be set and if syncroot is set, the directory must exist."
        exit 1
    fi

    if [ ! -w "$dir" ]; then
        echo "Error: Directory $dir is not writable."
        exit 1
    fi

    # check for invalid characters
    if [[ "$host" =~ [^a-zA-Z0-9_.-] ]]; then
        echo "Error: Host $host contains invalid characters. Only alphanumeric characters, dots, underscores and dashes are allowed."
        exit 1
    fi
    if [[ "$user" =~ [^a-zA-Z0-9_-] ]]; then
        echo "Error: User $user contains invalid characters. Only alphanumeric characters, dashes and underscores are allowed."
        exit 1
    fi
    if [[ "$port" =~ [^0-9] ]]; then
        echo "Error: Port $port is not a valid number."
        exit 1
    fi
    if [[ "$remote_directory" =~ [^a-zA-Z0-9_./-] || "$remote_directory" =~ \.\. ]]; then
        echo "Error: Remote directory $remote_directory contains invalid characters. Only alphanumeric characters, dashes, underscores and slashes are allowed. No double dots allowed."
        exit 1
    fi
    if [[ -n "$syncroot" && "$syncroot" =~ [^a-zA-Z0-9_./-] || "$syncroot" =~ \.\. ]]; then
        echo "Error: Sync root $syncroot contains invalid characters. Only alphanumeric characters, dashes, underscores and slashes are allowed. No double dots allowed."
        exit 1
    fi
    if [[ -n "$excluded_paths" && "$excluded_paths" =~ [^a-zA-Z0-9_./,-] || "$excluded_paths" =~ \.\. ]]; then
        echo "Error: Excluded paths $excluded_paths contain invalid characters. Only alphanumeric characters, dashes, underscores and slashes are allowed. No double dots allowed."
        exit 1
    fi
    if [[ -n "$included_paths" && "$included_paths" =~ [^a-zA-Z0-9_./,-] || "$included_paths" =~ \.\. ]]; then
        echo "Error: Included paths $included_paths contain invalid characters. Only alphanumeric characters, dashes, underscores and slashes are allowed. No double dots allowed."
        exit 1
    fi
    if [[ -n "$healthcheckurl" && ( ! "$healthcheckurl" =~ ^https?:\/\/[a-zA-Z0-9_.\/?\&=%-]+$ ) ]]; then
        echo "Error: Health check URL $healthcheckurl is not a valid URL."
        exit 1
    fi

}

# $1: environment name
# return: 0 if connection is successful, 1 otherwise
function check_connection() {
    local env_name="$1"

    local host=$(get_config "$env_name" "host")
    local port=$(get_config "$env_name" "port")
    local user=$(get_config "$env_name" "user")
    local remote_call_result=$(ssh -p "$port" "$user@$host" "echo 'Connection successful'." 2>/dev/null)

    if [ "$remote_call_result" != "Connection successful." ]; then
        echo "Error: Could not connect to the server. Please make sure the host, port and user are correct and that calling 'ssh -p $port $user@$host' works and host identification is established."
        return 1
    fi

    # check if remotedirectory exists
    local remote_directory=$(get_config "$env_name" "remotedirectory")
    local remote_call_result=$(ssh -p "$port" "$user@$host" "[ -d '$remote_directory' ] && echo 'Directory exists'" 2>/dev/null)
    if [[ "$remote_call_result" != "Directory exists" ]]; then
        echo "Error: Remote directory $remote_directory does not exist."
        return 1
    fi

    # check if remotedirectory is writable
    remote_call_result=$(ssh -p "$port" "$user@$host" "[ -w '$remote_directory' ] && echo 'Directory is writable'" 2>/dev/null)
    if [[ "$remote_call_result" != "Directory is writable" ]]; then
        echo "Error: Remote directory $remote_directory is not writable by user $user."
        return 1
    fi

    return 0
}

# $1: environment name
# $2: command
# options: --output (Default, Return only output if successful), --error (Return error messages if failed), --quiet (No output, just status code), --all (Output both output and error)
function execute_remote_command() {
    local env_name="$1"
    local command="$2"
    local output=""
    local error=""
    local exit_code=0

    local host=$(get_config "$env_name" "host")
    local port=$(get_config "$env_name" "port")
    local user=$(get_config "$env_name" "user")

    # Execute the command via SSH and capture output and errors
    output=$(ssh -p "$port" "$user@$host" "$command" 2> >(error=$(cat); declare -p error >/dev/null))
    exit_code=$?

    # Decide behavior based on options
    case "$3" in
        --output)  # Return only output if successful
            if [[ $exit_code -eq 0 ]]; then
                echo "$output"
            else
                return $exit_code
            fi
            ;;
        --error)  # Return error messages if failed
            if [[ $exit_code -ne 0 ]]; then
                echo "$error" >&2
            fi
            return $exit_code
            ;;
        --quiet)  # No output, just status code
            return $exit_code
            ;;
        --all)  # Output both output and error
            echo "$output"
            if [[ $exit_code -ne 0 ]]; then
                echo "$error" >&2
            fi
            return $exit_code
            ;;
        *)  # Default to output-only if no flag is passed
            if [[ $exit_code -eq 0 ]]; then
                echo "$output"
            else
                return $exit_code
            fi
            ;;
    esac
}

## return 0 if verbose flag is present in arguments, 1 otherwise
#function do_args_have_verbose_flag() {
#    for arg in "$@"; do
#        if [[ "$arg" == "-v" ]]; then
#            return 0
#        fi
#    done
#
#    return 1
#}

# $1: environment name
function get_remote_commit_id() {
    local env_name="$1"
    local remote_root_path=$(get_config "$env_name" "remotedirectory")

    local output=$(execute_remote_command "$env_name" "cat $remote_root_path/$LOG_FILE" --output)

    # Check if the command succeeded
    if [[ $? -ne 0 ]]; then
        # Command failed, return nothing
        echo ""
        return 1
    fi

    # validate commit id
    if ! is_valid_commit_id "$output"; then
        return 1
    fi

    # Command succeeded, return the output
    echo "$output"
    return 0
}

# $1: environment name
function status() {
    local env_name="$1"
    abort_if_environment_is_not_properly_configured "$env_name"

    local remote_commit_id=$(get_remote_commit_id "$env_name")
    local pwd=$(pwd)

    local remote_commit_id_exists_locally=0
    local diffs
    if [[ -n "$remote_commit_id" ]]; then
        remote_commit_id_exists_locally=$(does_commit_id_exist_locally "$remote_commit_id" && echo 1 || echo 0)
        if [ $remote_commit_id_exists_locally -eq 1 ]; then
            # Get changed and deleted files
            diffs=$(get_file_paths_list_to_push_or_delete "$env_name" "$remote_commit_id")
        fi
    else
        diffs=$(get_file_paths_list_to_push_or_delete "$env_name")
    fi

    # Parse them (split on '|')
    local changed_part=()
    local deleted_part=()
    local files_to_upload=()
    local files_to_remove=()
    if [[ -n "$diffs" ]]; then
        IFS='|' read -r changed_part deleted_part <<< "$diffs"
        IFS=' ' read -r -a files_to_upload <<< "$changed_part"
        IFS=' ' read -r -a files_to_remove <<< "$deleted_part"
    fi

    local local_path=$pwd
    if [[ -n "$(get_config "$env_name" "syncroot")" ]]; then
        local local_path="$pwd/$(get_config "$env_name" "syncroot")"
    fi

    echo "CONFIG:"
    echo "environment: $env_name"
    echo "ssh command: ssh -p $(get_config "$env_name" "port") $(get_config "$env_name" "user")@$(get_config "$env_name" "host")"
#    echo "server: $(get_config "$env_name" "host")"
#    echo "port: $(get_config "$env_name" "port")"
#    echo "user: $(get_config "$env_name" "user")"
    echo "path mapping: $local_path -> $(get_config "$env_name" "remotedirectory")"
    echo ""
    echo "LOCAL STATE:"
    echo "branch: $(git rev-parse --abbrev-ref HEAD)"
    echo "HEAD commit ID: $(git rev-parse HEAD)"
    echo "has uncommitted changes: $(is_repository_dirty && echo 'yes' || echo 'no')"
    echo ""
    echo "REMOTE STATE:"
    if check_connection "$env_name"; then
        echo "can connect: yes"
        if [[ -n "$remote_commit_id" ]]; then
            echo "remote commit ID: $remote_commit_id"
            if [[ "$remote_commit_id_exists_locally" -eq 1 ]]; then
                echo "remote commit ID found locally: yes"
            else
                echo "remote commit ID found locally: no"
            fi
        else
            echo "remote commit ID: not set or invalid value"
        fi

        if is_repository_dirty; then
            echo "files to upload/remove: None. Repository has uncommitted changes. Please commit first."
        else
            if [[ -n "$remote_commit_id" && $remote_commit_id_exists_locally -eq 0 ]]; then
                echo "number of files to upload/remove: None. Unknown remote commit id."
            else
                echo "number of files to upload/remove: ${#files_to_upload[@]}/${#files_to_remove[@]}"
            fi
            if [[ -n "$remote_commit_id" && $remote_commit_id_exists_locally -eq 0 ]]; then
                echo "files to upload/remove: None. Unknown remote commit id."
            elif [[ ${#files_to_upload[@]} -gt 0 || ${#files_to_remove[@]} -gt 0 ]]; then
                echo "files to upload (+) or remove (-):"
                for file in "${files_to_upload[@]}"; do
                    echo "+ $file"
                done
                for file in "${files_to_remove[@]}"; do
                    echo "- $file"
                done
            fi
        fi
    else
        echo "can connect: no"
    fi
}

# $1: environment name
# $2: commit id (if empty HEAD is used)
function write_remote_commit_id() {
    local env_name="$1"
    abort_if_environment_is_not_properly_configured "$env_name"

    local commit_id="$2"
    if [[ -z "$commit_id" ]]; then
        commit_id=$(git rev-parse HEAD)
    else
        if ! is_valid_commit_id "$commit_id"; then
            echo "Error: Invalid commit ID. Please provide the complete 40-character commit ID."
            exit 1
        fi
    fi

    if ! does_commit_id_exist_locally "$commit_id"; then
        echo "Error: Commit ID $commit_id does not exist locally."
        exit 1
    fi

    local remote_root_path=$(get_config "$env_name" "remotedirectory")

    execute_remote_command "$env_name" "echo $commit_id > $remote_root_path/$LOG_FILE" --quiet
    local remote_commit_id=$(get_remote_commit_id "$env_name")

    if [[ $? -ne 0 || "$remote_commit_id" != "$commit_id" ]]; then
        echo "Error: Could not create file $remote_root_path/$LOG_FILE. Check permissions."
        exit 1
    fi

    echo "Remote commit ID set to $commit_id."
}

# $1: environment name
function remove_remote_commit_id() {
    local env_name="$1"
    abort_if_environment_is_not_properly_configured "$env_name"

    local remote_root_path=$(get_config "$env_name" "remotedirectory")

    if [[ -z "$(get_remote_commit_id "$env_name")" ]]; then
        echo "Error: Remote commit ID not set. Does the file $remote_root_path/$LOG_FILE exist?"
        exit 1
    fi

    execute_remote_command "$env_name" "rm $remote_root_path/$LOG_FILE" --quiet

    if [[ $? -ne 0 || -n "$(get_remote_commit_id "$env_name")" ]]; then
        echo "Error: Could not remove file $remote_root_path/$LOG_FILE."
        exit 1
    fi

    echo "Remote commit ID log file removed from file $remote_root_path/$LOG_FILE."
}

# $1: environment name
# $2: commit id (if empty, deploy all)
function deploy() {
    local env_name="$1"
    local remote_commit_id="$2"
    local local_commit_id=$(git rev-parse HEAD)

    local syncroot=$(get_config "$env_name" "syncroot" || echo "")
    if [[ -n "$syncroot" && "${syncroot: -1}" != "/" ]]; then
        syncroot="$syncroot/"
    fi

    # check connection
    if ! check_connection "$env_name"; then
        echo "Error: Could not connect to the server."
        exit 1
    fi

    # Get changed and deleted files
    local diffs
    diffs=$(get_file_paths_list_to_push_or_delete "$env_name" "$remote_commit_id")

    # Parse them (split on '|')
    local changed_part=()
    local deleted_part=()
    local files_to_upload=()
    local files_to_remove=()
    if [[ -n "$diffs" ]]; then
        IFS='|' read -r changed_part deleted_part <<< "$diffs"
        IFS=' ' read -r -a files_to_upload <<< "$changed_part"
        IFS=' ' read -r -a files_to_remove <<< "$deleted_part"
    fi
    echo "files_to_upload: ${files_to_upload[@]}"
    echo "files_to_remove: ${files_to_remove[@]}"

    # If we have nothing to upload or remove, exit early
    if [[ ${#files_to_upload[@]} -eq 0 && ${#files_to_remove[@]} -eq 0 ]]; then
        echo "No changes to deploy."
        exit 0
    fi

    echo "Deploying to $env_name."

    # Create a tarball with the changed/added files only
    if [[ ${#files_to_upload[@]} -gt 0 ]]; then
        local tarball_name="git-ssh-deploy-$(date +%s).tar.gz"
        echo "Creating tar file ($tarball_name) for added/changed/renamed ${#files_to_upload[@]} file(s)."
        # Create tarball with files, stripping syncroot prefix if it exists
        # Create tarball using $files
        # COPYFILE_DISABLE=1 is used to prevent tar from including .DS_Store and other macOS metadata files like ._*
        if [[ -n "$syncroot" ]]; then
            local relative_files=()

            # Strip syncroot prefix from $files paths
            for file in "${files_to_upload[@]}"; do
                relative_files+=("${file#"$syncroot"}")
            done

            # Change directory to syncroot, create tarball, and return to previous directory
            (cd "$syncroot" && COPYFILE_DISABLE=1 tar -czf "../$tarball_name" --exclude="._*" --exclude=".DS_Store" "${relative_files[@]}")
        else
            # Fallback if no syncroot, tar $files directly
            COPYFILE_DISABLE=1 tar --exclude="._*" --exclude=".DS_Store" -czf "$tarball_name" "${files_to_upload[@]}"
        fi
        if [ $? -ne 0 ]; then
            echo "Error: Could not create tar-file. Aborting."
            exit 1
        fi
    fi

    # execute pre-deploy command
    local pre_deploy_command=$(get_config "$env_name" "predeploycommand")
    if [[ -n "$pre_deploy_command" ]]; then
        echo "Executing pre-deploy command"
        execute_remote_command "$env_name" "$pre_deploy_command" --output
        if [[ $? -ne 0 ]]; then
            echo "Error: Pre-deploy command failed. Aborting."
            exit 1
        fi
        echo "Pre-deploy command completed."
    fi

    # push tarball
    local remote_root_path=$(get_config "$env_name" "remotedirectory")
    echo "Uploading tar-file to remote server. Size: $(du -h "$tarball_name" | cut -f1)."
    scp -q -P $(get_config "$env_name" "port") "$tarball_name" "$(get_config "$env_name" "user")@$(get_config "$env_name" "host"):$remote_root_path/"
    if [[ $? -ne 0 ]]; then
        echo "Error: Could not upload tar-file to remote server. Aborting."
        exit 1
    fi

    # remove local tarball
    echo "Removing local tar-file."
    rm "$tarball_name"
    if [[ $? -ne 0 ]]; then
        echo "Error: Could not remove local tar-file. Please do that manually. Continuing."
    fi

    # extract tarball on remote server and remove it
    echo "Extracting tar-file on remote server and removing it."
    execute_remote_command "$env_name" "tar -xzf $remote_root_path/$tarball_name -C $remote_root_path && rm $remote_root_path/$tarball_name" --quiet
    if [[ $? -ne 0 ]]; then
        echo "Error: Could not extract and remove tar-file on remote server. Aborting."
        exit 1
    fi

    # Remove deleted or renamed-away files on remote
    if [[ ${#files_to_remove[@]} -gt 0 ]]; then
        echo "Removing ${#files_to_remove[@]} file(s) that were deleted or renamed locally."
        local remote_root_path=$(get_config "$env_name" "remotedirectory")
        for file in "${files_to_remove[@]}"; do
            if [[ -n "$syncroot" ]]; then
                local full_remote_path="$remote_root_path/${file#"$syncroot"}"
            else
                local full_remote_path="$remote_root_path/$file"
            fi
            execute_remote_command "$env_name" "rm -f $full_remote_path" --quiet
            if [[ $? -ne 0 ]]; then
                echo "Warning: Could not remove file $full_remote_path on remote server. Please do that manually. Continuing."
            fi

            # Recursively remove empty directories upward, but stop once we reach $remote_root_path
            local dir="$(dirname "$full_remote_path")"

            # In a loop, check if 'dir' is empty; if so, remove it and move upward.
            # Stop if dir == remote_root_path or dir == "/".
            while [[ "$dir" != "$remote_root_path" && "$dir" != "/" ]]; do
                # Check if the directory exists and is empty
                execute_remote_command "$env_name" "\
                    if [ -d '$dir' ] && [ \"\$(find '$dir' -mindepth 1 -maxdepth 1 | wc -l)\" -eq 0 ]; then
                        rmdir '$dir'
                    else
                        exit 2
                    fi" --quiet

                # If the exit code == 2, it means the directory was either non-empty or didn't exist,
                # so we break out of the loop
                if [[ $? -eq 2 ]]; then
                    break
                fi

                # Move up one directory level
                dir="$(dirname "$dir")"
            done
        done
    fi

    # write remote commit ID
    echo "Writing remote commit ID."
    write_remote_commit_id "$env_name" "$local_commit_id"
    if [[ $? -ne 0 ]]; then
        echo "Warning: Could not write remote commit ID. Please do that manually. Continuing."
    fi

    # execute post-deploy command
    local post_deploy_command=$(get_config "$env_name" "postdeploycommand")
    if [[ -n "$post_deploy_command" ]]; then
        echo "Executing post-deploy command."
        execute_remote_command "$env_name" "$post_deploy_command" --output
        if [[ $? -ne 0 ]]; then
            echo "Error: Pre-deploy command failed. Aborting."
            exit 1
        fi
        echo "Post-deploy command completed."
    fi

    # health check
    local health_check_url=$(get_config "$env_name" "healthcheckurl")
    if [[ -n "$health_check_url" ]]; then
        echo "Performing health check. URL: $health_check_url"
        if curl -s -I "$health_check_url" | head -n 1 | grep -q "HTTP/.* 2[0-9][0-9]"; then
            echo "Health check passed: A 2xx status code was returned."
        else
            echo "Health check failed: A 2xx status code was not found in the response."
            exit 1
        fi
    fi

    echo "Deployment completed."
}

# $1: environment name
function push_all() {
    local env_name="$1"
    abort_if_environment_is_not_properly_configured "$env_name"

    abort_if_dirty_repository

    deploy "$env_name"
}

# $1: environment name
function push_changes() {
    local env_name="$1"
    abort_if_environment_is_not_properly_configured "$env_name"

    abort_if_dirty_repository

    local remote_commit_id=$(get_remote_commit_id "$env_name")
    if [[ -z "$remote_commit_id" ]]; then
        echo "Error: Remote commit ID not set. Please run 'push_all' to start from scratch or manually set the remote id using 'write_remote_commit_id' first."
        exit 1
    fi
    abort_if_remote_commit_not_found_locally "$remote_commit_id"

    deploy "$env_name" "$remote_commit_id"
}

# $1: environment name
function create_default_config() {
    if ! is_valid_environment_name "$1"; then
        echo "Error: Invalid environment name."
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE does not exists."
        exit 1
    fi

    cat <<EOL >> $CONFIG_FILE

[git-ssh-deploy "$1"]
    host =
    user =
    port = 22
    # Directory on the remote server where the files will be uploaded. No trailing slash.
    remotedirectory = /var/www/html
    # Command to run on the remote server before deploying the files. Can be empty. Run multiple commands using "&&" for example.
    predeploycommand =
    # Command to run on the remote server after deploying the files. Can be empty. Run multiple commands using "&&" for example.
    postdeploycommand =
    # URL to check after deployment. Can be empty. Wrap the URL in double quotes if it contains special characters.
    healthcheckurl =
    # Local directory to sync with the remote server. If empty, the root of the repository is used. No trailing slash.
    syncroot =
    # Comma-separated list of paths to exclude from upload. Paths can be directories or files. Paths must be relative to syncroot if syncroot is set. Otherwise repository root is used. No starting or trailing slashes. No spaces after commas.
    excludedpaths =
    # Comma-separated list of paths to include in the every upload. Paths can be directories or files. Paths must be relative to syncroot if syncroot is set. Otherwise repository root is used. No starting or trailing slashes. No spaces after commas. Includes are run after excludes.
    includedpaths =
EOL
    echo "Default config added to $CONFIG_FILE."
}

function print_help() {
    echo "Usage: $0 <action> <environment> [<options or action-specific arguments>]"
    echo "Actions:"
    echo "  init_config               Add default config block to .git/config."
    echo "  status                    Shows state and connection information for given environment."
    echo "  push_all                  Upload all tracked files from scratch and set remote commit ID. Does not remove any other files."
    echo "  push                      Push changes based on Git diff and update remote commit ID."
    echo "  write_remote_commit_id    Manually set remote commit ID without pushing any files. Commit ID has to be set as third argument. If empty, HEAD commit ID is used."
    echo "  catchup                   Alias for write_remote_commit_id. Use without specifying the commit ID to use the HEAD commit ID. This states that the remote server is up to date with the local repository."
    echo "  remove_remote_commit_id   Remove remote commit ID log file."
    echo "Options:"
    echo "  -h                        Show help message."
}

function parse_arguments() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        print_help
        exit 0
    fi

    ensure_git_repo_root

    local action="$1"
    shift

    case "$action" in
        init_config)
            create_default_config "$@"
            ;;
        status)
            status "$@"
            ;;
        push_all)
            push_all "$@"
            ;;
        push)
            push_changes "$@"
            ;;
        write_remote_commit_id)
            write_remote_commit_id "$@"
            ;;
        catchup)
            write_remote_commit_id "$@"
            ;;
        remove_remote_commit_id)
            remove_remote_commit_id "$@"
            ;;
        *)
            echo "Invalid action: $action"
            print_help
            exit 1
            ;;
    esac

    exit 0
}

if [[ $# -lt 1 ]]; then
    print_help
    exit 1
fi

parse_arguments "$@"
