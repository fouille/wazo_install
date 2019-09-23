#!/bin/bash
# Copyright 2016-2019 The Wazo Authors  (see the AUTHORS file)
# SPDX-License-Identifier: GPL-3.0+

# abort on error
set -eo pipefail

mirror="http://mirror.wazo.community"
update='apt-get update'
install='apt-get install --assume-yes'
download='apt-get install --assume-yes --download-only'


check_system() {
    local version_file='/etc/debian_version'
    if [ ! -f $version_file ]; then
        echo "You must install Wazo on a Debian $debian_version (\"$debian_name\") system" 1>&2
        echo "You do not seem to be on a Debian system" 1>&2
        exit 1
    else
        version=$(cut -d '.' -f 1 "$version_file")
    fi

    if [ "$version" != "$debian_version" ]; then
        echo "You must install Wazo on a Debian $debian_version (\"$debian_name\") system" 1>&2
        echo "You are currently on a Debian $version system" 1>&2
        exit 1
    fi
}

add_apt_key() {
    wget $mirror/wazo_current.key -O - | apt-key add -
}

add_mirror() {
    echo "Add mirrors informations"
    local deb_line="deb $mirror/$apt_repo $distribution main"
    apt_dir="/etc/apt"
    sources_list_dir="$apt_dir/sources.list.d"
    if ! grep -qr "$deb_line" "$apt_dir"; then
        echo "$deb_line" > $sources_list_dir/tmp-pf.sources.list
    fi
    add_apt_key

    export DEBIAN_FRONTEND=noninteractive
    $update
    $install xivo-dist
    xivo-dist "$distribution"

    rm -f "$sources_list_dir/tmp-pf.sources.list"
    $update
}

install_wazo () {
    wget -q -O - $mirror/d-i/$debian_name/pkg.cfg | debconf-set-selections

    kernel_release=$(uname -r)
    $install --purge postfix
    $download dahdi-linux-modules-$kernel_release xivo
    $install dahdi-linux-modules-$kernel_release
    $install xivo-base

    if [ $gui -eq 1 ]; then
        $install xivo
    fi

    xivo-service restart all

    if [ $? -eq 0 ]; then
        echo 'You must now finish the installation.'
        if [ $gui -eq 1 ]; then
            echo 'The installation wizard is available at:'
            for ip_address in $(hostname -I); do
                echo "  https://$ip_address/"
            done
        fi
    fi
}

get_ansible_installer() {
    # Install git
    apt-get update
    apt-get install -yq git curl

    # Setup Ansible directory
    rm -rf /usr/src/wazo-ansible
    cd /usr/src

    # Get Ansible installer
    git clone https://github.com/wazo-pbx/wazo-ansible
    cd wazo-ansible

    # Checkout requested Ansible installer version
    git checkout $ansible_tag
}

install_wazo_with_ansible() {
    # Setup Ansible environment
    apt-get install -yq virtualenv python3-pip python
    # Python 3 virtualenv encounters this bug:
    # https://github.com/ansible/ansible/issues/21982
    virtualenv /var/lib/wazo-ansible-venv
    source /var/lib/wazo-ansible-venv/bin/activate
    pip install 'ansible==2.7.9'
    deactivate

    # Run Ansible
    echo "Installing $ansible_tag"
    /var/lib/wazo-ansible-venv/bin/ansible-galaxy install -r requirements-postgresql.yml
    /var/lib/wazo-ansible-venv/bin/ansible-playbook \
        -i inventories/uc-engine \
        --extra-vars wazo_debian_repo="$ansible_repo" \
        --extra-vars wazo_distribution="$distribution" \
        --extra-vars wazo_debian_repo_upgrade="$upgrade_repo" \
        --extra-vars wazo_distribution_upgrade="$upgrade_dist" \
        uc-engine.yml

    # Cleanup Ansible
    rm -rf /var/lib/wazo-ansible-venv
    cd /usr/src
    rm -rf /usr/src/wazo-ansible
    apt-get purge --autoremove -yq python3-pip virtualenv
}

usage() {
    cat << EOF
    This script is used to install Wazo

    usage : $(basename $0) [-c] [-o] {-p|-r|-d|-a version}
        -c                : install console mode (without web interface)
        -o                : install the old way (without ansible)
        without arg (rda) : install production version
        -p                : install the new stable version 19.11+ (pelican)
        -r                : install release candidate version
        -d                : install development version
        -a version        : install archived version

EOF
    exit 1
}

debian_name='buster'
debian_version='10'

# Installing without arguments
apt_repo='debian'
distribution='pelican-buster'
gui=1
use_ansible=0

while getopts ':crdpa:' opt; do
    case ${opt} in
        c)
            gui=0
            ;;
        p)
            use_ansible=1
            ansible_repo=main
            distribution='pelican-buster'
            upgrade_repo=main
            upgrade_dist="$distribution"
            ansible_tag=wazo-$(curl https://mirror.wazo.community/version/stable)
            ;;
        r)
            use_ansible=1
            ansible_repo=main
            distribution='wazo-rc-buster'
            upgrade_repo=main
            upgrade_dist="$distribution"
            ansible_tag=origin/master
            ;;
        d)
            use_ansible=1
            ansible_repo=main
            distribution='wazo-dev-buster'
            upgrade_repo=main
            upgrade_dist="$distribution"
            ansible_tag=origin/master
            ;;
        a)
            apt_repo='archive'
            distribution="wazo-$OPTARG"

            if [ "$OPTARG" \> "19.10" ]; then
                use_ansible=1
                ansible_repo=archive
                ansible_tag="$distribution"
                upgrade_repo=main
                upgrade_dist=pelican-buster
            fi

            if [ "$OPTARG" \< "19.13" ]; then
                debian_version='9'
                debian_name='stretch'
                upgrade_dist=pelican-stretch
            fi

            if [ "$OPTARG" \< "19.10" ]; then
                echo "Ansible install not available for $OPTARG, defaulting to the former way." 1>&2
                use_ansible=0
            fi

            if [ "$OPTARG" \< "18.01" ]; then
                debian_version='8'
                debian_name='jessie'
            fi

            if [ "$OPTARG" \< "16.16" ]; then
                echo "This script only supports installing Wazo 16.16 or later." 1>&2
                exit 1
            fi
            ;;
        *)
            usage
            ;;
    esac
done

check_system

if [ $use_ansible = 0 ]; then
    add_mirror
    install_wazo
else
    get_ansible_installer
    install_wazo_with_ansible
fi
