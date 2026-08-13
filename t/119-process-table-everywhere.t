#!/usr/bin/env perl
# The process table, as three real machines actually print it.
#
# ps puts its start time in a different field order depending on the platform:
#
#   Linux   1 Tue May 26 08:06:05 2026 /usr/lib/systemd/systemd
#   macOS   1 Thu 13 Aug 01:52:51 2026 /sbin/launchd
#
# Day name, month, day on one; day name, day, month on the other. Both regexes
# that read the table required a month name in the second field, so on macOS
# every line failed to match: 192 lines of ps output produced 0 processes and 0
# start times, where the same command on Linux produced 711 of each.
# leftover-process therefore reported nothing on a Mac whatever was running.
#
# The lines below are literal output captured from the labs, not written from
# memory. That distinction is the whole point of this card: the previous
# release dismissed the macOS lab in writing, on the grounds that it would only
# add a second POSIX platform that Linux already covered. BSD ps is not Linux
# ps, and the lab settled in one command what the reasoning got wrong.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira::CLI;

# --- captured from the Linux container ------------------------------------

my @linux = (
    '      1 Tue May 26 08:06:05 2026 /usr/lib/systemd/systemd --system --deserialize=130 splash',
    '      2 Tue May 26 08:06:05 2026 [kthreadd]',
);

# --- captured from the macOS lab, 14.8.5 ----------------------------------

my @macos = (
    '    1 Thu 13 Aug 01:52:51 2026     /sbin/launchd',
    '   83 Thu 13 Aug 01:52:57 2026     /usr/libexec/logd',
    '   84 Thu 13 Aug 01:52:57 2026     /usr/libexec/smd',
);

my $from_linux = Tira::CLI::_processes_from( \@linux );
is( scalar @{$from_linux}, 2, 'every line of Linux ps output is read' );
is( $from_linux->[0]{pid}, 1, 'with the process number' );
is( $from_linux->[0]{started_at}, '2026-05-26T08:06:05',
    'and the start time, month named in the second field' );
like( $from_linux->[0]{command}, qr/systemd/, 'and what is running' );

my $from_macos = Tira::CLI::_processes_from( \@macos );
is( scalar @{$from_macos}, 3, 'every line of macOS ps output is read too' );
is( $from_macos->[0]{pid}, 1, 'with the process number' );
is( $from_macos->[0]{started_at}, '2026-08-13T01:52:51',
    'and the start time, month named in the third field instead' );
like( $from_macos->[0]{command}, qr{/sbin/launchd}, 'and what is running' );

is( $from_macos->[1]{started_at}, '2026-08-13T01:52:57',
    'and the rest of them, rather than only the first' );

# --- the month is found, not assumed by position --------------------------
#
# Deciding by platform would be wrong on the first machine whose locale prints
# something else. Whichever field is a month name is the month, which needs no
# knowledge of where it is running.

is( Tira::CLI::_stamp_from_ps('Thu 13 Aug 01:52:51 2026'), '2026-08-13T01:52:51',
    'day before month is read' );
is( Tira::CLI::_stamp_from_ps('Tue May 26 08:06:05 2026'), '2026-05-26T08:06:05',
    'and month before day' );

# --- and anything else answers with nothing -------------------------------
#
# Rather than an invented time, which would make every age rule wrong instead
# of absent - and wrong is worse than absent, because absent can be noticed.

is( Tira::CLI::_stamp_from_ps('not a date at all'), undef, 'an unreadable time answers with nothing' );
is( Tira::CLI::_stamp_from_ps('Thu 13 Zzz 01:52:51 2026'), undef,
    'and so does one whose month is not a month' );
is( Tira::CLI::_stamp_from_ps('Thu 13 14 01:52:51 2026'), undef,
    'and one with two numbers where a month belongs' );

is_deeply( Tira::CLI::_processes_from( ['a line that is not a process at all'] ), [],
    'a line that is not a process is not counted as one' );

done_testing();

__END__

=head1 NAME

119-process-table-everywhere.t - the process table as three real machines print it

=head1 DESCRIPTION

ps puts the month before the day on Linux and after it on macOS. Both regexes
that read the table required a month name in the second field, so every line on
macOS failed to match and the process table came back empty - 192 lines in, 0
out, where Linux gave 711 of each.

The month is now whichever field is a month name, which is decidable without
knowing the platform and so cannot be wrong on a machine nobody anticipated.

The sample lines are literal output captured from the labs rather than written
from memory, because the previous release dismissed the macOS lab in reasoning
and the lab disagreed in one command.

=cut
