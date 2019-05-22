#---------------------------------------------------------------------------------------------------
# Add created binary packages to the package repository
#---------------------------------------------------------------------------------------------------

# Path to the repository
aptdir=tmp/deploy/docker-ce

# Create configuration file for reprepro
group "apt"
task "setup" "configuring reprepro..."
begin
    d=${aptdir}/conf
    conf=${d}/distributions
    if [ ! -e ${conf} ]; then
        info "configuring reprepro...\n"
        mkdir -p ${d} && \
        echo "Codename: docker-ce"               >${conf} && \
        echo "Architectures: armhf arm64 amd64" >>${conf} && \
        echo "Components: main"                 >>${conf}
        result=${?}
    fi
end

# Add binary packages to the repository
task "deploy" "adding created packages to the repository..."
deps "docker-ce-${latest}:copy"
begin
    d=tmp/work/${ARCH}/docker-ce-${latest}/results
    for deb in ${d}/*.deb; do
        [ -e ${deb} ] || continue
        reprepro -b ${aptdir} -C main includedeb docker-ce ${deb}
        result=${?}
        [ ${result} -eq 0 ] || break
    done
    [ ${result} -eq 0 ]
end
