package Tira::Job::ScheduleWords;

# TKT-1151. Lifted out of Tira::Job::Schedule, which crossed the 500-line
# convention (TKT-1044/1092/1102 precedent) after TKT-1143's OR-trap fix
# added cohesive cron-matching logic. This is the wording-formatting half
# of that module: turning a parsed schedule into a phrase ("Every 30
# minutes"), with zero dependency on the cron-parsing internals
# (_cron_field_values, @CRON_FIELDS) that stay behind in Schedule.pm.
#
# Every function here still takes exactly the arguments it took inside
# Schedule.pm - nothing closes over anything, so the lift is mechanical.
# job_schedule_words itself stays in Schedule.pm (it needs the parsing
# internals) and calls into this module by fully-qualified name.

use strict;
use warnings;

our @DAY = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);

our %DAY_NAME = (
    sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
);

our @MONTH = qw(January February March April May June
               July August September October November December);

our %MONTH_NAME = do {
    my $n = 0;
    map { ( lc substr( $_, 0, 3 ) => ++$n ) } @MONTH;
};

# 1st, 2nd, 3rd, 4th - because "on the 1 of each month" is the kind of wording a
# reader stops on instead of reading the schedule.
sub _ordinal {
    my ($n) = @_;
    return "${n}th" if $n % 100 >= 11 && $n % 100 <= 13;
    my %suffix = ( 1 => 'st', 2 => 'nd', 3 => 'rd' );
    return $n . ( $suffix{ $n % 10 } // 'th' );
}

# A list of things as a sentence rather than as data: "08:00, 12:00 and 18:00".
# IS THIS EVERY-N, or does it just look like it? Cron restarts a step at the
# start of its range, so */7 on minutes fires at 0,7,...,56 and then 0 - a gap of
# FOUR, not seven - and */5 on hours leaves a four-hour gap at midnight. "Every 7
# minutes" is the nearly-right description this sub exists to refuse.
#
# ASKED OF THE EXPANDED VALUES RATHER THAN THE TEXT, which is stronger than the
# divisibility test it replaces: it answers for ranges and lists too, and it
# includes the WRAP - the gap from the last value back to the first - which is
# exactly where */7 stops being every-seven.
# WHAT MAKES A DESCRIPTION APPROXIMATE, said in the description itself. His
# answer to Q-119: "Describe everything, marking the approximate ones as
# approximate - e.g. 'About every 7 minutes (restarts each hour)'".
#
# The mark and the REASON travel together on purpose. "About every 7 minutes" on
# its own is a hedge; with "(restarts each hour)" it is an explanation, and a
# reader who needs the exact firing times knows where the imprecision is.
# " every Monday", " every weekday", " every weekend day" - or undef when the
# field selects no day or all of them, which is not a restriction worth wording.
sub _weekday_phrase {
    my ($selected) = @_;
    # 7 IS SUNDAY AS WELL AS 0, which is standard cron.
    my %once;
    my @day = sort { $a <=> $b }
      grep { !$once{$_}++ } map { $_ == 7 ? 0 : $_ } @{$selected};
    return undef if @day == 0 || @day == 7;
    return ' every weekday'     if @day == 5 && "@day" eq '1 2 3 4 5';
    return ' every weekend day' if @day == 2 && "@day" eq '0 6';
    return ' every ' . _and_list( map { $DAY[$_] } @day );
}

# " on the 1st of each month", " on 1 January", " every day in March"
sub _monthday_phrase {
    my ( $dom, $mon, $values ) = @_;
    my @date  = @{ $values->{'day of month'} };
    my @month = @{ $values->{month} };
    return undef if !@date || !@month;

    my $which = $dom eq '*' ? '' : _and_list( map { _ordinal($_) } @date );
    return " on the $which of each month" if $mon eq '*';
    return ' every day in ' . _and_list( map { $MONTH[ $_ - 1 ] } @month )
      if $dom eq '*';
    my $phrase = " on $which " . _and_list( map { $MONTH[ $_ - 1 ] } @month );
    $phrase =~ s/(\d+)(?:st|nd|rd|th)/$1/g;
    return $phrase;
}

sub _about {
    my ( $phrase, $why ) = @_;
    return "About $phrase ($why)";
}

sub _even_step {
    my ( $values, $size ) = @_;
    return undef if @{$values} < 2;
    my $step = $values->[1] - $values->[0];
    for my $i ( 2 .. $#{$values} ) {
        return undef if $values->[$i] - $values->[ $i - 1 ] != $step;
    }

    # AND THE WRAP, which is the gap this whole guard exists for. */7 on minutes
    # has seven between every pair and FOUR from 56 back to 0; 0-20/2 on hours
    # has two between every pair and four from 20 back to 0. Checking only the
    # pairs would call both of them even, which is the exact sentence this sub
    # refuses to write.
    return undef if $size - $values->[-1] + $values->[0] != $step;
    return $step;
}

sub _and_list {
    my (@item) = @_;
    return $item[0] if @item == 1;
    my $last = pop @item;
    return join( ', ', @item ) . " and $last";
}

1;
