#!/usr/bin/env perl

# Found while gating TKT-709's coverage requirement on lib/Tira/CLI.pm, a
# file that ticket only added a comment to - the gap is pre-existing and
# unrelated to that ticket's own change, but the coverage rule binds on
# any touched module.
#
# lib/Tira/CLI.pm keeps a forwarder for every sub TKT-607 moved into
# lib/Tira/CLI/Move.pm, so a caller still reaching Tira::CLI::<name>
# after the lift gets the same answer rather than "Undefined
# subroutine" - the same reachability guarantee TKT-837's own lift
# documented ("a lift must not change what a caller can reach"). Most of
# these forwarders are exercised because CLI.pm calls its own copy of
# them internally too. _item_is_done and _first_line are not: Move.pm's
# own internal callers reach Move.pm's copy directly (unqualified, so
# Perl resolves it to the current package), and nothing anywhere calls
# the fully-qualified Tira::CLI:: form - so the forwarder itself,
# despite being a real, load-bearing compatibility guarantee, was never
# actually exercised.
#
# Not a bug fix - the forwarders already work correctly. This closes a
# genuine statement/subroutine coverage gap found while gating TKT-709,
# not a red-then-green test.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira::CLI;

is( Tira::CLI::_item_is_done( { status => 'Done' } ), 1,
    'the CLI.pm forwarder for _item_is_done reaches Move.pm and answers correctly' );
is( Tira::CLI::_item_is_done( { status => 'pending' } ), '',
    'and answers correctly for an unfinished item too' );

is( Tira::CLI::_first_line("first line\nsecond line"), 'first line',
    'the CLI.pm forwarder for _first_line reaches Move.pm and answers correctly' );
is( Tira::CLI::_first_line( 'x' x 100 ), ( 'x' x 69 ) . '...',
    'and truncates a long single line the same way Move.pm itself does' );

done_testing;

__END__

=head1 NAME

1097-a-forwarder-nobody-called-by-name.t - lib/Tira/CLI.pm's forwarders for _item_is_done and _first_line are reachable

=head1 DESCRIPTION

lib/Tira/CLI.pm carries a forwarder to lib/Tira/CLI/Move.pm for every sub
TKT-607 lifted out of it, so a caller that still reaches
C<Tira::CLI::E<lt>nameE<gt>> after the lift gets the same answer. Most
forwarders are exercised because CLI.pm also calls its own copy
internally; C<_item_is_done> and C<_first_line> are called only from
inside Move.pm itself (unqualified, resolving to Move.pm's own copy), so
their CLI.pm forwarders - a real compatibility guarantee - were never
actually exercised by anything. This proves both still reach Move.pm and
answer correctly.

=cut
