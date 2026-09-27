#!/usr/bin/env perl
# TKT-1169. SKILLS.md's own 'tira.<type>.list' catalogue line - the one
# _usage() finds first for a typed list command, ahead of %RECORD_USAGE's
# own fallback - never mentioned --count or --fields, even though both are
# real, genuinely-accepted options (lib/Tira/CLI.pm:188/193) and both
# already appear in %RECORD_USAGE{list}'s OWN text. Because the SKILLS.md
# line is checked first and matches, %RECORD_USAGE's line is never reached,
# so having --count/--fields there already did nothing for the printed
# usage. TKT-1161 added five other missing flags to this same SKILLS.md
# line without noticing these two were also missing.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
require Tira::CLI::Usage;

for my $type (qw(ticket epic sow)) {
    my $usage = Tira::CLI::Usage::_usage( 'record.list', $type );
    like( $usage, qr/--count\b/, "tira.$type.list --help names --count, which record_list genuinely accepts" );
    like( $usage, qr/--fields\b/, "tira.$type.list --help names --fields, which record_list genuinely accepts" );
    like( $usage, qr/^Usage: d2 tira\.\Q$type\E\.list\b/,
        'and still names the command actually asked about' );
}

done_testing;

__END__

=head1 NAME

1171-a-usage-line-that-forgot-count-and-fields.t - list's usage line never named --count or --fields

=head1 DESCRIPTION

TKT-1169. C<d2 tira.<type>.list --help> never showed C<--count> or
C<--fields>, even though C<record_list> genuinely accepts both
(confirmed live: C<--count --sum> together return a real error about the
numeric field, not "unknown option"). Both already appear in
C<%RECORD_USAGE{list}>'s own text in C<Tira::CLI::Usage>, but that
fallback is never reached for a typed list command - SKILLS.md's own
generic C<tira.<type>.list> catalogue line is found first and wins
(TKT-418's precedence order), and that line never had them either.

=cut
