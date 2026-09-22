#!/usr/bin/env perl
# TKT-1127. lib/Tira/CLI/Serve.pm's _stop_police_beside_board and
# _stop_policy_bridge_beside_board are byte-for-byte identical (kill TERM;
# waitpid; return 1) - found during TKT-1125's 2-hourly improvement hunt
# while reviewing the same cleanup path TKT-1125 reused. Pure duplication
# cleanup, no bug, no behavior change.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use lib 't/lib';
use Suite ();

my $source = Suite::cli_source('Serve.pm');
# non-empty is the whole claim - every check below would pass on an
# unreadable file's own emptiness otherwise.
like( $source, qr/\S/, 'Serve.pm source is there to be read' );

# THE DUPLICATION, checked directly rather than assumed: both functions'
# bodies, bounded by their own closing "}", must be identical text before
# the fix, and after the fix each must be a short delegation to one shared
# helper rather than each still carrying its own kill+waitpid.
my ($police_body) = $source =~ /(sub \s+ _stop_police_beside_board \s* \{ .*? \n \})/xs;
my ($bridge_body)  = $source =~ /(sub \s+ _stop_policy_bridge_beside_board \s* \{ .*? \n \})/xs;
ok( defined $police_body, '_stop_police_beside_board was found to read' );
ok( defined $bridge_body,  '_stop_policy_bridge_beside_board was found to read' );

unlike( $police_body // '', qr/kill\s+'TERM'/,
    '_stop_police_beside_board no longer carries its own kill(TERM) - it delegates to a shared helper instead' );
unlike( $bridge_body // '', qr/kill\s+'TERM'/,
    '_stop_policy_bridge_beside_board no longer carries its own kill(TERM) either - same delegation' );

like( $police_body // '', qr/_stop_child_beside_board/,
    '_stop_police_beside_board calls the shared _stop_child_beside_board helper' );
like( $bridge_body // '', qr/_stop_child_beside_board/,
    '_stop_policy_bridge_beside_board calls the shared _stop_child_beside_board helper' );

my ($shared_body) = $source =~ /(sub \s+ _stop_child_beside_board \s* \{ .*? \n \})/xs;
ok( defined $shared_body, 'the shared _stop_child_beside_board helper was found to read' );
like( $shared_body // '', qr/kill\s+'TERM'/,
    'the shared helper carries the one real kill(TERM)' );
like( $shared_body // '', qr/waitpid/,
    'and the one real waitpid' );

# BEHAVIOR UNCHANGED, proved live rather than only read: both wrapper
# functions still kill and reap a real child process and return 1, and
# still return 0 without touching anything for an undef child - exactly
# t/519 and t/1026's own existing assertions, run again here directly
# against both wrappers so this file stands on its own.
use lib 'lib';
use Tira::CLI::Serve;

is( Tira::CLI::Serve::_stop_police_beside_board(undef), 0,
    '_stop_police_beside_board(undef) still returns 0 and does nothing' );
is( Tira::CLI::Serve::_stop_policy_bridge_beside_board(undef), 0,
    '_stop_policy_bridge_beside_board(undef) still returns 0 and does nothing' );

for my $case (
    [ 'police',  \&Tira::CLI::Serve::_stop_police_beside_board ],
    [ 'bridge',  \&Tira::CLI::Serve::_stop_policy_bridge_beside_board ],
) {
    my ( $label, $sub ) = @{$case};
    my $child = fork();
    if ( !defined $child ) {
        fail("$label: could not fork a real child to stop");
        next;
    }
    if ( $child == 0 ) {
        sleep 30;
        exit 0;
    }
    my $stopped = $sub->($child);
    is( $stopped, 1, "$label: a real child was killed and reaped, returning 1" );
    is( kill( 0, $child ), 0, "$label: the child is genuinely gone after stopping" );
}

done_testing();

__END__

=head1 NAME

1145-two-stops-that-were-one.t - _stop_police_beside_board and
_stop_policy_bridge_beside_board share one implementation

=head1 DESCRIPTION

TKT-1127. C<lib/Tira/CLI/Serve.pm>'s C<_stop_police_beside_board> and
C<_stop_policy_bridge_beside_board> were byte-for-byte identical (kill
C<TERM>; C<waitpid>; return 1). Collapsed into one shared
C<_stop_child_beside_board> helper, both existing functions delegating to
it. Checked by reading each function's own source (bounded by its closing
brace) rather than by name alone, and re-proved live: both wrappers still
kill and reap a real forked child and still no-op on C<undef>, exactly as
before.

=cut
