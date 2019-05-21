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

shopt -s expand_aliases

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

COLOR_NC='\e[0m' # No Color
COLOR_WHITE='\e[1;37m'
COLOR_BLACK='\e[0;30m'
COLOR_BLUE='\e[0;34m'
COLOR_LIGHT_BLUE='\e[1;34m'
COLOR_GREEN='\e[0;32m'
COLOR_LIGHT_GREEN='\e[1;32m'
COLOR_CYAN='\e[0;36m'
COLOR_LIGHT_CYAN='\e[1;36m'
COLOR_RED='\e[0;31m'
COLOR_LIGHT_RED='\e[1;31m'
COLOR_PURPLE='\e[0;35m'
COLOR_LIGHT_PURPLE='\e[1;35m'
COLOR_BROWN='\e[0;33m'
COLOR_YELLOW='\e[1;33m'
COLOR_GRAY='\e[0;30m'
COLOR_LIGHT_GRAY='\e[0;37m'

task_name=
task_descr=
task_result=
failed_task=

alias check='if [ ${task_result} -eq 0 ]; then if _check; then true'
alias starting='echo -en "\r${COLOR_BROWN}[RUNNING]${COLOR_NC} ${task_descr}"'
alias success='echo -en "\r${COLOR_GREEN}[SUCCESS]${COLOR_NC} ${task_descr}"'
alias failed='echo -en "\r${COLOR_RED}[FAILED ]${COLOR_NC} ${task_descr}"'
alias begin='check; _begin'
alias end='task_result=${?}; _end; fi; fi'

group() {
    task_group="${1}"
    WORKDIR=tmp/work/${ARCH}/${task_group}
    mkdir -p ${WORKDIR}/logs ${WORKDIR}/stamps
}

task() {
    task_name="${1}"
    task_descr="${2:-${task_name}}"
    task_stamp="${3:-1}"
    task_log=${WORKDIR}/logs/log.do_${task_name}.${$}
    task_result=${task_result:-0}
}

_begin() {
    starting
    task_start=${SECONDS}

    touch ${task_log}
    rm -f ${WORKDIR}/logs/log.do_${task_name}
    ln -s $(basename ${task_log}) ${WORKDIR}/logs/log.do_${task_name}

    exec 8>&1 9>&2
    exec >${task_log} 2>&1
}

_end() {
    exec 1>&8 2>&9
    task_end=${SECONDS}
    task_duration=$((${task_end} - ${task_start}))

    if [ ${task_duration} -ge 60 ]; then
        units="minutes"
        task_duration=$((${task_duration} / 60))
    else
        units="seconds"
    fi

    if [ ${task_result} -eq 0 ]; then
        touch ${WORKDIR}/stamps/${task_name}.done
        success
        echo " (took ${task_duration} ${units})"
    else
        failed
        echo -e " (failed after ${task_duration} ${units})${COLOR_RED}"
        tail ${task_log}
        echo -e "${COLOR_NC}(full log can be found in ${task_log})" >&2
        failed_task="${task_name}"
    fi
}

_check() {
    local _do_task

    [ ${task_stamp} -eq 0 ] || [ ! -f ${WORKDIR}/stamps/${task_name}.done ]
    _do_task=${?}
    return ${_do_task}
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

group "setup"
task  "hostdeps" "installing host dependencies..."
begin
    install_build_host_deps
end

task "upstreamcheck" "checking latest docker-ce build..." "0"
begin
    latest=$(curl -s ${DOCKER_REPO}/releases/latest|sed -e 's,.*<a href=",,g'|cut -d '"' -f1)
    latest=$(basename ${latest})
    info "upstream version is ${latest}\n"
end

# Copy preseed file to local web server
task "copypreseed" "copying preseed to ${WWW_DIR}..."
begin
    cat preseed.cfg \
        | HTTP_PROXY="${HTTP_PROXY}" \
          SSH_PASS="${SSHPASS}" \
          SSH_USER="${SSH_USER}" \
          envsubst \
        | sudo tee ${WWW_DIR}/preseed.cfg \
        > /dev/null
end

group "$(echo ${DEBIAN_VERSION}|tr '[:upper:]' '[:lower:]')-installer"
task  "fetch" "getting ${ARCH} kernel and ramdisk..."
begin
    if [ ! -e ${WORKDIR}/${DI_INITRD} ] || [ ! -e ${WORKDIR}/${DI_KERNEL} ]; then
        info "getting ${ARCH} kernel and ramdisk\n"
        url=${DEBIAN_BASE_URL}/${DEBIAN_VERSION}/${DI_PATH}
        mkdir -p ${WORKDIR} && \
        pushd ${WORKDIR} >/dev/null && \
        wget -qc ${url}/${DI_INITRD} && \
        wget -qc ${url}/${DI_KERNEL} && \
        popd >/dev/null
    fi
end

# Create (empty) disk image
task "diskimage" "creating ${DISK_SIZE} disk image..."
begin
    mkdir -p ${DISK_PATH} && \
    qemu-img create -f qcow2 ${DISK_PATH}/${DISK_IMAGE} ${DISK_SIZE} >/dev/null
end

# Install Debian to the disk image
task "install" "installing Debian for ${ARCH}..."
begin
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
end

# Extract kernel/initrd from disk
task "extract" "extracting installed kernel and ramdisk..."
begin
    sudo modprobe nbd max_part=8 && \
    sudo qemu-nbd --connect=/dev/nbd0 ${DISK_PATH}/${DISK_IMAGE} && \
    sudo partprobe /dev/nbd0 && \
    mkdir -p ${DISK_PATH}/mnt && \
    sudo mount /dev/nbd0p1 ${DISK_PATH}/mnt && \
    cp $(find ${DISK_PATH}/mnt -maxdepth 1 -type f -name initrd\*) ${DISK_PATH}/initrd.img && \
    cp $(find ${DISK_PATH}/mnt -maxdepth 1 -type f -name vmlinuz\*) ${DISK_PATH}/vmlinuz
end

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

# Boot installed system
qemu_pid=
group "docker-ce-${latest}"
task "boot" "starting ${ARCH} vm..." "0"
begin
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
end

# Wait for system to be up
if [ -n "${qemu_pid}" ]; then
    ssh_wait; task_result=${?}
    if [ ${task_result} -ne 0 ]; then
        sleep 60
        kill -TERM ${qemu_pid}
        qemu_pid=
    fi
else
    task_result=1
fi

task "setup" "installing packages to support https package feeds..."
begin
    ssh_sudo apt-get -qqy install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg2 \
        software-properties-common
end

task "getgpg" "get docker’s official GPG key..."
begin
    ssh_cmd curl -fsSL -o docker.gpg https://download.docker.com/linux/debian/gpg
end

task "addgpg" "adding docker's key..."
begin
    ssh_sudo 'apt-key add docker.gpg >/dev/null'
end

task "addsrc" "adding docker's package feed..."
begin
    ssh_cmd  "echo deb https://download.docker.com/linux/debian ${DISTRO} stable>docker.list" && \
    ssh_sudo "cp docker.list /etc/apt/sources.list.d/"
end

task "aptupd" "updating package database..."
begin
    ssh_sudo "apt-get -qqy update"
end

task "install" "installing docker-ce..."
begin
    ssh_sudo "apt-get -qqy install docker-ce docker-ce-cli containerd.io ${EXTRA_PACKAGES}"
end

task "config" "copying docker's daemon configuration file..."
begin
    ssh_copy_to daemon.json && \
    ssh_sudo 'cp daemon.json /etc/docker/'
end

task "restart" "restarting docker..."
begin
    ssh_sudo 'systemctl restart docker'
end

task "fetch" "getting sources (${latest})..."
begin
    ssh_sudo "rm -rf docker-ce" && \
    ssh_cmd  "git clone -b ${latest} --single-branch --depth 1 https://github.com/docker/docker-ce"
end

task "adduser" "adding user to docker group..."
begin
    ssh_sudo "adduser ${SSH_USER} docker"
end

check_stamp=1
task "build" "building docker for ${ARCH}..."
begin
    check_stamp=0
    ssh_cmd "make -C docker-ce deb DOCKER_BUILD_PKGS=debian-${DISTRO}"
end

task "copy" "getting deb packages from build vm..." "${check_stamp}"
begin
    mkdir -p ${WORKDIR}/results && \
    ssh_copy_from \
        docker-ce/components/packaging/deb/debbuild/debian-*/*.deb \
        ${WORKDIR}/results
end

# Use reboot to stop the virtual machine
if [ -n "${qemu_pid}" ]; then
    info "stopping build vm...\n"
    ssh_sudo reboot
    wait ${qemu_pid}
fi

case ${task_result} in
    0) status="SUCCEESS"                ;;
    *) status="FAILED (${failed_task})" ;;
esac

echo "BUILD ${status}"
