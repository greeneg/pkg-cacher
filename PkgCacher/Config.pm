package PkgCacher::Config {
    use strictures;
    use English;
    use utf8;

    use feature ":5.28";
    use feature 'lexical_subs';
    use feature 'signatures';
    no warnings "experimental::signatures";

    use boolean;
    use Try::Tiny qw(try catch);

    sub new ($class) {
        say STDERR "Constructing PkgCacher::Config object: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $self = {};

        bless($self, $class);
        return $self;
    }

    our sub read_config ($self, $config_file) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        # set the default config variables
        my %config = (
            cache_dir => '/var/cache/pkg-cacher',
            logdir => '/var/log/pkg-cacher',
            admin_email => 'root@localhost',
            generate_reports => 0,
            expire_hours => 0,
            http_proxy => '',
            https_proxy => '',
            use_proxy => 0,
            http_proxy_auth => '',
            https_proxy_auth => '',
            use_proxy_auth => 0,
            require_valid_ssl => 1,
            debug => 0,
            clean_cache => 0,
            allowed_hosts_6 => '*',
            allowed_hosts => '*',
            limit => 0,
            daemon_port => 8080,
            fetch_timeout => 300 # five minutes from now
        );

        my $conf_fh = undef;
        try {
            open $conf_fh, $config_file or die $!;
        } catch {
            chomp $ARG;
            say "Error: Cannot open file $config_file";
            exit 2;
        };

        my $buf = undef;
        try {
            read($conf_fh, $buf, -s $conf_fh);
        } catch {
            chomp $ARG;
            say "Error: Cannot read from filehandle for $config_file";
            exit 5;
        };
        $buf =~ s/\\\n#/\n#/mg; # fix broken multilines
        $buf =~ s/\\\n//mg; # merge multilines

        foreach my $token (split(/\n/, $buf)) {
            next if ($token =~ m/^#/); # weed out whole comment lines immediately

            $token =~ s/#.*//;  # kill off comments
            $token =~ s/^\s+//;	# kill off leading spaces
            $token =~ s/\s+$//;	# kill off trailing spaces

            if ($token) {
                my ($key, $value) = split(/\s*=\s*/, $token);	# split into key and value pair
                $value = 0 unless ($value);
                #print "key: $key, value: $value\n";
                $config{$key} = $value;
                #print "$config{$key}\n";
            }
        }

        close $conf_fh;

        return \%config;
    }


    true;
}
