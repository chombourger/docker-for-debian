#!/bin/bash
#---------------------------------------------------------------------------------------------------
# Build docker-ce for Debian
#---------------------------------------------------------------------------------------------------
# docker may be easily built for the architecture you are running on but it may be a little more
# tricky if you are targeting Arm and do not have an Arm machine with enough memory or computing
# power. This script uses qemu to run Debian on Arm to get a full environment (the "build vm") and
# where docker may be installed (as required by the build process). Sources are downloaded inside
# the build vm and built using the provided makefile.
#---------------------------------------------------------------------------------------------------

#---------------------------------------------------------------------------------------------------
# Debian installer
#---------------------------------------------------------------------------------------------------

WWW_DIR=/var/www/html
WWW_PRESEED=http://10.0.2.2/preseed.cfg

#---------------------------------------------------------------------------------------------------
# Disk settings for the build VM
#---------------------------------------------------------------------------------------------------

DISK_IMAGE=disk.qcow2
DISK_PATH=tmp/work/${ARCH}/debian-${DISTRO}
DISK_SIZE=10G

#---------------------------------------------------------------------------------------------------
# Utility functions
#---------------------------------------------------------------------------------------------------

# Print an info message to the console
info() {
    local mins

    mins=$(awk "BEGIN { print $SECONDS / 60; }")
    mins=$(printf "%0.2f" "${mins}")
    printf "\r[${mins}] ${*}"
}

# Run a command in the build vm
ssh_cmd() {
    export SSHPASS
    sshpass -e                               \
        ssh -q -p ${SSH_PORT}                \
            -o StrictHostKeyChecking=no      \
            -o UserKnownHostsFile=/dev/null  \
            ${SSH_USER}@localhost            \
            "${*}"
}

# Run a command in the build vm using sudo
ssh_sudo() {
    ssh_cmd "echo ${SSHPASS}|sudo -S -p '' ${*}"
}

# Check if SSH is running in the build vm
ssh_check() {
   ssh_cmd /bin/true
}

# Wait for SSH to be up and running in the build vm
ssh_wait() {
    local result counter


    counter=${SSH_DELAY}
    while [ ${counter} -gt 0 ]; do
        info "waiting for ssh server to be up..."
        sleep 1
        counter=$((${counter} - 1))
    done

    counter=${SSH_TRIES}
    while [ ${counter} -gt 0 ]; do
        info "trying to connect to build vm via ssh..."
        ssh_check; result=${?}
        [ ${result} -eq 0 ] && break
        counter=$((${counter} - 1))
    done

    case ${result} in
        0) echo "ok!"      ;;
        *) echo "timeout!" ;;
    esac
    return ${result}
}

# Copy something from the build vm
ssh_copy_from() {
    export SSHPASS
    sshpass -e                              \
        scp -r -q -P ${SSH_PORT}            \
            -o StrictHostKeyChecking=no     \
            -o UserKnownHostsFile=/dev/null \
            ${SSH_USER}@localhost:${1} ${2}
}

# Copy something to the build vm
ssh_copy_to() {
    export SSHPASS
    sshpass -e                              \
        scp -r -q -P ${SSH_PORT}            \
            -o StrictHostKeyChecking=no     \
            -o UserKnownHostsFile=/dev/null \
            ${1} ${SSH_USER}@localhost:${2}
}

install_build_host_deps() {
    sudo apt-get -qqy install \
        curl                  \
        nbd-client            \
        qemu-system           \
        reprepro              \
        sshpass               \
        wget
}

#---------------------------------------------------------------------------------------------------
# Local settings
#---------------------------------------------------------------------------------------------------

if [ -f local.conf ]; then
    info "loading local.conf"
    source local.conf
fi

#---------------------------------------------------------------------------------------------------
# QEMU command line
#---------------------------------------------------------------------------------------------------

cpuopt=""
[ -n "${CPU}" ] && cpuopt="-cpu ${CPU}"

#---------------------------------------------------------------------------------------------------
# kernel command line
#---------------------------------------------------------------------------------------------------

kcmd=""
[ -n "${CONSOLE}" ] && kcmd="${kcmd} console=${CONSOLE}"

#---------------------------------------------------------------------------------------------------
# The actual build process
#---------------------------------------------------------------------------------------------------

result=0

info "installing host dependencies\n"
install_build_host_deps; result=${?}

if [ ${result} -eq 0 ]; then
    info "checking latest docker-ce build...\n"
    latest=$(curl -s ${DOCKER_REPO}/releases/latest|sed -e 's,.*<a href=",,g'|cut -d '"' -f1)
    latest=$(basename ${latest})
    info "upstream version is ${latest}\n"
fi

# work directory for the installer
D=$(echo ${DEBIAN_VERSION}|tr '[:upper:]' '[:lower:]')-installer
WORKDIR=tmp/work/${ARCH}/${D}

if [ ${result} -eq 0 ]; then
    if [ ! -e ${WORKDIR}/${DI_INITRD} ] || [ ! -e ${WORKDIR}/${DI_KERNEL} ]; then
        info "getting ${ARCH} kernel and ramdisk\n"
        url=${DEBIAN_BASE_URL}/${DEBIAN_VERSION}/${DI_PATH}
        mkdir -p ${WORKDIR} && \
        pushd ${WORKDIR} >/dev/null && \
        wget -qc ${url}/${DI_INITRD} && \
        wget -qc ${url}/${DI_KERNEL} && \
        popd >/dev/null
        result=${?}
    fi
fi

# Copy preseed file to local web server
if [ ${result} -eq 0 ]; then
    info "copying preseed to ${WWW_DIR}\n"
    cat preseed.cfg \
        | HTTP_PROXY="${HTTP_PROXY}" \
          SSH_PASS="${SSHPASS}" \
          SSH_USER="${SSH_USER}" \
          envsubst \
        | sudo tee ${WWW_DIR}/preseed.cfg \
        > /dev/null
    result=${?}
fi

# Create (empty) disk image
if [ ${result} -eq 0 ]; then
    if [ ! -e ${DISK_PATH}/${DISK_IMAGE} ]; then
        info "creating ${DISK_SIZE} disk image\n"
        mkdir -p ${DISK_PATH} && \
        qemu-img create -f qcow2 ${DISK_PATH}/${DISK_IMAGE} ${DISK_SIZE} >/dev/null
        result=${?}
    fi
fi

# Install Debian to the disk image
if [ ${result} -eq 0 ]; then
    if [ ! -e ${DISK_PATH}/install.done ]; then
        info "installing Debian for ${ARCH}...\n"
        bootcmd="root=/dev/ram${kcmd}"
        bootcmd="${bootcmd} auto=true priority=critical preseed/url=${WWW_PRESEED}"
        ${QEMU} \
            -smp ${CORES} -M ${MACHINE} ${cpuopt} -m ${MEM} \
            -initrd ${WORKDIR}/${DI_INITRD} -kernel ${WORKDIR}/${DI_KERNEL} \
            -append "${bootcmd}" \
            \
            ${SCSI_OPTS} \
            -drive file=${DISK_PATH}/${DISK_IMAGE}${DRIVE_OPTS},id=rootimg,media=disk \
            \
            ${NETDEV_OPTS} \
            \
            -vnc :0 \
            -monitor unix:${DISK_PATH}/monitor.sock,server,nowait \
            -no-reboot
        result=${?}
        if [ ${result} -eq 0 ]; then
            touch ${DISK_PATH}/install.done
        fi
    fi
fi

# Extract kernel/initrd from disk
if [ ${result} -eq 0 ]; then
    if [ ! -e ${DISK_PATH}/initrd.img ] || [ ! -e ${DISK_PATH}/vmlinuz ]; then
        info "extracting installed kernel and ramdisk\n"
        sudo modprobe nbd max_part=8 && \
        sudo qemu-nbd --connect=/dev/nbd0 ${DISK_PATH}/${DISK_IMAGE} && \
        sudo partprobe /dev/nbd0 && \
        mkdir -p ${DISK_PATH}/mnt && \
        sudo mount /dev/nbd0p1 ${DISK_PATH}/mnt && \
        cp $(find ${DISK_PATH}/mnt -maxdepth 1 -type f -name initrd\*) ${DISK_PATH}/initrd.img && \
        cp $(find ${DISK_PATH}/mnt -maxdepth 1 -type f -name vmlinuz\*) ${DISK_PATH}/vmlinuz
        result=${?}
    fi
fi

# Flush data and release I/O devices
sync
if mountpoint -q ${DISK_PATH}/mnt; then
    info "un-mounting disk image\n"
    sudo umount /dev/nbd0p1
fi
if sudo nbd-client -c /dev/nbd0; then
    info "releasing network block device\n"
    sudo nbd-client -d /dev/nbd0
fi

# work directory for our docker-ce build
D=docker-ce-${latest}
WORKDIR=tmp/work/${ARCH}/${D}

if [ ${result} -eq 0 ]; then
    mkdir -p ${WORKDIR}
    result=${?}
fi

# Boot installed system
qemu_pid=
if [ ${result} -eq 0 ]; then
    info "booting installed ${ARCH} system...\n"
    ${QEMU} \
        -smp ${CORES} -M ${MACHINE} ${cpuopt} -m ${MEM} \
        -initrd ${DISK_PATH}/initrd.img -kernel ${DISK_PATH}/vmlinuz \
        -append "root=/dev/debian-vg/root${kcmd}" \
        \
        ${SCSI_OPTS} \
        -drive file=${DISK_PATH}/${DISK_IMAGE}${DRIVE_OPTS},id=rootimg,media=disk \
        \
        ${NETDEV_OPTS} \
        \
        -vnc :0 \
        -monitor unix:${DISK_PATH}/monitor.sock,server,nowait \
        -no-reboot \
       &
    qemu_pid=${!}
fi

# Wait for system to be up
if [ -n "${qemu_pid}" ]; then
    ssh_wait; result=${?}
    if [ ${result} -ne 0 ]; then
        sleep 60
        kill -TERM ${qemu_pid}
        qemu_pid=
    fi
else
    result=1
fi

if [ ${result} -eq 0 ]; then
    info "install packages to support https package feeds...\n"
    ssh_sudo apt-get -qqy install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg2 \
        software-properties-common
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "get docker’s official GPG key\n"
    ssh_cmd curl -fsSL -o docker.gpg https://download.docker.com/linux/debian/gpg
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "adding docker's key...\n"
    ssh_sudo 'apt-key add docker.gpg >/dev/null'
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "adding docker's package feed...\n"
    ssh_cmd  "echo deb https://download.docker.com/linux/debian ${DISTRO} stable>docker.list" && \
    ssh_sudo "cp docker.list /etc/apt/sources.list.d/"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "updating package database...\n"
    ssh_sudo "apt-get -qqy update"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "installing docker-ce...\n"
    ssh_sudo "apt-get -qqy install docker-ce docker-ce-cli containerd.io ${EXTRA_PACKAGES}"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "copying docker's daemon configuration file...\n"
    ssh_copy_to daemon.json && \
    ssh_sudo 'cp daemon.json /etc/docker/'
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "restarting docker...\n"
    ssh_sudo 'systemctl restart docker'
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "getting sources (${latest})...\n"
    ssh_sudo "rm -rf docker-ce" && \
    ssh_cmd  "git clone -b ${latest} --single-branch --depth 1 https://github.com/docker/docker-ce"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "adding user to docker group\n"
    ssh_sudo "adduser ${SSH_USER} docker"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    info "building docker for ${ARCH}...\n"
    ssh_cmd "make -C docker-ce deb DOCKER_BUILD_PKGS=debian-${DISTRO}"
    result=${?}
fi

if [ ${result} -eq 0 ]; then
    mkdir -p ${WORKDIR}/results
    ssh_copy_from \
        docker-ce/components/packaging/deb/debbuild/debian-*/*.deb \
        ${WORKDIR}/results
fi

# Use reboot to stop the virtual machine
if [ -n "${qemu_pid}" ]; then
    info "stopping build vm...\n"
    ssh_sudo reboot
    wait ${qemu_pid}
fi

case ${result} in
    0) status="SUCCEESS" ;;
    *) status="FAILED"   ;;
esac

echo "BUILD ${status}"
