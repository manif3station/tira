#!/usr/bin/env perl
# TKT-1160. show's %RECORD_USAGE line ('--ref REF [--fields LIST]
# [--brief|--full]') never mentioned --refs, the batch-read form
# record_show_many implements and docs/commands.md documents (line ~3809:
# "--refs A,B,C to show, the response keyed by ref with the request order
# preserved"). Confirmed live: --help for ticket.show/epic.show/sow.show
# all share this one line, via Tira::CLI::Usage's %RECORD_USAGE table.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
require Tira::CLI::Usage;

for my $type (qw(ticket epic sow)) {
    my $usage = Tira::CLI::Usage::_usage( 'record.show', $type );
    like( $usage, qr/--refs/,
        "tira.$type.show --help names --refs, the batch-read form record_show_many implements" );
    like( $usage, qr/^Usage: d2 tira\.\Q$type\E\.show\b/,
        "and still names the command actually asked about" );
}

done_testing;

__END__

=head1 NAME

1166-a-usage-line-that-forgot-the-batch-flag.t - show's usage line never named --refs

=head1 DESCRIPTION

TKT-1160. C<d2 tira.<type>.show --help> (and the usage line printed on a
missing C<--ref>) showed only C<--ref REF [--fields LIST] [--brief|--full]>
- never C<--refs>, the batch-read form C<record_show_many> implements and
C<docs/commands.md> documents. Shared by ticket/epic/sow show since they
all read the one C<%RECORD_USAGE{show}> line in C<Tira::CLI::Usage>.

=cut
