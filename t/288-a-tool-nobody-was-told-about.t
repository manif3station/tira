#!/usr/bin/env perl
# tools/gate-run exists to save a push from re-running a suite already
# proved, and nothing outside its own header ever said so.
#
# TKT-351 built tools/gate-run and tools/gate-cache-write/read so the
# pre-push hook could trust a suite already proved against the exact tree
# about to be pushed, instead of running it a second time. Verifying a
# change the ordinary way - a manual docker prove-and-cover run, to watch a
# red test turn green - never touches tools/gate-run, so the cache stays
# cold and push pays for the suite again.
#
# Measured on this session, twice, twelve minutes apart, for one release: a
# manual verification run reported "Tests=6474, 783 wallclock secs", and the
# push that followed re-ran the identical suite against the identical
# commit, because nothing had ever recorded a pass for that tree. TKT-415.
#
# README.md's own Verification section already documents the manual command
# this project runs to prove a change - this adds the other half: what to
# run between committing and pushing so the push does not pay for the suite
# twice.

use strict;
use warnings;

use Test::More;

open my $readme, '<', 'README.md' or die "Cannot read README.md: $!";
my $readme_text = do { local $/; <$readme> };
close $readme;

like( $readme_text, qr/tools\/gate-run/,
    'README.md names the tool that avoids a duplicate suite run' );

# The guidance has to say WHEN, not just that the tool exists - the gap this
# ticket found was not that gate-run was unknown, it was that nothing said
# to run it between committing and pushing.
my ($verification) = $readme_text =~ /^## Verification\n(.*?)(?=^## |\z)/ms;
ok( defined $verification, 'the Verification section is where this lives' );
like( $verification, qr/tools\/gate-run/,
    'and the guidance is inside the section about proving a change' );
like( $verification, qr/\bcommit\b.*\bpush\b|\bpush\b.*\bcommit\b/is,
    'and it says where gate-run sits between committing and pushing' );

# The claim has to match what the script actually requires, or this
# documents the same shape of drift TKT-413 just fixed elsewhere in this
# project - a stated instruction nobody checked against the tool it names.
open my $script, '<', 'tools/gate-run' or die "Cannot read tools/gate-run: $!";
my $script_text = do { local $/; <$script> };
close $script;
like( $script_text, qr/Requires a clean tree/,
    "the script itself still requires what this test assumes it does" );
like( $verification, qr/clean/i,
    'and the README says so too, rather than a caller finding out from a refusal' );

done_testing;

__END__

=head1 NAME

288-a-tool-nobody-was-told-about.t - the release workflow names gate-run

=head1 DESCRIPTION

tools/gate-run and the cache it writes exist so a push can trust a suite
already proved rather than running it again - built for TKT-351, and
undocumented anywhere a person or agent doing release work would read it
first. This asserts README.md's Verification section names the tool and
says where it sits between committing and pushing.

=cut
