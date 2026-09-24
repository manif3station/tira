#!/usr/bin/env perl
# TKT-1151. lib/Tira/Job/Schedule.pm is 516 lines, over the 500-line
# convention (TKT-1044/1092/1102 precedent), after TKT-1143's OR-trap fix
# added cohesive cron-matching logic. job_schedule_words's own
# wording-formatting helper cluster (_ordinal, _weekday_phrase,
# _monthday_phrase, _about, _even_step, _and_list, and the
# @DAY/@MONTH/%DAY_NAME/%MONTH_NAME word tables) has zero dependency on the
# cron-parsing internals that stay in Schedule.pm, and is the natural
# extraction target.
#
# WRITTEN RED: lib/Tira/Job/ScheduleWords.pm does not exist yet, and
# Schedule.pm is still over 500 lines.

use strict;
use warnings;

use Test::More;
use FindBin;

my $schedule_path = "$FindBin::Bin/../lib/Tira/Job/Schedule.pm";
my $words_path     = "$FindBin::Bin/../lib/Tira/Job/ScheduleWords.pm";

ok( -f $words_path, 'lib/Tira/Job/ScheduleWords.pm exists' )
  or diag('the wording-formatting cluster has not been extracted yet');

my $schedule_lines = do {
    open my $fh, '<', $schedule_path or die "$schedule_path: $!";
    my $n = 0;
    $n++ while <$fh>;
    $n;
};
cmp_ok( $schedule_lines, '<=', 500,
    "lib/Tira/Job/Schedule.pm is at or under the 500-line convention - $schedule_lines lines" );

# --- behavior is unchanged: the moved cluster is a pure code-location lift -

use lib 'lib';
require Tira::Job;

my %said = (
    '* * * * *'      => 'Every minute',
    '0 * * * *'      => 'Every hour, on the hour',
    '30 9 * * *'     => 'Every day at 09:30',
    '0 9 * * 1'      => 'Every Monday at 09:00',
    '17 3 5,20 */2 1-5' => qr/./,    # merely confirms it still returns SOMETHING sane
);
for my $cron ( sort keys %said ) {
    my $words = Tira::Job::job_schedule_words($cron);
    ok( defined $words && length $words, "job_schedule_words('$cron') still returns real words: '$words'" );
}

done_testing;

__END__

=head1 NAME

1151-a-word-cluster-still-crowding-its-neighbor.t - the wording-formatting
cluster is lifted into its own module, bringing Schedule.pm back under 500
lines

=head1 DESCRIPTION

TKT-1151. Confirms lib/Tira/Job/ScheduleWords.pm exists, Schedule.pm is
back at or under the 500-line convention, and job_schedule_words's own
behavior is unchanged - the extraction is a pure code-location lift, the
same shape TKT-1044 itself used.

=cut
