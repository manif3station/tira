#!/usr/bin/env perl

use strict;
use warnings;

use Cwd ();
use File::Spec;
use Test::More;

use lib 'lib';
use Tira;

# On 2026-08-11 this project's own Tira board was destroyed while several test
# containers ran at once against the same mounted directory. The board is not
# in git - it is the live delivery board - so there was nothing to restore
# from, and a morning's cards were gone.
#
# The fix is not discipline. The testing compose file now mounts an empty
# temporary filesystem over the board's directory, so inside a test container
# the production board is not merely off limits, it is not there. This test
# exists to notice if that ever stops being true: it fails the moment a suite
# run can see a real board by walking up from where the tests run.

my ($root) = Cwd::getcwd() =~ /\A([^\x00-\x1f\x7f]+)\z/;

my $found = eval { Tira->new->discover_project };
my $why = $@;

is( $found, undef,
    'no real Tira project is reachable from where the tests run' )
  or diag <<"WHY";

A test run can see the project at:
    $found

That is production data - the board this work is tracked on. Something has
removed the tmpfs mask over its directory from docker-compose.testing.yml, or
the tests are being run outside the container. Either way a test is one
mistake away from writing to the live board, which has already cost a
morning's cards once.
WHY

like( $why, qr/no tira project found/i,
    'and the engine says so plainly rather than failing some other way' );

# The mask is an empty directory rather than nothing at all, so this also
# guards the case where the mount silently stops being applied and the real
# directory shows through with its project file intact.
my $project_file = File::Spec->catfile( $root, '.tira', 'project.yml' );
ok( !-e $project_file,
    'and no project file is visible at the repository root' );

done_testing;

__END__

=head1 NAME

74-production-board.t - the live board must be invisible to the tests

=head1 DESCRIPTION

This project keeps its own delivery board in Tira, in a directory that is
deliberately outside git because it is live data rather than source. On
2026-08-11 that board was destroyed during testing and there was nothing to
restore it from.

The repair was structural rather than procedural: the testing compose file
mounts an empty temporary filesystem over the board's directory, so a test
container cannot see the board at all, and a test that creates a project at
the repository root writes into memory and loses it on exit.

Structural repairs rot quietly when nobody is watching them, so this test
watches. It fails if a suite run can reach a real board from where the tests
run - which is what the mask exists to prevent, and the only warning anyone
would get before the same accident happened twice.

=cut
