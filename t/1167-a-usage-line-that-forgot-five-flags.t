#!/usr/bin/env perl
# TKT-1161. list's %RECORD_USAGE line ('[--column SLUG] [--assignee ID]
# [--fields LIST] [--count] [--sum FIELD]') never mentioned --where,
# --since, --label, --refs-only, or --meta-only - all five genuinely
# accepted by record_list (lib/Tira.pm) via the global option table
# (lib/Tira/CLI.pm:163/191/193/201). Confirmed live: --help for
# ticket.list/epic.list/sow.list all share this one line, via
# Tira::CLI::Usage's %RECORD_USAGE table. --count and --sum were already
# present (this ticket's acceptance_criteria predates TKT-730 adding
# --sum), so only the five genuinely-missing flags are asserted here.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
require Tira::CLI::Usage;

for my $type (qw(ticket epic sow)) {
    my $usage = Tira::CLI::Usage::_usage( 'record.list', $type );
    like( $usage, qr/--where/,     "tira.$type.list --help names --where, which record_list genuinely accepts" );
    like( $usage, qr/--since/,     "tira.$type.list --help names --since, which record_list genuinely accepts" );
    like( $usage, qr/--label/,     "tira.$type.list --help names --label, which record_list genuinely accepts" );
    like( $usage, qr/--refs-only/, "tira.$type.list --help names --refs-only, which record_list genuinely accepts" );
    like( $usage, qr/--meta-only/, "tira.$type.list --help names --meta-only, which record_list genuinely accepts" );
    like( $usage, qr/^Usage: d2 tira\.\Q$type\E\.list\b/,
        'and still names the command actually asked about' );
}

done_testing;

__END__

=head1 NAME

1167-a-usage-line-that-forgot-five-flags.t - list's usage line never named five flags it genuinely accepts

=head1 DESCRIPTION

TKT-1161. C<d2 tira.<type>.list --help> showed only
C<[--column SLUG] [--assignee ID] [--fields LIST] [--count] [--sum FIELD]>
- never C<--where>, C<--since>, C<--label>, C<--refs-only>, or
C<--meta-only>, all five genuinely accepted by C<record_list>. Shared by
ticket/epic/sow list since they all read the one
C<%RECORD_USAGE{list}> line in C<Tira::CLI::Usage>.

=cut
