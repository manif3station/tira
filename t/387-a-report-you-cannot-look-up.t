#!/usr/bin/env perl
# TKT-283. dev.found.bug_or_improvement --help names no arguments, so the one
# command an agent reaches for after already hitting trouble is the one it
# cannot look up without a second command. SKILLS.md documents this command
# only mid-sentence, inside a prose paragraph, wrapped in backticks - never
# at the start of a line - so _skills_usage_line()'s start-of-line regex
# never matches it, and _usage() falls all the way through to the bare
# "[options]" placeholder. TKT-343 fixed this exact defect shape for six
# other commands by adding a start-of-line usage line to SKILLS.md; this one
# was simply missed.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira::CLI;
# Tira::CLI::Usage holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Usage;

my $usage = Tira::CLI::Usage::_usage( 'dev.found.bug_or_improvement', undef );

unlike( $usage, qr/\[options\]\s*\[-o/,
    'tira.dev.found.bug_or_improvement --help no longer answers with a bare [options]' )
  or diag($usage);
like( $usage, qr/--from/,  'and names --from' );
like( $usage, qr/--title/, 'and names --title' );
like( $usage, qr/--text/,  'and names --text' );
like( $usage, qr/^Usage: dashboard tira\.dev\.found\.bug_or_improvement\b/,
    'still names the command that was actually asked about' );

done_testing;

__END__

=head1 NAME

387-a-report-you-cannot-look-up.t - dev.found.bug_or_improvement --help names its own arguments

=head1 DESCRIPTION

TKT-283: SKILLS.md mentioned C<tira.dev.found.bug_or_improvement> only
mid-sentence in prose, never at the start of a line, so
C<_skills_usage_line()>'s start-of-line regex never matched it and
C<--help> fell through to the generic C<[options]> placeholder - the same
defect shape TKT-343 fixed for six other commands. SKILLS.md now also
carries a start-of-line usage line for this command, naming C<--from>,
C<--title>, and C<--text>.

=cut
