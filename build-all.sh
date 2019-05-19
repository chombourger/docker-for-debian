#!/bin/bash
#---------------------------------------------------------------------------------------------------
# Build docker-ce for all supported Debian configuration
#---------------------------------------------------------------------------------------------------

self=${0}
for a in amd64 arm64 armhf
do
    scr=${self/-all.sh/-${a}.sh}
    ${scr} || exit ${?}
done
