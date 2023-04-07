# pkg-cacher - A transparent package cache for Debian, Red Hat, SUSE

Pkg-cacher is a transparent caching server for APT and YUM/DNF repositories. In 2008 it was forked from Debian's [apt-cacher](https://tracker.debian.org/pkg/apt-cacher) (1.6.4) by Robert Nelson and enhanced to support RPM repositories used in the Red Hat and SUSE distribution families.

Since the `pkg-cacher` release [1.1.0](https://github.com/open-sw/pkg-cacher/releases) in 2014 its development is stalled but its still fully functional and I added some bug fixes and enhancements to maintain compatibility with some recent repository archive changes.

## Description

Pkg-cacher performs caching of packages and metadata which have been downloaded by local users. It is most useful for local area networks with slow internet uplink or many machines running the same distribution and version.

When a package is requested, the cache checks whether it already has the requested version, in which case it sends the package to the user immediately. If not, it downloads the package while streaming it to the user at the same time. A local copy is then kept for use by other users.

Pkg-cacher has been optimized for best utilization of network bandwidth and efficiency even on slow low-memory servers. Multiple ways of installation are possible: as a stand-alone HTTP proxy, as a daemon executed by inetd or as a CGI program. Client machines are configured by changing APT's proxy configuration or modification of access URLs in sources.list or .repo files.

The package includes utilities to clean the cache (removing obsolete package files), generate usage reports.

## Installation

### Docker

To keep your data out of Docker container, we do a volume (`/var/pkg-cacher` -> `/var/cache/pkg-cacher`) here, and you can change it based on your situation.

```
# Pull image from Docker Hub.
$ docker pull linuxmonk/pkg-cacher

# Create local directory for repository cache.
$ sudo mkdir -p /var/pkg-cacher

# Use `docker run` for the first time.
$ docker run --name=pkg-cacher -p 80:8080 -v /var/pkg-cacher:/var/cache/pkg-cacher linuxmonk/pkg-cacher

# Use `docker start` if you have stopped it.
$ docker start pkg-cacher
```

### Debian/Ubuntu

* Install build dependencies:
```
$ sudo apt install make debhelper dh-systemd
```
* Change to the source directory and run the following command to create the `pkg-cacher` deb packages:
```
$ make debs
```
* The generated packages are then stored in the `../dist/debian` directory.

* They can be installed from there. E.g. the standalone version via:
```
$ sudo apt install ../dist/debian/pkg-cacher{,-sa}_1.1.1_all.deb
```

### Fedora/CentOS

_Hint: On CentOS replace the 'dnf' commands with 'yum'._

* Install build dependencies:
```
$ sudo dnf install make rpm-build
```

* Change to the source directory and run the following command to create the `pkg-cacher` RPMs:
```
$ make rpms
```
* The generated packages are then stored in the `../dist/pkg-cacher` directory.

* They can be installed from there. E.g. the standalone version via:
```
$ sudo dnf install ../dist/pkg-cacher/pkg-cacher{,-sa}-1.1.1-1.noarch.rpm
```

## Authors and License

- [Robert Nelson](https://github.com/Robert-Nelson) | [email](mailto:robertn@the-nelsons.org)
- Mark Hindley | [email](mailto:mark@hindley.org.uk)
- Eduard Bloch | [email](mailto:blade@debian.org)
- Nick Andrews | [email](mailto:nick@zeta.org.au)

License: [GPL-2](https://tldrlegal.com/license/gnu-general-public-license-v2)
