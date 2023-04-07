#!/bin/bash

set -e
set -u
set -o pipefail
set -x

VERSION="1.2.0"

DESTDIR="${DESTDIR:-}"
PREFIX="${PREFIX:=/usr}"
SBINDIR="${SBINDIR:=$PREFIX/sbin}"
SHAREDIR="${SHAREDIR:=$PREFIX/share}"
SYSTEMDDIR="${SYSTEMDDIR:=$PREFIX/lib/systemd/system}"
CACHEDIR="${CACHEDIR:=/var/cache/pkg-cacher}"
LOGDIR="${LOGDIR:=/var/log/pkg-cacher}"

function create_dirs {
    install -v -m 755 -d ${DESTDIR}/etc/logrotate.d
    install -v -m 755 -d ${DESTDIR}/etc/pkg-cacher
    install -v -m 755 -d ${DESTDIR}${SBINDIR}
    install -v -m 755 -d ${DESTDIR}${SHAREDIR}/pkg-cacher/Repos
    install -v -m 755 -d ${DESTDIR}${SHAREDIR}/man/man1
    install -v -m 755 -d ${DESTDIR}${CACHEDIR}
    install -v -m 755 -d ${DESTDIR}${LOGDIR}
    install -v -m 755 -d ${DESTDIR}${SHAREDIR}/doc/pkg-cacher/client-samples
    install -v -m 755 -d ${DESTDIR}${SYSTEMDDIR}
}

function install_scripts {
    for file_name in "pkg-cacher" "pkg-cacher.pl" "pkg-cacher-request.pl" \
                 "pkg-cacher-fetch.pl" "pkg-cacher-lib.pl" \
                 "pkg-cacher-cleanup.pl" "pkg-cacher-report.pl" "Repos.pm"; do
        install -v -m 755 $file_name ${DESTDIR}${SHAREDIR}/pkg-cacher/
    done
    perl -pe 's/^our \$version=.*/our \$version="'$VERSION'";/' \
        -i ${DESTDIR}${SHAREDIR}/pkg-cacher/pkg-cacher
}

function install_repo_files {
    install -v -m 755 Repos/Debian.pm ${DESTDIR}${SHAREDIR}/pkg-cacher/Repos/
    install -v -m 755 Repos/Fedora.pm ${DESTDIR}${SHAREDIR}/pkg-cacher/Repos/
}

function install_data_files {
    install -v -m 644 index_files.regexp  ${DESTDIR}${SHAREDIR}/pkg-cacher/
    install -v -m 644 static_files.regexp ${DESTDIR}${SHAREDIR}/pkg-cacher/
}

function install_config {
    install -v -m 644 pkg-cacher.conf ${DESTDIR}/etc/pkg-cacher/pkg-cacher.conf
}

function install_docs {
    install -v -m 644 README.md TODO ${DESTDIR}${SHAREDIR}/doc/pkg-cacher
    for file_name in "client-samples/pkg-cacher-debian.list" \
                     "client-samples/pkg-cacher-ubuntu.list" \
                     "client-samples/pkg-cacher-centos.repo" \
                     "client-samples/pkg-cacher-fedora.repo"; do
        install -v -m 644 $file_name ${DESTDIR}${SHAREDIR}/doc/pkg-cacher/client-samples
    done
}

function install_logrotate_config {
    install -v -m 644 pkg-cacher.logrotate ${DESTDIR}/etc/logrotate.d/pkg-cacher
}

function install_manpages {
    install -m 644 debian/pkg-cacher.1 ${DESTDIR}${SHAREDIR}/man/man1/pkg-cacher.1
}

function install_link {
    ln -s -f -v ${DESTDIR}${SHAREDIR}/pkg-cacher/pkg-cacher ${DESTDIR}${SBINDIR}/pkg-cacher
}

function install_systemd_units {
    install -v -m 644 -p contrib/*.service ${DESTDIR}${SYSTEMDDIR}
    install -v -m 644 -p contrib/*.timer   ${DESTDIR}${SYSTEMDDIR}
}

function pre_install {
    getent group pkg-cacher > /dev/null  || echo "Adding system group: pkg-cacher" && groupadd -r pkg-cacher
    getent passwd pkg-cacher > /dev/null || \
      echo "Adding system user: pkg-cacher" && \
        useradd -r -d ${CACHEDIR} -g pkg-cacher -s /sbin/nologin \
          -c "pkg-cacher user" pkg-cacher
}

function systemd_post {
    if [[ -x /usr/bin/systemctl ]]; then
        YAST_IS_RUNNING=${YAST_IS_RUNNING:-}
        if [[ "$YAST_IS_RUNNING" != "instsys" ]]; then
            /usr/bin/systemctl daemon-reload
        else
            true
        fi
    fi
}

function post_install {
    systemd_post
    test -d ${DESTDIR}${CACHEDIR} || {
        mkdir -v ${DESTDIR}${CACHEDIR}{,/cache,/headers,/packages,/private,/temp}
    }
    chown -R pkg-cacher:pkg-cacher ${DESTDIR}${CACHEDIR}
    test -d ${DESTDIR}${LOGDIR} || {
        touch ${DESTDIR}${LOGDIR}/{access.log,error.log}
    }
    chown -R pkg-cacher:pkg-cacher ${DESTDIR}${LOGDIR}
    sed -i -e '/^\(user\|group\)=/s/=.*$/=pkg-cacher/' ${DESTDIR}/etc/pkg-cacher/pkg-cacher.conf
}

function main {
    pre_install
    create_dirs
    install_scripts
    install_repo_files
    install_data_files
    install_config
    install_docs
    install_logrotate_config
    install_manpages
    install_link
    install_systemd_units
    post_install
}

main
