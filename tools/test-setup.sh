#!/bin/bash
# cSpell:ignore RPMS xorg cmdtest corepack xrandr nocolor userns pwsh
#
# This tool is used to setup the environment for running the tests. Its name
# name and location is based on Zuul CI, which can automatically run it.
# (cspell: disable-next-line)
set -euo pipefail

DIR="$(dirname "$(realpath "$0")")"
# shellcheck source=/dev/null
. "$DIR/_utils.sh"

IMAGE_VERSION=$(./tools/get-image-version)
IMAGE=ghcr.io/ansible/community-ansible-dev-tools:${IMAGE_VERSION}
PIP_LOG_FILE=out/log/pip.log
ERR=0
EE_ANSIBLE_VERSION=null
EE_ANSIBLE_LINT_VERSION=null

mkdir -p out/log
# we do not want pip logs from previous runs
:> "${PIP_LOG_FILE}"

# Function to retrieve the version number for a specific command. If a second
# argument is passed, it will be used as return value when tool is missing.
get_version () {
    if command -v "${1:-}" >/dev/null 2>&1; then
        _cmd=("${@:1}")
        # if we did not pass any arguments, we add --version ourselves:
        if [[ $# -eq 1 ]]; then
            _cmd+=('--version')
        fi
        # prevents npm runtime warning if both NO_COLOR and FORCE_COLOR are present
        unset FORCE_COLOR
        # Keep the `tail -n +1` and the silencing of 141 error code because otherwise
        # the called tool might fail due to premature closure of /dev/stdout
        # made by `--head n1`. See https://superuser.com/a/642932/3004
        # NO_COLOR is needed by ansible-lint to allow sed to work correctly
        NO_COLOR=1 "${_cmd[@]}" | tail -n +1 | head -n1 | sed -r 's/^[^0-9]*([0-9][0-9\\w\\.]*).*$/\1/'
    else
        log error "Got $? while trying to retrieve ${1:-} version"
        return 99
    fi
}

find_powershell() {
    # Sometimes these are not in PATH under wsl, so we need to look deeper
    local candidates=(
        "pwsh.exe"
        "powershell.exe"
        "/mnt/c/Program Files/PowerShell/7/pwsh.exe"
        "/mnt/c/Program Files (x86)/PowerShell/7/pwsh.exe"
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    )
    for exe in "${candidates[@]}"; do
        if cmd=$(command -v "$exe" 2>/dev/null); then
            echo "$cmd"
            exit 0
        elif [ -x "$exe" ]; then
            echo "$exe"
            exit 0
        fi
    done
    log error "Failed to find powershell executable"
    exit 2
}

if [[ -z "${HOSTNAME:-}" ]]; then
   export HOSTNAME=${HOSTNAME:-${HOST:-$(hostname)}}
   log warning "Defined HOSTNAME=${HOSTNAME} as we were not able to found a value already defined.."
fi

if [[ "${OSTYPE:-}" != darwin* ]]; then
    pgrep "dbus-(daemon|broker)" >/dev/null || {
        log error "dbus was not detecting as running and that would interfere with testing (xvfb)."
        exit 55
    }
fi

if [[ "${OSTYPE:-}" == darwin* ]]; then
    # coreutils provides 'timeout' command
    HOMEBREW_NO_ENV_HINTS=1 timed brew bundle --file=- <<-EOS
brew "coreutils"
brew "libssh"
brew "gh"
brew "git-lfs"
EOS
    # Using 'brew bundle' due to https://github.com/Homebrew/brew/issues/2491
fi

is_podman_running() {
    if [[ "$(podman machine ls --format '{{.Name}} {{.Running}}' --noheading 2>/dev/null)" == *"podman-machine-default* true"* ]]; then
        log notice "Podman machine is running."
        return 0
    else
        log error "Podman machine is not running."
        return 1
    fi
}

if [ ! -d "$HOME/.local/bin" ] ; then
    log warning "Creating missing ~/.local/bin"
    mkdir -p "$HOME/.local/bin"
fi

# Detect RedHat/CentOS/Fedora:
if [[ -f "/etc/redhat-release" ]]; then
    RPMS=()
    command -v xvfb-run >/dev/null 2>&1 || RPMS+=(xorg-x11-server-Xvfb)
    if [[ ${#RPMS[@]} -ne 0 ]]; then
        log warning "We need sudo to install some packages: ${RPMS[*]}"
        sudo dnf install -y "${RPMS[@]}"
    fi
fi


# Fail-fast if run on Windows or under WSL1/2 on /mnt/c because it is so slow
# that we do not support it at all. WSL use is ok, but not on mounts.
WSL=0
if [[ "${OS:-}" == "windows" ]]; then
    log error "You cannot use Windows build tools for development, try WSL."
    exit 1
fi
if grep -qi microsoft /proc/version >/dev/null 2>&1; then
    # resolve pwd symlinks and ensure than we do not run under /mnt (mount)
    if [[ "$(pwd -P || true)" == /mnt/* ]]; then
        log warning "Under WSL, you must avoid running from mounts (/mnt/*) due to critical performance issues."
    fi
    WSL=1
fi

# determine os_version as lowercase string
if [[ "${OSTYPE:-}" == darwin* ]]; then
    OS_VERSION="macos-$(sw_vers --productVersion)"
else
    OS_VERSION="$(lsb_release --id --short 2> /dev/null)-$(lsb_release --release --short 2> /dev/null)"
    OS_VERSION="${OS_VERSION,,}"
    if [[ "$WSL" -eq 1 ]]; then
        OS_VERSION=$($(find_powershell) -Command 'Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -property Caption, BuildNumber' | grep "Microsoft " | \
        tr -d '\r' | \
        sed 's/^Microsoft //I' | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[ -]\+/-/g')-wsl-$OS_VERSION
    fi
fi
log notice "Platform: $OS_VERSION"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "ARCH=$ARCH" >> "$GITHUB_OUTPUT"
    echo "OS_VERSION=$OS_VERSION" >> "$GITHUB_OUTPUT"
fi

if [[ -f "/usr/bin/apt-get" ]]; then
    INSTALL=0
    # qemu-user-static is required by podman on arm64
    # python3-dev is needed for headers as some packages might need to compile
    DEBS=(curl git python3-dev python3-venv python3-pip qemu-user-static xvfb x11-xserver-utils libgbm-dev libssh-dev libonig-dev)
    # add nodejs to DEBS only if node is not already installed because
    # GHA has newer versions preinstalled and installing the rpm would
    # basically downgrade it
    command -v node >/dev/null 2>&1 || {
        DEBS+=(nodejs)
    }
    command -v npm >/dev/null 2>&1 || {
        DEBS+=(npm)
    }
    command -v git-lfs >/dev/null 2>&1 || {
        # curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | sudo bash
        DEBS+=(git-lfs)
        INSTALL=1
    }

    for DEB in "${DEBS[@]}"; do
        [[ "$(dpkg-query --show --showformat='${db:Status-Status}\n' \
            "${DEB}" || true)" != 'installed' ]] && INSTALL=1
    done
    if [[ "${INSTALL}" -eq 1 ]]; then
        log warning "We need sudo to install some packages: ${DEBS[*]}"
        # mandatory or other apt-get commands fail
        sudo apt-get update -qq -o=Dpkg::Use-Pty=0
        # avoid outdated ansible and pipx
        sudo apt-get remove -y ansible pipx || true
        # install all required packages
        sudo apt-get -qq install -y \
            --no-install-recommends \
            --no-install-suggests \
            -o=Dpkg::Use-Pty=0 "${DEBS[@]}"
    fi
    # Remove undesirable packages, like cmdtest which provides another "yarn"
    DEBS=(cmdtest)
    for DEB in "${DEBS[@]}"; do
        [[ "$(dpkg-query --show --showformat='${db:Status-Status}\n' \
            "${DEB}" 2>/dev/null || true)" == 'installed' ]] && \
            sudo apt-get remove -y "$DEB"
    done
fi

git lfs status >/dev/null || {
    log error "Please install and configure git lfs to be able to build the project."
    exit 3
}

# Pull Git LFS files to ensure media files are available for packaging
log notice "Pulling Git LFS files..."
git lfs pull || {
    log error "Failed to pull Git LFS files. Media files may appear as text pointers in the package."
    exit 3
}
log notice "Git LFS files pulled successfully."

if [[ $(file media/walkthroughs/*.mp4 | grep -c "ASCII text") -gt 0 ]]; then
    log error "Detected LFS pointer files, not real files. Check the git lfs configuration and status."
    exit 3
fi

log notice "Using $(python3 --version)"

# Ensure that git is configured properly to allow unattended commits, something
# that is needed by some tasks, like devel or deps.
git config user.email >/dev/null 2>&1 || GIT_NOT_CONFIGURED=1
git config user.name  >/dev/null 2>&1 || GIT_NOT_CONFIGURED=1
if [[ "${GIT_NOT_CONFIGURED:-}" == "1" ]]; then
    echo CI="${CI:-}"
    if [ -z "${CI:-}" ]; then
        log error "git config user.email or user.name are not configured."
        exit 40
    else
        git config user.email ansible-devtools@redhat.com
        git config user.name "Ansible DevTools"
    fi
fi

# macos specific
if [[ "${OS:-}" == "darwin" && "${SKIP_PODMAN:-}" != '1' ]]; then
    command -v podman >/dev/null 2>&1 || {
        HOMEBREW_NO_ENV_HINTS=1 time brew install podman
        podman machine ls --noheading | grep '\*' || time podman machine init
        podman machine ls --noheading | grep "Currently running" || {
            # do not use full path as it varies based on architecture
            # https://github.com/containers/podman/issues/10824#issuecomment-1162392833
            "qemu-system-${MACHTYPE}" -machine q35,accel=hvf:tcg -cpu host -display none INVALID_OPTION || true
            time podman machine start
            }
        podman info
        podman run --rm hello-world
    }
fi

# User specific environment
if ! [[ "${PATH}" == *"${HOME}/.local/bin"* ]]; then
    # shellcheck disable=SC2088
    log warning "~/.local/bin was not found in PATH, attempting to add it."
    PATH="${HOME}/.local/bin:${PATH}"
    export PATH

    # shellcheck disable=SC2088
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        log notice "Altered GITHUB_ENV to extend PATH."
        echo "{PATH}={$PATH}" >> "$GITHUB_ENV"
    else
        log error "Reconfigure your shell (${SHELL}) to include ~/.local/bin in your PATH, we need it."
        exit 102
    fi
fi

# fail-fast if we detect incompatible filesystem (o-w)
# https://github.com/ansible/ansible/pull/42070
python3 -c "import os, stat, sys; sys.exit(os.stat('.').st_mode & stat.S_IWOTH)" || {
    log error "Cannot run from world-writable filesystem, try moving code to a secured location and read https://ansible.readthedocs.io/projects/team-devtools/guides/ansible/permissions/"
    exit 100
}

# install gh if missing
command -v gh >/dev/null 2>&1 || {
    log notice "Trying to install missing gh on ${OS} ..."
    # https://github.com/cli/cli/blob/trunk/docs/install_linux.md
    if [[ -f "/usr/bin/apt-get" ]]; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
          sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt-get update
      sudo apt-get install gh
    else
        command -v dnf >/dev/null 2>&1 && sudo dnf install -y gh
    fi
    gh --version || log warning "gh cli not found and it might be needed for some commands."
}

# on WSL we want to avoid using Windows's npm (broken)
if [[ "$(command -v npm || true)" == '/mnt/c/Program Files/nodejs/npm' ]]; then
    log notice "Installing npm ... ($WSL)"
    curl -sL https://deb.nodesource.com/setup_16.x | sudo bash
    sudo apt-get install -y -qq -o=Dpkg::Use-Pty=0 \
        nodejs gcc g++ make python3-dev
fi

# if a virtualenv is already active, ensure is the expected one
EXPECTED_VENV="${HOME}/.local/share/virtualenvs/vsa"
if [[ -d "${VIRTUAL_ENV:-}" && "${VIRTUAL_ENV:-}" != "${EXPECTED_VENV}" ]]; then
     log warning "Detected another virtualenv active ($VIRTUAL_ENV) than expected one, switching it to ${EXPECTED_VENV}"
fi
VIRTUAL_ENV=${EXPECTED_VENV}
if [[ ! -d "${VIRTUAL_ENV}" ]]; then
    log notice "Creating virtualenv ..."
    python3 -m venv "${VIRTUAL_ENV}"
fi
# shellcheck disable=SC1091
. "${VIRTUAL_ENV}/bin/activate"

if [[ "$(which python3)" != ${VIRTUAL_ENV}/bin/python3 ]]; then
    log warning "Virtualenv broken, trying to recreate it ..."
    python3 -m venv --clear "${VIRTUAL_ENV}"
    . "${VIRTUAL_ENV}/bin/activate"
    if [[ "$(which python3)" != ${VIRTUAL_ENV}/bin/python3 ]]; then
        log error "Virtualenv still broken."
        exit 99
    fi
fi
log notice "Upgrading pip and uv ..."

python3 -m pip install -q -U pip uv
# Fail fast if user has broken dependencies
python3 -m pip check || {
        log error "pip check failed with exit code $?"
        if [[ $MACHTYPE == x86_64* && "${OSTYPE:-}" != darwin* ]] ; then
            exit 98
        else
            log error "Ignored pip check failure on this platform due to https://sourceforge.net/p/ruamel-yaml/tickets/521/"
        fi
}

if [[ $(uname || true) != MINGW* ]]; then # if we are not on pure Windows
    # We used the already tested constraints file from community-ansible-dev-tools EE in order
    # to avoid surprises. This ensures venv and community-ansible-dev-tools EE have exactly same
    # versions.
    python3 -m uv pip install -q \
        -r .config/requirements.in -c .config/constraints.txt
fi

# GHA failsafe only: ensure ansible and ansible-lint cannot be found anywhere
# other than our own virtualenv. (test isolation)
if [[ -n "${CI:-}" ]]; then
    command -v ansible >/dev/null 2>&1 || {
        log warning "Attempting to remove pre-installed ansible on CI ..."
        pipx uninstall --verbose ansible || true
        if [[ "$(which -a ansible | wc -l | tr -d ' ')" != "1" ]]; then
            log error "Please ensure there is no preinstalled copy of ansible on CI.\n$(which -a ansible)"
            exit 66
        fi
    }
    command -v ansible-lint >/dev/null 2>&1 || {
        log warning "Attempting to remove pre-installed ansible-lint on CI ..."
        pipx uninstall --verbose ansible-lint || true
        if [[ "$(which -a ansible-lint | wc -l | tr -d ' ')" != "1" ]]; then
            log error "Please ensure there is no preinstalled copy of ansible-lint on CI.\n$(which -a ansible-lint)"
            exit 67
        fi
    }
    if [[ -d "${HOME}/.ansible" ]]; then
        log warning "Removing unexpected ~/.ansible folder found on CI to avoid test contamination."
        rm -rf "${HOME}/.ansible"
    fi
fi

# Fail if detected tool paths are not from inside out out/ folder
for CMD in ansible ansible-lint ansible-navigator; do
    CMD=$(command -v $CMD 2>/dev/null)
    [[ "${CMD}" == "$VIRTUAL_ENV"* ]] || {
        log error "${CMD} executable is not from our own virtualenv ($VIRTUAL_ENV)"
        exit 68
    }
done
unset CMD

if [[ -f yarn.lock ]]; then
    # Check if npm has permissions to install packages (system installed does not)
    # Share https://stackoverflow.com/a/59227497/99834
    test -w "$(npm config get prefix)" || {
        log warning "Your npm is not allowed to write to $(npm config get prefix), we will reconfigure its prefix"
        npm config set prefix "${HOME}/.local/"
    }
fi

log notice "Docker checks..."
if [[ -n ${DOCKER_HOST+x} ]]; then
    log error "DOCKER_HOST is set, we do not support this setup."
    exit 1
fi
# Detect docker and ensure that it is usable (unless SKIP_DOCKER)
DOCKER_VERSION="$(get_version docker 2>/dev/null || echo 'null' && log warning 'docker not found, skipping related tests')"
if [[ "${DOCKER_VERSION}" != 'null' ]] && [[ "${SKIP_DOCKER:-}" != '1' ]]; then

    DOCKER_STDERR="$(docker --version 2>&1 >/dev/null)"
    if [[ "${DOCKER_STDERR}" == *"Emulate Docker CLI using podman"* ]]; then
        log error "podman-docker shim is present and we do not support it. Please remove it."
        exit 1
    fi

    if [ -n "${DOCKER_HOST:-}" ]; then
        log error "Found DOCKER_HOST and this is not supported, please unset it."
        exit 1
    fi
    docker container prune -f
    log notice "Pull our test container image with docker."
    pull_output=$(docker pull "${IMAGE}" 2>&1 >/dev/null) || {
        log error "Failed to pull image, maybe current user is not in docker group? Run 'sudo sh -c \"groupadd -f docker && usermod -aG docker $USER\"' and relogin to fix it.\n${pull_output}"
        exit 1
    }
    # without running we will never be sure it works (no arm64 image yet)
    EE_ANSIBLE_VERSION=$(get_version \
        docker run --rm "${IMAGE}" ansible --version)
    EE_ANSIBLE_LINT_VERSION=$(get_version \
        docker run "${IMAGE}" ansible-lint --nocolor --version)
    log notice "ansible: ${EE_ANSIBLE_VERSION}, ansible-lint: ${EE_ANSIBLE_LINT_VERSION}"
    # Test docker ability to mount current folder with write access, default mount options
    docker run -v "$PWD:$PWD" ghcr.io/ansible/community-ansible-dev-tools:latest \
        bash -c "[ -e $PWD ] && [ -d $PWD ] \
        && echo 'Mounts working' || { echo 'Mounts not working. You might need to either disable or make selinux permissive.'; exit 1; }"
fi

log notice "Podman checks..."
# macos specific
if [[ "${OSTYPE:-}" == darwin* && "${SKIP_PODMAN:-}" != '1' ]]; then
    command -v podman >/dev/null 2>&1 || {
        log notice "Installing podman..."
        HOMEBREW_NO_ENV_HINTS=1 timed brew install podman
    }
    log notice "Configuring podman machine ($MACHTYPE)..."
    podman machine ls --noheading | grep '\*' >/dev/null || {
        log warning "Podman machine not found, creating and starting one ($MACHTYPE)..."
        timed podman machine init --now || log warning "Ignored init failure due to possible https://github.com/containers/podman/issues/13609 but we will check again later."
    }
    podman machine ls --noheading
    log notice "Checking status of podman machine ($MACHTYPE)..."
    is_podman_running || {
        log warning "Podman machine not running, trying to start it..."
        # do not use full path as it varies based on architecture
        # https://github.com/containers/podman/issues/10824#issuecomment-1162392833
        # MACHTYPE can look like x86_64 or x86_64-apple-darwin20.6.0
        if [[ $MACHTYPE == x86_64* ]] ; then
            log notice "Running on x86_64 architecture"
        else
            qemu-system-aarch64 -machine q35,accel=hvf:tcg -cpu host -display none INVALID_OPTION || true
        fi
        podman machine start
        # Waiting for machine to become available
        n=0
        until [ "$n" -ge 9 ]; do
            log warning "Still waiting for podman machine to become available $((n * 15))s ..."
            is_podman_running && break
            n=$((n+1))
            sleep 15
        done
        is_podman_running
        }
    # validation is done later
    podman info >out/podman.log 2>&1
    podman run hello-world >out/podman.log 2>&1
    du -ahc ~/.config/containers ~/.local/share/containers  >out/podman.log 2>&1 || true
    podman machine inspect >out/podman.log 2>&1
fi
# Detect podman and ensure that it is usable (unless SKIP_PODMAN)
PODMAN_VERSION="$(get_version podman || echo null)"
if [[ "${PODMAN_VERSION}" != 'null' ]] && [[ "${SKIP_PODMAN:-}" != '1' ]]; then
    podman container prune -f
    log notice "Pull our test container image with podman."
    pull_output=$(podman pull --quiet "${IMAGE}" 2>&1 >/dev/null) || {
        log error "Failed to pull image.\n${pull_output}"
        exit 1
    }
    # without running we will never be sure it works
    log notice "Retrieving ansible version from ee"
    EE_ANSIBLE_VERSION=$(get_version \
        podman run --rm "${IMAGE}" ansible --version)
    log notice "Retrieving ansible-lint version from ee"
    EE_ANSIBLE_LINT_VERSION=$(get_version \
        podman run --rm "${IMAGE}" ansible-lint --nocolor --version)
    log notice "ansible: ${EE_ANSIBLE_VERSION}, ansible-lint: ${EE_ANSIBLE_LINT_VERSION}"
    log notice "Test podman ability to mount current folder with write access, default mount options"
    podman run -v "$PWD:$PWD" ghcr.io/ansible/community-ansible-dev-tools:latest \
        bash -c "[ -e $PWD ] && [ -d $PWD ] && echo 'Mounts working' || { echo 'Mounts not working. You might need to either disable or make selinux permissive.'; exit 1; }"
fi

# Create a build manifest so we can compare between builds and machines, this
# also has the role of ensuring that the required executables are present.
#
tee "out/log/manifest-${HOSTNAME}.yml" <<EOF
system:
  uname: $(uname)
env:
  ARCH: ${ARCH:-null}  # taskfile
  OS: ${OS:-null}    # taskfile
  OSTYPE: ${OSTYPE}
tools:
  ansible-lint: $(get_version ansible-lint)
  ansible: $(get_version ansible)
  bash: $(get_version bash)
  gh: $(get_version gh || echo null)
  git: $(get_version git)
  node: $(get_version node)
  npm: $(get_version npm)
  pre-commit: $(get_version pre-commit)
  python: $(get_version python3)
  task: $(get_version task)
  yarn: $(npx --yes yarn --version || echo null)
containers:
  podman: ${PODMAN_VERSION}
  docker: ${DOCKER_VERSION}
community-ansible-dev-tools:
  ansible: ${EE_ANSIBLE_VERSION}
  ansible-lint: ${EE_ANSIBLE_LINT_VERSION}
EOF

[[ $ERR -eq 0 ]] && level=notice || level=error
log "${level}" "${0##*/} -> out/log/manifest-$HOSTNAME.yml and returned ${ERR}"
exit "${ERR}"
