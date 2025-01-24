# git-ssh-deploy

Push tracked Git files to a remote server using SSH.

Deployment bash script based on tracked files in a Git repository using SSH. Allows pushing changed local files in Git to remote environments that have a different state. Places a file named ```.git-ssh-deploy-state-commit-id.log``` on the target remote server after successful deployment, storing the pushed commit ID for reference and to determine which files to push next time.

The deployment determines files to be pushed to the remote environment by using ```git diff```. Then, those files are bundled in a tarball, copied to the server using ```scp``` and extracted there.
Environment configuration is placed in .git/config.

## Features

- Ease of use. One-time setup. Working is a breeze.
- Fast and resource-saving deployment.
- State logged on environment.
- Multiple environments (e.g. production, staging etc.) supported.
- Support pre- and post-deploy commands on server (e.g. to activate or deactivate maintenance mode).
- Filter local files by setting up a synchronisation directory (e.g. "webroot" in a WordPress project's repo or "laravel-app" in a mono-repo.).
- Exclude tracked files or directories from the deployment (e.g. .env.template).
- Include additional files or directories that are not part of Git in the deployments.
- Automated health check visits URL and looks for an HTTP 2xx status in the response.

Please note that a failed deployment does not rollback the state on the server. You have to manually check and take action. This, however, is made easy by the script as it is transparent about which steps succeeded and where problems arose.

```sh

# Setup environment "production" section in .git/config.
git-ssh-deploy init_config production
# Now, set up at least the host, user and remote directory and edit .git/config directly or, alternatively, set it up this way:
git config git-ssh-deploy.production.host "foo.example.org"
git config git-ssh-deploy.production.user "webuser"
git config git-ssh-deploy.production.remotedirectory "/var/www/html"
# Make sure, you are able to access the server using SSH with these settings and have accepted the remote host’s SSH key/fingerprint in advance
# ssh webuser@foo.example.org

# Display status information, including files to be uploaded, connection and state information and local and remote path mapping.
git-ssh-deploy status production

# Upload all tracked files and set commit ID to the HEAD commit ID
git-ssh-deploy push_all production

# Or if the files are already there (This sets the remote commit ID to the HEAD commit ID without uploading anything.)
git-ssh-deploy catchup production

# Work and deploy
echo "new content" >> index.txt
git commit index.txt -m "Add new content"
git-ssh-deploy push production

```

## Requirements

- Local system: macOS (Currently, no support for other operating systems. Feel free to contribute.)
- Remote system: Linux
- SSH
  - Currently only supports ***SSH public key authentication***. No password authentication is supported as it is not a good idea anyway to store it in an unencrypted file like .git/config on disk. (Maybe an interactive password input will be implemented in the future.)
  - Calls such as ```ssh -p 22 webuser@example.org``` have to work and setup in advance (like trusting the remote host identification in ~/.ssh/known_hosts).

## Installation

### Direct usage

You could clone or download this repository, place it somewhere on your disk, make it executable and use it directly:

```sh
# git clone the repo to /some/directory

# make it executable
chmod +x /some/directory/git-ssh-deploy.sh

# use it in some other repo
cd /some/other/repo
/some/directory/git-ssh-deploy.sh -h
```

### Symlink usage

Alternatively, you could clone or download this repository, place it somewhere on your disk, and create a symlink in a $PATH directory (such as /usr/local/bin for all users on local machine) for easier access.

```sh
# git clone the repo to /some/directory

# make it executable
chmod +x /some/directory/git-ssh-deploy.sh

# create symlink
sudo ln -s /some/directory/git-ssh-deploy.sh /usr/local/bin/git-ssh-deploy

# use it in some other repo
cd /some/other/repo
git-ssh-deploy -h

# uninstall it later if desired
sudo rm /usr/local/bin/git-ssh-deploy
```

## Usage

```
Usage: git-ssh-deploy <action> <environment> [<options or action-specific arguments>]
Actions:
    init_config               Add default config block to .git/config.
    status                    Shows state and connection information for given environment.
    push_all                  Upload all tracked files from scratch and set remote commit ID. Does not remove any other files.
    push                      Push changes based on Git diff and update remote commit ID.
    write_remote_commit_id    Manually set remote commit ID without pushing any files. Commit ID has to be set as third argument. If empty, HEAD commit ID is used.
    catchup                   Alias for write_remote_commit_id. Use without specifying the commit ID to use the HEAD commit ID. This states that the remote server is up to date with the local repository.
    remove_remote_commit_id   Remove remote commit ID log file.
Options:
    -h                        Show help message.
```

### Config

Be careful to escape special characters for correct bash usage. Put more complex strings such as commands or URLs in double-quotes.

***Note:*** Make sure your SSH user has write permissions for the remote directory (remotedirectory) on the server. Otherwise, the deployment will fail.

```
[git-ssh-deploy "production"]
    host =
    user =
    port = 22
    # Directory on the remote server where the files will be uploaded. No trailing slash.
    remotedirectory = /var/www/html
    # Command to run on the remote server before deploying the files. Can be empty. Run multiple commands using "&&", for example.
    predeploycommand =
    # Command to run on the remote server after deploying the files. Can be empty. Run multiple commands using "&&", for example.
    postdeploycommand =
    # URL to check after deployment. Can be empty. Wrap the URL in double quotes if it contains special characters.
    healthcheckurl =
    # Local directory to sync with the remote server. If empty, the root of the repository is used. No trailing slash.
    syncroot =
    # Comma-separated list of paths to exclude from upload. Paths can be directories or files. Paths must be relative to syncroot if syncroot is set. Otherwise repository root is used. No starting or trailing slashes. No spaces after commas.
    excludedpaths =
    # Comma-separated list of paths to include in the every upload. Paths can be directories or files. Paths must be relative to syncroot if syncroot is set. Otherwise repository root is used. No starting or trailing slashes. No spaces after commas. Includes are run after excludes.
```

#### Example config for a generic web application (e.g. WordPress)

```
[git-ssh-deploy "production"]
    host = foo.example.org
    user = webuser
    port = 22
    remotedirectory = /var/www/html
    predeploycommand =
    postdeploycommand =
    healthcheckurl = "https://foo.example.org"
    syncroot =
    excludedpaths =
```

#### Example config for a laravel application

```
[git-ssh-deploy "production"]
    host = foo.example.org
    user = webuser
    port = 22
    remotedirectory = /var/www/html
    predeploycommand = "php /var/www/html/artisan down"
    postdeploycommand = "php /var/www/html/artisan config:clear && php /var/www/html/artisan optimize && php /var/www/html/artisan storage:link && php /var/www/html/artisan migrate --force && php /var/www/html/artisan queue:restart && php /var/www/html/artisan up"
    healthcheckurl = "https://foo.example.org"
    syncroot =
    excludedpaths =
```

## Security

This tool performs sensitive tasks and thus has a potential to break stuff.

Known risks:

- Invalid path configuration might cause damage by overwriting vital files.
- Potential bugs could cause data loss or downtimes. Test your preferred workflow thoroughly if it matches the tool's functionality.
- The script allows pre- and post-deployment commands. If an attacker has access to the local machine and is able to modify the config, this could compromise the machines involved. To prevent this, make sure to have a clean local machine without malicious code running. However, this attack vector might not be as relevant, because if that happens, the attacker is most likely able to directly access and infect the environment anyway.

## Contributing

You are welcome to help improve this project by adding features, tests or fixing found bugs.

If you found any security issues, please report them as issues in this project or use the information on the [contact](https://www.pageonstage.at/en/contact) page.

## Acknowledgment

The idea of this repo is loosely based on the fantastic [git-ftp](https://github.com/git-ftp/git-ftp).
