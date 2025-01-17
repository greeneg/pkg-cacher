#!/usr/bin/env perl
# vim: ts=4 sw=4 ai si

=head1 NAME

 pkg-cacher - WWW proxy optimized for use with Linux Distribution Repositories

 Copyright (C) 2005 Eduard Bloch <blade@debian.org>
 Copyright (C) 2007 Mark Hindley <mark@hindley.org.uk>
 Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
 Distributed under the terms of the GNU Public Licence (GPL).

=cut
# ----------------------------------------------------------------------------

package PkgCacher::Fetch {
    use strictures;
    use English;
    use utf8;

    use feature ":5.28";
    use feature 'lexical_subs';
    use feature 'signatures';
    no warnings "experimental::signatures";

    use boolean;
    use Data::Dumper;
    use Fcntl qw(:DEFAULT :flock);

    use WWW::Curl::Easy;
    use IO::Socket::INET;
    use HTTP::Response;
    use HTTP::Date;

    use Sys::Hostname;

    use File::Path;

    # Data shared between files
    our $cached_file;
    our $cached_head;
    our $complete_file;
    our @cache_control;

    my $cfg;
    my %pathmap;
    my $pkg_cacher = undef;
    sub new ($class, $_cfg, $_pkg_cacher, $pathmap) {
        say STDERR "Constructing PkgCacher::Fetch object: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $self = {};

        $cfg = $_cfg;
        $pkg_cacher = $_pkg_cacher;
        %pathmap = %{$pathmap};
        undef $_cfg;
        undef $_pkg_cacher;
        undef $pathmap;

        bless($self, $class);
        return $self;
    }

    # Subroutines
    sub head_callback {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        say STDERR "debug: DUMP: ". Dumper(@_) if $ENV{'DEBUG'};

        my $chunk = $_[0];
        my $response = ${$_[1][0]};
        my $write = $_[1][1];

        SWITCH:
        for ($chunk) {
            /^HTTP/ && do {
                my ($proto,$code,$mess) = split(/ /, $chunk, 3);
                $response->protocol($proto);
                $response->code($code);
                $response->message($mess);
                last SWITCH;
            };
            /^\S+: \S+/ && do {
                # debug_message("fetch: Got header $chunk\n");
                $response->headers->push_header(split /: /, $chunk);
                last SWITCH;
            };
            /^\r\n$/ && do {
                $pkg_cacher->debug_message($cfg, "fetch: libcurl download of headers complete: LINE: ". __PACKAGE__ .':'. __LINE__);
                &write_header(\$response) if $write;
                last SWITCH;
            };
            $pkg_cacher->info_message("fetch: warning, unrecognised line in head_callback: $chunk");
        }

        return length($chunk); # OK
    }

    # Arg is ref to HTTP::Response
    sub write_header {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        $pkg_cacher->set_global_lock(": libcurl, storing the header to $cached_head");
        open (my $chfd, ">$cached_head") || barf("Unable to open $cached_head, $!");
        print $chfd ${$_[0]}->as_string;
        close($chfd);
        $pkg_cacher->release_global_lock();
    }

    sub body_callback {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my ($chunk, $handle) = @_;

        # debug_message("fetch: Body callback got ".length($chunk)." bytes for $handle\n");

        # handle is undefined if HEAD, in that case body is usually an error message
        if (defined $handle) {
            print $handle $chunk || return -1;
        }

        return length($chunk); # OK
    }

    our sub debug_callback ($self, $data, $type) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        say STDERR "debug: Dumping arguments list: \n". Dumper(@_) if $ENV{'DEBUG'};
        say STDERR "debug: type: $type";
        $pkg_cacher->write_errorlog("debug CURLINFO_"
            .('TEXT','HEADER_IN','HEADER_OUT','DATA_IN','DATA_OUT','SSL_DATA_IN','SSL_DATA_OUT')[$type]
            ." [$PROCESS_ID]: $data") if ($type < $cfg->{'debug'});
    }

    {
        my $curl; # Make static
        sub setup_curl {
            say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
            return \$curl if (defined($curl));

            $pkg_cacher->debug_message($cfg, 'fetch: init new libcurl object: LINE: '. __PACKAGE__ .':'. __LINE__);
            $curl = WWW::Curl::Easy->new();

            # General
            $curl->setopt(CURLOPT_USERAGENT, "pkg-cacher/$PkgCacher::VERSION (".$curl->version.')');
            $curl->setopt(CURLOPT_NOPROGRESS, 1);
            $curl->setopt(CURLOPT_CONNECTTIMEOUT, 10);
            $curl->setopt(CURLOPT_NOSIGNAL, 1);
            $curl->setopt(CURLOPT_LOW_SPEED_LIMIT, 0);
            $curl->setopt(CURLOPT_LOW_SPEED_TIME, $cfg->{'fetch_timeout'});
            $curl->setopt(CURLOPT_INTERFACE, $cfg->{'use_interface'}) if defined $cfg->{'use_interface'};

            # Callbacks
            $curl->setopt(CURLOPT_WRITEFUNCTION, \&body_callback);
            $curl->setopt(CURLOPT_HEADERFUNCTION, \&head_callback);

            # Disable this, it isn't supported on Debian Etch
            $curl->setopt(CURLOPT_DEBUGFUNCTION, \&debug_callback);
            $curl->setopt(CURLOPT_VERBOSE, ($cfg->{'debug'} or $ENV{'DEBUG'}));

            # SSL
            if (not $cfg->{'require_valid_ssl'}) {
                $curl->setopt(CURLOPT_SSL_VERIFYPEER, 0);
                $curl->setopt(CURLOPT_SSL_VERIFYHOST, 0);
            }

            # Rate limit support
            my $maxspeed;
            foreach my $l ($cfg->{'limit'}) {
                $l =~ /^\d+$/ and do { $maxspeed = $l; last; };
                $l =~ /^(\d+)k$/ and do { $maxspeed = $1 * 1024; last; };
                $l =~ /^(\d+)m$/ and do { $maxspeed = $1 * 1048576; last; };
                warn "Unrecognised limit: $l. Ignoring.";
            }
            if ($maxspeed) {
                $pkg_cacher->debug_message($cfg, "fetch: Setting bandwidth limit to $maxspeed: LINE: ". __PACKAGE__ .':'. __LINE__);
                $curl->setopt(CURLOPT_MAX_RECV_SPEED_LARGE, $maxspeed);
            }

            say STDERR "debug: Dumping curl object: " . Dumper($curl) if $ENV{'DEBUG'};
            return \$curl;
        }
    }

    # runs the get or head operations on the user agent
    sub libcurl ($vhost, $uri, $pkfdref) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $url;
        say STDERR "debug: URL: $uri: LINE: " . __PACKAGE__ .':'. __LINE__;
        my $curl = ${setup_curl()};

        my $hostcand;
        my $response;
        my @headers;

        if (not grep /^Pragma:/, @cache_control) {
            # Remove libcurl default.
            push @headers, 'Pragma:';
        } else {
            push @headers, @cache_control;
        }

        my @hostpaths = @{$pathmap{$vhost}};

        while (true) {
            $response = HTTP::Response->new();

            # validate virtual host is the one we want
            chomp($hostcand = shift(@hostpaths));
            say STDERR "debug: host candidate: $hostcand" if $ENV{'DEBUG'};
            "http://$uri" =~ /^(http:\/\/[a-zA-Z0-9\.]+)\/.*$/;
            say STDERR "debug: match group 1: ". $1 if $ENV{'DEBUG'};
            my $host = $1;
            if ($host eq $hostcand) {
                $pkg_cacher->debug_message($cfg, "fetch: Candidate: $hostcand: LINE: ". __PACKAGE__ .':'. __LINE__);
                $url = $hostcand = ($hostcand =~ /^https?:/ ? '' : 'http://').$uri;
            }

            # Proxy - SSL or otherwise - Needs to be set per host
            if ($url =~ /^https:/) {
                say STDERR "debug: Setting up HTTPS proxy configuration" if $ENV{'DEBUG'};
                $curl->setopt(CURLOPT_PROXY, $cfg->{'https_proxy'}) if ($cfg->{'use_proxy'} and $cfg->{'https_proxy'});
                $curl->setopt(CURLOPT_PROXYUSERPWD, $cfg->{'https_proxy_auth'}) if ($cfg->{'use_proxy_auth'});
            } else {
                say STDERR "debug: Setting up HTTP proxy configuration" if $ENV{'DEBUG'};
                $curl->setopt(CURLOPT_PROXY, $cfg->{'http_proxy'}) if ($cfg->{'use_proxy'} and $cfg->{'http_proxy'});
                $curl->setopt(CURLOPT_PROXYUSERPWD, $cfg->{'http_proxy_auth'}) if ($cfg->{'use_proxy_auth'});
            }
            my $redirect_count = 0;
            my $retry_count = 0;

            while (true) {
                if (not $pkfdref) {
                    $pkg_cacher->debug_message($cfg, 'fetch: setting up for HEAD request: LINE: '. __PACKAGE__ .':'. __LINE__);
                    $curl->setopt(CURLOPT_NOBODY,1);
                } else {
                    $pkg_cacher->debug_message($cfg, 'fetch: setting up for GET request: LINE: '. __PACKAGE__ .':'. __LINE__);
                    $curl->setopt(CURLOPT_HTTPGET,1);
                    $curl->setopt(CURLOPT_FILE, $$pkfdref);
                }

                $curl->setopt(CURLOPT_HTTPHEADER, \@headers);
                $curl->setopt(CURLOPT_WRITEHEADER, [\$response, ($pkfdref ? 1 : 0)]);

                # Make sure URL doesn't contain any illegal characters
                $url =~ s/\r|\n//g;

                $curl->setopt(CURLOPT_URL, $url);

                $pkg_cacher->debug_message($cfg, "fetch: getting $url: LINE: ". __LINE__);

                if ($curl->perform) { # error
                    $response = HTTP::Response->new(502);
                    $response->protocol('HTTP/1.1');
                    $response->message('pkg-cacher: libcurl error: '.$curl->errbuf);
                    error_message("fetch: error - libcurl failed for $url with ".$curl->errbuf);
                    write_header(\$response); # Replace with error header
                }

                $response->request($url);

                my $httpcode = $curl->getinfo(CURLINFO_HTTP_CODE);

                if ($httpcode == 000 || $httpcode == 400) {
                    $retry_count++;
                    if ($retry_count > 5) {
                        info_message("fetch: retry count exceeded, trying next host in path_map");
                        last;
                    }

                    info_message("fetch: Retrying due to bad request or no response code from $url");

                    $url = $hostcand;

                } elsif ($response->is_redirect()) {
                    $redirect_count++;
                    if ($redirect_count > 5) {
                        info_message("fetch: redirect count exceeded, trying next host in path_map");
                        last;
                    }

                    my $newurl = $response->header("Location");

                    if ($newurl =~ /^ftp:/) {
                        # Redirected to an ftp site which won't work, try again
                        info_message("fetch: ignoring redirect from $url to $newurl");
                        $url = $hostcand;
                    } else {
                        info_message("fetch: redirecting from $url to $newurl");
                        $url = $newurl;
                    }
                } else {
                    # It isn't a redirect or a malformed response so we are done
                    last;
                }

                $response = HTTP::Response->new();
                if ($pkfdref) {
                    truncate($$pkfdref, 0);
                    sysseek($$pkfdref, 0, 0);
                }
                unlink($cached_head, $complete_file);
            }

            # if okay or the last candidate fails return
            if ($response->is_success || ! @hostpaths ) {
                last;
            }

            # truncate cached_file to remove previous HTTP error
            if ($pkfdref) {
                truncate($$pkfdref, 0);
                sysseek($$pkfdref, 0, 0);
            }
        }

        $pkg_cacher->debug_message($cfg, "fetch: libcurl response =\n".$response->as_string.": LINE: ". __LINE__);

        return \$response;
    }

    our sub fetch_store ($self, $host, $uri) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $response;
        my $pkfd;
        my $filename;

        ($filename) = ($uri =~ /\/?([^\/]+)$/);

        # remove leading /
        $uri =~ s|^\/||;
        my $url = "http://$uri";
        $pkg_cacher->debug_message($cfg, "fetch: try to fetch $url: LINE: ". __LINE__);

        $cached_file = "$cfg->{cache_dir}/packages/$host/$uri";

        sysopen($pkfd, $cached_file, O_RDWR)
          || $pkg_cacher->barf("Unable to open $cached_file for writing: $!");

        # jump from the global lock to a lock on the target file
        flock($pkfd, LOCK_EX) || barf('Unable to lock the target file');
        $pkg_cacher->release_global_lock();

        $response = ${libcurl($host, $uri, \$pkfd)};

        flock($pkfd, LOCK_UN);
        close($pkfd) or warn "Close $cached_file failed, $!";

        $pkg_cacher->debug_message($cfg, 'fetch: libcurl returned: LINE: '. __LINE__);

        if ($response->is_success) {
            $pkg_cacher->debug_message($cfg, "fetch: stored $url as $cached_file: LINE: ". __LINE__);

            # sanity check that file size on disk matches the content-length in the header
            my $expected_length = -1;
            if (open my $chdfd, $cached_head) {
                foreach my $l (<$chdfd>){
                    if($l =~ /^Content-Length:\s*(\d+)/) {
                        $expected_length = $1;
                        last;
                    }
                }
                close $chdfd;
            }

            my $file_size = -s $cached_file;

            if ($expected_length != -1) {
                if ($file_size != $expected_length) {
                    unlink($cached_file);
                    $pkg_cacher->barf("$cached_file is the wrong size, expected $expected_length, got $file_size");
                }
            } else {
                # There was no Content-Length header so chunked transfer, manufacture one
                open (my $chdfd, ">>$cached_head") || barf("Unable to open $cached_head, $!");
                printf $chdfd "Content-Length: %d\r\n", $file_size;
                close($chdfd);
            }

            # assuming here that the filesystem really closes the file and writes
            # it out to disk before creating the complete flag file

            my $sha1sum = `sha1sum $cached_file`;
            if (not $sha1sum) {
                $pkg_cacher->barf("Unable to calculate SHA-1 sum for $cached_file - error = $?");
            }

            ($sha1sum) = $sha1sum =~ /([0-9A-Fa-f]+) +.*/;

            $pkg_cacher->debug_message($cfg, "fetch: sha1sum $cached_file = $sha1sum: LINE: ". __LINE__);

            $pkg_cacher->set_global_lock(': link to cache');
		
            if (-f "$cfg->{cache_dir}/cache/$filename.$sha1sum") {
                unlink($cached_file);
                link("$cfg->{cache_dir}/cache/$filename.$sha1sum", $cached_file);
            } else {
                link($cached_file, "$cfg->{cache_dir}/cache/$filename.$sha1sum");
            }

            $pkg_cacher->release_global_lock();

            $pkg_cacher->debug_message($cfg, "fetch: setting complete flag for $filename: LINE: ". __LINE__);
            # Now create the file to show the pickup is complete, also store the original URL there
            open(MF, ">$complete_file") || die $!;
            print MF $response->request;
            close(MF);
        } elsif (HTTP::Status::is_client_error($response->code)) {
            $pkg_cacher->debug_message($cfg,
                'fetch: upstream server returned error ' . $response->code . " for " .
                $response->request .
                ". Deleting $cached_file: LINE: ". __LINE__
            );
            unlink $cached_file;
        }
        $pkg_cacher->debug_message($cfg, 'fetch: fetcher done: LINE: '. __LINE__);
    }

    true;
}
