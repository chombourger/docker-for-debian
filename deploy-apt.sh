#---------------------------------------------------------------------------------------------------
# Add created binary packages to the package repository
#---------------------------------------------------------------------------------------------------

# Path to the repository
aptdir=tmp/deploy/docker-ce

# Create configuration file for reprepro
if [ ${result} -eq 0 ]; then
    d=${aptdir}/conf
    conf=${d}/distributions
    if [ ! -e ${conf} ]; then
        info "configuring reprepro..."
        mkdir -p ${d} && \
        echo "Codename: docker-ce"               >${conf} && \
        echo "Architectures: armhf arm64 amd64" >>${conf} && \
        echo "Components: main"                 >>${conf}
        result=${?}
    fi
fi

# Add binary packages to the repository
if [ ${result} -eq 0 ]; then
    d=tmp/work/${ARCH}/docker-ce-${latest}/results
    for deb in ${d}/*.deb; do
        [ -e ${deb} ] || continue
        info "adding $(basename ${deb}) to the repository..."
        reprepro -b ${aptdir} -C main includedeb ${DISTRO} ${deb}
        result=${?}
        [ ${result} -eq 0 ] || break
    done
fi
