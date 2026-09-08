#!/usr/bin/env perl
# TKT-672. An install whose Changes file names a newer release than the
# code actually running produces exactly this symptom: a flag the
# changelog documents refused as "Unknown option", with nothing saying
# why. Reported live: a session ran a 4.56 install against a repo at 4.59
# for its whole length, reading refusals for flags TKT-598 had already
# shipped.
#
# THE FIX: the engine's own changelog (beside the running module, the same
# way _collector_script finds its sibling) is compared against $VERSION.
# When the changelog names something newer, an "Unknown option" refusal now
# says so and names the install command - rather than leaving the reader
# to work out, from a report a session filed against itself, that its own
# install was stale.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

# --- the detector itself ------------------------------------------------

{
    no warnings 'redefine';
    local *Tira::_engine_changes_text = sub { "9.99  2099-01-01\n    - future stuff\n" };
    my $said = Tira::_version_mismatch();
    like( $said, qr/9\.99/, 'a changelog naming a newer release than $VERSION is reported' );
    like( $said, qr/\Q$Tira::VERSION\E/, 'and the running version is named too' );
    like( $said, qr/d2 skills install tira/, 'and the remedy names the actual install command' );
}

{
    no warnings 'redefine';
    local *Tira::_engine_changes_text = sub { "$Tira::VERSION  2026-01-01\n    - x\n" };
    is( Tira::_version_mismatch(), undef, 'a changelog that agrees with $VERSION reports nothing' );
}

{
    no warnings 'redefine';
    local *Tira::_engine_changes_text = sub { undef };
    is( Tira::_version_mismatch(), undef,
        'a missing changelog is silence, not a fault - _engine_changes_text\'s own convention' );
}

# --- wired into the refusal an agent actually sees -----------------------

{
    no warnings 'redefine';
    require Tira::CLI;
    local *Tira::_version_mismatch = sub { 'the installed changelog names 9.99 but the code running is 1.00 - re-run the install: cd ~; d2 skills install tira' };
    my $tira = Tira->new;
    open my $eh, '>', \my $said or die $!;
    local *STDERR = $eh;
    Tira::CLI::_error( $tira, 'json', "Unknown option: brief\n" );
    like( $said, qr/9\.99/, 'an "Unknown option" refusal now carries the version drift' );
    like( $said, qr/d2 skills install tira/, 'and the remedy command' );
}

done_testing();

__END__

=head1 NAME

672-a-refusal-that-forgot-to-check-itself.t - a stale install's own
changelog mismatch is named on an "Unknown option" refusal

=head1 DESCRIPTION

TKT-672. C<Tira::_version_mismatch> compares the engine's own Changes file
(read the same way C<_collector_script> finds its sibling) against
C<$Tira::VERSION>. When the changelog names something newer, the code has
not actually been updated to match it - an install that copied a new
Changes without the C<lib/> that goes with it, say. C<Tira::CLI::_error>
now appends this to any "Unknown option" refusal, so a flag the changelog
documents but the running code does not recognise is reported as a version
drift with the install command named, rather than left to read as a typo.

=cut
