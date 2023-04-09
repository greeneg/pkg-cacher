# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
#
# This is a library file for Pkg-cacher to allow code
# common to Pkg-cacher itself plus its supporting scripts
# (pkg-cacher-report.pl and pkg-cacher-cleanup.pl) to be
# maintained in one location.

# This function reads the given config file into the
# given hash ref. The key and value are separated by
# a '=' and will have all the leading and trailing
# spaces removed.

package PkgCacher {
    use strictures;
    use English;
    use utf8;

    use feature ":5.28";
    use feature 'lexical_subs';
    use feature 'signatures';
    no warnings "experimental::signatures";

    use boolean;
    use Data::Dumper;
    use Fcntl qw(:flock);

    use File::Basename;

    use Try::Tiny qw(try catch);

    our $cfg;

    our $erlog_fh = undef;
    our $aclog_fh = undef;

    my $exlockfile = undef;
    sub new ($class, $_cfg, $_elfile) {
        say STDERR "Constructing PkgCacher object: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $self = {};

        $cfg = $_cfg;
        $exlockfile = $_elfile;

        bless($self, $class);
        return $self;
    }

    our sub read_patterns ($self, $filename) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $file = '/usr/share/pkg-cacher/' . $filename;
        my @pattern;

        if (open(my $fd, $file)) {
            foreach my $line (<$fd>) {
                $line =~ s/#.*$//;
                $line =~ s/[\s]+//;
                next if $line =~ m/^$/;
                push(@pattern, $line);
            }
        }

        return join('|', @pattern);
    }

    # check directories exist and are writable
    # Needs to run as root as parent directories may not be writable
    our sub check_install ($self, $cfg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        # Die if we have not been configured correctly
        say STDERR "DEBUG: ". Dumper($cfg) if $ENV{'DEBUG'};
        if (exists $cfg->{'cache_dir'} && defined $cfg->{'cache_dir'}) {
            if (not -d $cfg->{'cache_dir'}) {
                say STDERR basename($PROGRAM_NAME) . ": No cache_dir directory! Exiting";
                exit 2;
            }
        } else {
            say STDERR basename($PROGRAM_NAME) . ": No cache_dir is configured! Exiting";
            exit 1;
        }

        say STDERR "Info: Checking for user $cfg->{'user'}" if $ENV{'DEBUG'};
        my $uid = $cfg->{'user'}  =~ /^\d+$/ ? $cfg->{'user'} : getpwnam($cfg->{'group'});
        say STDERR "Info: Checking for group $cfg->{'group'}" if $ENV{'DEBUG'};
        my $gid = $cfg->{'group'} =~ /^\d+$/ ? $cfg->{'group'} : getgrnam($cfg->{'group'});

        if (not defined ($uid || $gid)) {
            say STDERR "Unable to get user:group";
            exit 1;
        }

        foreach my $dir ($cfg->{'cache_dir'}, $cfg->{'logdir'},
                "$cfg->{'cache_dir'}/headers", "$cfg->{'cache_dir'}/packages",
                "$cfg->{'cache_dir'}/private", "$cfg->{'cache_dir'}/temp",
                "$cfg->{'cache_dir'}/cache") {
            say STDERR "Info: Checking for $dir" if $ENV{'DEBUG'};
            if (not -d $dir) {
                say STDERR "Warning: $dir missing. Doing mkdir($dir, 0755)";
                mkdir($dir, 0755) || die "Unable to create $dir";
                chown($uid, $gid, $dir) || die "Unable to set ownership for $dir";
            }
        }
        for my $file ("$cfg->{logdir}/access.log", "$cfg->{logdir}/error.log") {
            if (not -e $file) {
                say STDERR "Warning: $file missing. Creating";
                open(my $tmp, ">$file") || die "Unable to create $file";
                close($tmp);
                chown($uid, $gid, $file) || die "Unable to set ownership for $file";
            }
        }
    }

    # Convert a human-readable IPv4 address to raw form (4-byte string)
    # Returns undef if the address is invalid
    our sub ipv4_normalise ($self, $addr) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        return undef if $addr =~ /:/;
        my @in = split (/\./, $addr);
        return '' if $#in != 3;
        my $out = '';
        foreach my $num (@in) {
            return undef if $num !~ /^[[:digit:]]{1,3}$/o;
            $out .= pack ("C", $num);
        }
        return $out;
    }

    # Convert a human-readable IPv6 address to raw form (16-byte string)
    # Returns undef if the address is invalid
    sub ipv6_normalise ($addr) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        return "\0" x 16 if $addr eq '::';
        return undef if $addr =~ /^:[^:]/  || $addr =~ /[^:]:$/ || $addr =~ /::.*::/;
        my @in = split (/:/, $addr);
        return undef if $#in > 7;
        shift @in if $#in >= 1 && $in[0] eq '' && $in[1] eq ''; # handle ::1 etc.
        my $num;
        my $out = '';
        my $tail = '';
        while (defined ($num = shift @in) && $num ne '') {  # Until '::' found or end
            # Mapped IPv4
            if ($num =~ /^(?:[[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}$/) {
                $out .= ipv4_normalise($num);
            } else {
                return undef if $num !~ /^[[:xdigit:]]{1,4}$/o;
                $out .= pack ("n", hex $num);
            }
        }
        foreach $num (@in) { # After '::'
            # Mapped IPv4
            if ($num =~ /^(?:[[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}$/) {
                $tail .= ipv4_normalise($num);
                last;
            } else {
                return undef if $num !~ /^[[:xdigit:]]{1,4}$/o;
                $tail .= pack ("n", hex $num);
            }
        }
        my $l = length ($out.$tail);
        return $out.("\0" x (16 - $l)).$tail if $l < 16;
        return $out.$tail if $l == 16;
        return undef;
    }

    # Make a netmask from a CIDR network-part length and the IP address length
    sub make_mask ($mask, $bits) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        return undef if $mask < 0 || $mask > $bits;
        my $m = ("\xFF" x ($mask / 8));
        $m .= chr ((-1 << (8 - $mask % 8)) & 255) if $mask % 8;
        return $m . ("\0" x ($bits / 8 - length ($m)));
    }

    # Arg is ref to flattened hash. Returns hash ref
    sub hashify {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        unless ($cfg->{'debug'}) {
            no warnings 'uninitialized'
        }
        return {split(/ /, ${$_[0]})};
    }

    our sub info_message ($self, $msg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        $self->write_errorlog("info [$PROCESS_ID]: $msg");
    }

    our sub error_message ($self, $msg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        $self->write_errorlog("error [$PROCESS_ID]: $msg");
    }

    our sub debug_message ($self, $cfg, $msg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        if ($cfg->{'debug'}) {
            $self->write_errorlog("debug [$PROCESS_ID]: $msg");
        }
    }

    our sub open_log_files ($self, $cfg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $logfile = "$cfg->{'logdir'}/access.log";
        my $errorfile = "$cfg->{'logdir'}/error.log";

        if (defined $erlog_fh) {
            open($erlog_fh, ">>", "$errorfile") or barf("Unable to open $errorfile, $!");
        }
        if (defined $aclog_fh) {
            open($aclog_fh,">>", "$logfile") or barf("Unable to open $logfile, $!");
        }
        # Install signal handlers to capture error messages
        $SIG{__WARN__} = sub { $self->write_errorlog("warn [$PROCESS_ID]: " . shift) };
        $SIG{__DIE__}  = sub { $self->write_errorlog("error [$PROCESS_ID]: " . shift) };
    }

    # Jon's extra stuff to write errors to a log file.
    our sub write_errorlog ($self, $msg, $erlog_fh = undef) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $time = localtime;

        # Prevent double newline
        chomp $msg;

        if (not defined $erlog_fh) {
            say STDERR "$msg"; # Better than nothing
            return;
        } else {
            flock($erlog_fh, LOCK_EX);
            # files may need to be reopened sometimes - reason unknown yet, EBADF
            # results
            syswrite($erlog_fh,"$time|$msg\n") || $self->open_log_files();
            flock($erlog_fh, LOCK_UN);
        }
    }

    my $exlock;

    sub set_global_lock ($self, $msg) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        die ("Global lock file unknown") if not defined($exlockfile);
        $msg = '' if not defined($msg);

        $self->debug_message($cfg, "Entering critical section $msg: LINE: ". __LINE__);

        # may need to create it if the file got lost
        my $createstr = (-f $exlockfile) ? '' : '>';

        open($exlock, $createstr.$exlockfile);
        if ( !$exlock || not flock($exlock, LOCK_EX)) {
            $self->debug_message($cfg, "unable to achieve a lock on $exlockfile: $!: LINE: ". __LINE__);
            die "Unable to achieve lock on $exlockfile: $!";
        }
    }

    our sub release_global_lock ($self) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        $self->debug_message($cfg, "Exiting critical section: LINE: ". __LINE__);
        flock($exlock, LOCK_UN);
    }

    our sub setup_ownership ($self) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $uid=$cfg->{'user'};
        my $gid=$cfg->{'group'};

        if ($cfg->{'chroot'}) {
            say STDERR "Info: Configuration requesting chroot'd operation";
            if ($uid || $gid) {
                # open them now, before it is too late
                # FIXME: reopening won't work, but the lose of file handles needs to be
                # made reproducible first
                $self->open_log_files;
            }
            chroot $cfg->{'chroot'} || die "Unable to chroot, aborting.\n";
            chdir $cfg->{'chroot'};
        }

        if ($gid) {
            say STDERR "Info: Checking if requested GID($gid) exists" if $ENV{'DEBUG'};
            if ($gid =~ /^\d+$/) {
                my $name = getgrgid($gid);
                die "Unknown group ID: $gid (exiting)\n" if !$name;
            } else {
                $gid=getgrnam($gid);
                die "No such group (exiting)\n" if not defined($gid);
            }
            say STDERR "Info: Requested GID($gid) exists" if $ENV{'DEBUG'};
            $EGID = "$gid $gid";
            $GID  = $gid;
            $EGID =~ /^$gid\b/ and $GID =~ /^$gid\b/ or barf("Unable to change real and effective group id");
        }

        if ($uid) {
            if($uid=~/^\d+$/) {
                my $name = getpwuid($uid);
                die "Unknown user ID: $uid (exiting)\n" if !$name;
            } else {
                $uid=getpwnam($uid);
                die "No such user (exiting)\n" if !defined($uid);
            }
            $> = $uid;
            $< = $uid;
            $> == $uid && $< == $uid || barf("Unable to change user id");
        }
    }

    our sub barf ($error) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        say STDERR 'Fatal error: ' . basename($0) . ": $error";
        exit 1;
    }

    our sub is_index_file ($self, $filename) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $index_files_regexp = '(?:' . $self->read_patterns('index_files.regexp') . ')$';
        if (defined $filename) {
            return ($filename =~ /$index_files_regexp/);
        } else {
            return undef;
        }
    }

    #### common code for installation scripts ####
    sub remove_apache {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        foreach my $apache ("apache", "apache-ssl", "apache2") {
            # Remove the include lines from httpd.conf
            my $httpdconf = "/etc/$apache/httpd.conf";
            if (-f $httpdconf) {
                my $old = $httpdconf;
                my $new = "$httpdconf.tmp.$$";
                my $bak = "$httpdconf.bak";
                my $done;

                my $o_fh;
                my $n_fh;
                open $o_fh, "<", "$old" or die "can't open $old: $!";
                open $n_fh, ">", "$new" or die "can't open $new: $!";

                foreach my $line (<$o_fh>) {
                    $done += s/# This line has been appended by the Pkg\-cacher install script/ /;
                    $done += s/Include \/etc\/pkg\-cacher\/apache.conf/ /;
                    (print $n_fh $line) or die "can't write to $new: $!";
                }

                close $o_fh or die "can't close $old: $!";
                close $n_fh or die "can't close $new: $!";

                if (not $done) {
                    unlink $new;
                    last;
                }
                rename($old, $bak)          or die "can't rename $old to $bak: $!";
                rename($new, $old)          or die "can't rename $new to $old: $!";
    #			if (-f "/etc/init.d/$apache")
    #			{
    #				`/etc/init.d/$apache restart`;
    #			}
            }
        }
    }

    true;
}
