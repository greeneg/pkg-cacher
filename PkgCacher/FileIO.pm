package PkgCacher::FileIO {
    use strictures;
    use English;
    use utf8;

    use feature ":5.28";
    use feature 'lexical_subs';
    use feature 'signatures';
    no warnings "experimental::signatures";

    use boolean;
    use Data::Dumper;

    my $lockfile = undef;

    sub new ($class) {
        say STDERR "Constructing PkgCacher::Config object: ". (caller(0))[3] if $ENV{'DEBUG'};
        my $self = {};

        bless($self, $class);
        return $self;
    }

    our sub get_global_lockfile ($self) {
        return $lockfile;
    }

    our sub define_global_lockfile ($self, $exlockfile) {
        say STDERR "In sub: ". (caller(0))[3] if $ENV{'DEBUG'};
        $lockfile = $exlockfile;
        return $lockfile;
    }

    true;
}
