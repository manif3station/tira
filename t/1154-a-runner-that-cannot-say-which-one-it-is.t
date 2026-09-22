#!/usr/bin/env perl
# TKT-649. No command named the running Tira version - $Tira::VERSION
# existed internally but nothing exposed it, so a stale install shadowing
# a fresh one (project-local vs installed, or a forgotten reinstall) was
# silently undetectable from any command's own output. Measured live:
# two checkouts of the same repo answered the same board at two different
# versions, one accepting and ignoring a flag the other had already
# implemented, with nothing either process could run saying which was
# which.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tira = Tira->new;
my $out  = '';
open my $capture, '>', \$out or die $!;
my $status = do {
    local *STDOUT = $capture;
    Tira::CLI->run( command => 'version', tira => $tira, argv => [ '-o', 'json' ] );
};
close $capture;

is( $status, 0, 'tira.version answers, not a refusal' )
  or diag("output: $out");
# non-empty is the whole claim
like( $out, qr/\S/, 'the command prints something' );
like( $out, qr/\Q$Tira::VERSION\E/,
    'and it names the exact running $Tira::VERSION' );

# --- the REAL d2-reachable entrypoint exists too, not only the internal ----
# --- dispatch table - a dotted command (card.required) reaches Tira::CLI ---
# --- through a shared generic router, but a bare single-word command like -
# --- 'version' needs its OWN cli/ script or 'd2 tira.version' itself never
# --- resolves, however correct the internal dispatch is (Codex review) -----

{
    my $script = File::Spec->catfile( $FindBin::Bin, '..', 'cli', 'version' );
    ok( -f $script, 'cli/version exists - the real d2-reachable entrypoint' )
      or diag("no such file: $script");
    ok( -x $script, 'and it is executable' ) if -f $script;

    SKIP: {
        skip 'cli/version missing', 1 if !-f $script;
        my $printed = `perl -Ilib "$script" -o json 2>&1`;
        like( $printed, qr/\Q$Tira::VERSION\E/,
            'and running it directly answers the same running version' );
    }
}

done_testing;

__END__

=head1 NAME

1154-a-runner-that-cannot-say-which-one-it-is.t - tira.version names the
running version

=head1 DESCRIPTION

TKT-649. C<$Tira::VERSION> existed but nothing exposed it - C<d2
tira.version> answered "Command 'version' not found". A stale install
shadowing a fresh one was undetectable from any command's own output, and
was discovered live only by comparing file sizes on disk. C<tira.version>
now answers C<{ version => $Tira::VERSION }>, a static fact requiring no
board or project context, the same shape C<tira.card.required> already
answers.

=cut
