# Do no use this justfile directly. See sub-directories.

# Explicitely allow overriding variables and recipes in justfiles importing this one
set allow-duplicate-variables := true
set allow-duplicate-recipes := true

# sysexts must explicitely say which base operating system images they target
base_images := ""

# Do not download any packages by default
packages := ""

# Do not enable additional repos by default
enable_repos := ""

# Do not enable any Copr repos by default
copr_repos := ""

# Disable repos from the build container
disable_repos := ""

# Do not enable any external repos by default
external_repos := ""

# Do not run any commands before downloading RPMs by default
pre_commands := ""

# Install weak dependencies by default
dnf_weak_deps := ""

# Do not exclude any dependency by default
exclude_packages := ""

# Default to noarch + current architecture
arch := "noarch " + arch()

# Do not install any additional files by default
files := ""

# zstd compression is still experimental in EROFS
# compression := "zstd"
compression := "lz4"

# Default, empty, just recipe
default:
    #!/bin/bash
    set -euo pipefail
    # set -x

    echo "Usage: 'just build <target>'"
    echo ""
    echo "Valid targets for this sysext:"
    echo "{{base_images}}"

# Main recipe with all the steps to use to build a sysext
build target: (check target) clean (download-rpms target) download-manual setup-rootfs install-rpms install-files install-manual move-etc rm-ignored (reset-selinux-labels target) (build-erofs target)

# List the supported targets for this sysext. To use in CI and scripting
targets:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ -z "{{base_images}}" ]]; then
        echo "sysexts must explicitely say which base operating system images they support"
        exit 1
    fi

    echo "{{base_images}}" | xargs

# Sanity check that some variables are set
check target:
    #!/bin/bash
    set -euo pipefail
    # set -x

    # Make sure that the sysext lists the base images that it supports
    if [[ -z "{{base_images}}" ]]; then
        echo "sysexts must explicitely say which base operating system images they support"
        exit 1
    fi

    # Make sure that the current target is in the supported list
    found=false
    for base in $(echo "{{base_images}}" | xargs); do
        if [[ "${base}" == {{target}} ]]; then
            found=true
            break
        fi
    done
    if [[ ${found} == "false" ]]; then
        echo "{{target}} is not listed as a supported base image for this sysext"
        exit 1
    fi

    # Make sure that we install at least a package or some files
    if [[ -z "{{packages}}" ]] && [[ -z "{{files}}" ]]; then
        echo "sysexts must include at least one package or file tree"
        exit 1
    fi

# Download RPMs to install. Use the following variables:
# - packages: List of packages to download (and later install)
# - enable_repos: List of additional repos to enable
download-rpms target:
    #!/bin/bash
    set -euo pipefail
    # set -x

    # Skip this step if we have not been asked to download packages
    if [[ -z "{{packages}}" ]]; then
        exit 0
    fi

    enablerepos=""
    if [[ -n "{{enable_repos}}" ]]; then
        for r in {{enable_repos}}; do
            echo "➕ Enabling repo: ${r}"
            enablerepos+=" --enablerepo=${r}"
        done
    fi

    disablerepos=""
    if [[ -n "{{disable_repos}}" ]]; then
        for r in {{disable_repos}}; do
            echo "➖ Disabling repo: ${r}"
            disablerepos+=" --disablerepo=${r}"
        done
    fi

    arch=""
    for a in {{arch}}; do
        arch+="--arch=${a} "
    done

    dnf_opts=""
    if [[ "{{dnf_weak_deps}}" == false ]]; then
        dnf_opts="--setopt=install_weak_deps=False"
    fi
    if [[ -n "{{exclude_packages}}" ]]; then
        excluded_packages="$(echo "{{exclude_packages}}" | xargs)"
        for p in ${excluded_packages}; do
            echo "➖ Excluding package: ${p}"
            dnf_opts+=" --exclude=${p}"
        done
    fi

    packages="$(echo "{{packages}}" | xargs)"

    pre_commands=""
    if [[ -n "{{pre_commands}}" ]]; then
        pre_commands+="{{pre_commands}} ; "
    fi
    if [[ -n "{{copr_repos}}" ]]; then
        pre_commands+="dnf install -y dnf5-plugins"
        for r in "{{copr_repos}}"; do
            pre_commands+=" ; dnf copr enable -y ${r}"
        done
        pre_commands+=" ; "
    fi
    if [[ -n "{{external_repos}}" ]]; then
        pre_commands+="dnf install -y dnf5-plugins"
        for r in "{{external_repos}}"; do
            pre_commands+=" ; dnf config-manager addrepo --from-repofile=${r}"
        done
        pre_commands+=" ; "
    fi

    mkdir -p ../.dnf-cache

    mkdir rpms
    cd rpms

    echo "⬇️ Downloading packages ({{arch}}): ${packages}"
    # dnf install --downloadonly --downloaddir . ${arch} ${enablerepos} ${packages}
    podman run --rm -ti \
        --volume "${PWD}:/var/srv" \
        --volume "${PWD}/../../.dnf-cache:/var/cache/libdnf5" \
        --workdir "/var/srv" \
        --security-opt label=disable \
        "{{target}}" \
        bash -c "${pre_commands}dnf download --resolve ${arch} ${dnf_opts} ${disablerepos} ${enablerepos} ${packages}"

# Manual download step, that can be overridden to dowload non RPM content
download-manual:
    #!/bin/bash
    set -euo pipefail
    # set -x
    exit 0

# Sets up the rootfs directory and creates the extension release config
setup-rootfs:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    mkdir rootfs
    cd rootfs

    echo "➡️ Setting up extension config file"
    ${SUDO} install -d -m0755 usr/lib/extension-release.d
    echo "ID=\"_any\"" | ${SUDO} tee usr/lib/extension-release.d/extension-release.{{name}} > /dev/null

# Install (extract) RPM packages download in download-rpms recipe. Uses:
# - packages: List of packages to install
install-rpms:
    #!/bin/bash
    set -euo pipefail
    # set -x

    # Skip this step if we have not been asked to install packages
    if [[ -z "{{packages}}" ]]; then
        exit 0
    fi

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    cd rootfs

    echo "📦 Extracting packages:"
    for rpm in ../rpms/*.rpm; do
        echo "$(basename ${rpm})"
        rpm2cpio "${rpm}" | ${SUDO} cpio -idmv &> /dev/null
    done

# Install files from the current directory. Uses:
# - files: List of folders or files to copy to `rootfs`. Use either `usr` or
#   `opt` as everything else is ignored. Spaces are not supported.
install-files:
    #!/bin/bash
    set -euo pipefail
    # set -x

    # Skip this step if we have not been asked to copy files
    if [[ -z "{{files}}" ]]; then
        exit 0
    fi

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    cd rootfs

    echo "📁 Copying additional files from: {{files}}"
    for f in {{files}}; do
        ${SUDO} cp -a ../${f} .
    done

# Manual installation step, that can be overridden to install non RPM content
# or fixup issues after RPM installation.
install-manual:
    #!/bin/bash
    set -euo pipefail
    # set -x
    exit 0

# Move /etc to /usr/etc. Might be converted to a confext generator.
move-etc:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    cd rootfs

    if [[ -d ./etc ]] then
        echo "➡️ Moving /etc to /usr/etc"
        ${SUDO} mv --no-clobber --no-copy ./etc ./usr/etc
    fi

# Move all folders outside of /usr & /opt out of the sysext's rootfs.
# Note: This step is still in progress. Currently only moves /var and /run.
rm-ignored:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    if [[ -d rootfs.ignored ]]; then
        echo "🧹 Cleaning up previous rootfs.ignored"
        ${SUDO} rm -rf ./rootfs.ignored
    fi
    mkdir rootfs.ignored

    cd rootfs

    for dir in "var" "run"; do
        if [[ -d ./"${dir}" ]] then
            echo "➡️ Moving ${dir} out of rootfs"
            ${SUDO} mv ./"${dir}" ../rootfs.ignored
        fi
    done

# Reset SELinux labels to expected values from the policy
reset-selinux-labels target:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    dnf_opts=""
    if [[ "{{dnf_weak_deps}}" == false ]]; then
        dnf_opts="--setopt=install_weak_deps=False"
    fi
    if [[ -n "{{exclude_packages}}" ]]; then
        excluded_packages="$(echo "{{exclude_packages}}" | xargs)"
        for p in ${excluded_packages}; do
            echo "➖ Excluding package: ${p}"
            dnf_opts+=" --exclude=${p}"
        done
    fi

    pre_commands=""
    if [[ -n "{{pre_commands}}" ]]; then
        pre_commands+="{{pre_commands}} ; "
    fi

    disablerepos=""
    if [[ -n "{{disable_repos}}" ]]; then
        for r in {{disable_repos}}; do
            echo "➖ Disabling repo: ${r}"
            disablerepos+=" --disablerepo=${r}"
        done
    fi

    if [[ -n "{{packages}}" ]]; then
        pre_commands+="dnf install -y ${dnf_opts} ${disablerepos} ./rpms/* && "
    fi

    filecontexts="/etc/selinux/targeted/contexts/files/file_contexts"
    echo "🏷️ Resetting SELinux labels"
    podman run --rm -ti \
        --volume "${PWD}:/var/srv" \
        --volume "${PWD}/../.dnf-cache:/var/cache/libdnf5" \
        --workdir "/var/srv" \
        --security-opt label=disable \
        --privileged \
        "{{target}}" \
        bash -c "${pre_commands}cd rootfs && setfiles -r . ${filecontexts} . && chcon --user=system_u --recursive ."

# Creates the EROFS sysext file
build-erofs target:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    echo "🔒 Creating EROFS sysext ({{compression}})"
    version=$(podman run --rm -ti \
        --security-opt label=disable \
        "{{target}}" \
        bash -c 'source /etc/os-release ; echo -n ${OSTREE_VERSION}')
    arch=$(uname -m | sed 's/_/-/g')
    ${SUDO} mkfs.erofs -z{{compression}} {{name}}-${version}-${arch}.raw rootfs > /dev/null

    if [[ "${UID}" != "0" ]]; then
        ${SUDO} chown "${USER}:" {{name}}*.raw
    fi

    echo "🎉 Done!"

# Clean up files from previous builds
clean:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ "${UID}" == "0" ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    echo "🧹 Cleaning up files from previous builds"
    rm -rf ./rpms
    rm -rf ./binaries
    ${SUDO} rm -rf ./rootfs ./rootfs.ignored
    rm -f ./*.raw
