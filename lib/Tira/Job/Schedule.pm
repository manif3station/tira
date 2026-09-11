package Tira::Job::Schedule;

# Cron schedule parsing, validation and wording, lifted out of Tira::Job -
# TKT-1044, the same week TKT-1041/1042/1043 lifted three other oversized
# files' own separable concerns.
#
# Every function here still takes exactly the arguments it took inside
# Tira::Job - nothing closes over anything, so the lift is mechanical.
# Documentation of Tira::Job's OWN overall concern (why a schedule lives on
# the board rather than as a session loop, the two output modes, the two
# schedule kinds) stays in Tira::Job, deliberately - it explains the file's
# own concern, not these functions specifically. The "A SCHEDULE THAT READS
# AS WORDS" section, which is specifically about job_schedule_words, moves
# here with it.
#
# CALLED THROUGH A FORWARD OF THE SAME NAME in Tira::Job, required at the
# point of use, exactly Tira::CLI::Move's own shape. Not renamed, so every
# existing caller - Tira::CLI::Browser::Jobs and Tira::CLI::Job, which
# already reach schedule_refusal and job_schedule_words by their
# fully-qualified Tira::Job:: name - needed no change at all. Calls between
# these functions, inside this module, are made directly by their own short
# name; the two callers left behind in Tira::Job (_job_fields validating a
# write, job_is_due checking a stored schedule) reach _cron_parse and
# _cron_minute_matches through Tira::Job's own forwarding stub, unqualified,
# since no test monkey-patches either by a fully-qualified name.

use strict;
use warnings;

my @CRON_FIELDS = (
    { name => 'minute',       min => 0, max => 59 },
    { name => 'hour',         min => 0, max => 23 },
    { name => 'day of month', min => 1, max => 31 },
    { name => 'month',        min => 1, max => 12 },
    { name => 'day of week',  min => 0, max => 7 },
);

# One field of one expression, expanded to the set of values it matches.
# Returns nothing when the field is malformed, and the caller turns that into
# a refusal naming the field - so every rejection can say where it was.
sub _cron_field_values {
    my ( $spec, $field ) = @_;
    my %hit;
    for my $part ( split /,/, $spec, -1 ) {
        return if $part eq '';

        my $step = 1;
        if ( $part =~ s{/(\d+)\z}{} ) {
            $step = $1;
            return if $step == 0;
        }

        my ( $from, $to );
        if ( $part eq '*' ) {
            ( $from, $to ) = ( $field->{min}, $field->{max} );
        }
        elsif ( $part =~ /\A(\d+)-(\d+)\z/ ) {
            ( $from, $to ) = ( $1, $2 );
        }
        elsif ( $part =~ /\A(\d+)\z/ ) {
            ( $from, $to ) = ( $1, $1 );

            # A bare number with a step means "from here to the end", the
            # way cron reads 5/10. Without this, '0/2' matched only 0.
            $to = $field->{max} if $step > 1;
        }
        else {
            return;
        }

        return if $from < $field->{min} || $to > $field->{max} || $from > $to;
        for ( my $v = $from; $v <= $to; $v += $step ) { $hit{$v} = 1 }
    }
    return \%hit;
}

# Parses a crontab expression into five value-sets, or dies naming the field
# and its range. Dying rather than returning false is deliberate: every
# caller of this wants the reason, and the one place that does not (the
# due-check, reading an already-stored schedule) has already been past this
# on the way in.
sub _cron_parse {
    my ($schedule) = @_;
    die "A schedule is required\n" if !defined $schedule || $schedule eq '';

    my @parts = split ' ', $schedule;
    die "A cron schedule has five fields (minute hour day month weekday), not "
      . scalar(@parts) . " - got '$schedule'\n"
      if @parts != 5;

    my @sets;
    for my $i ( 0 .. 4 ) {
        my $values = _cron_field_values( $parts[$i], $CRON_FIELDS[$i] );
        die "The $CRON_FIELDS[$i]{name} field '$parts[$i]' is not valid - it takes "
          . "$CRON_FIELDS[$i]{min} to $CRON_FIELDS[$i]{max}\n"
          if !$values;
        push @sets, $values;
    }
    return \@sets;
}

# Why a schedule would be refused, as a string, or undef when it is fine.
#
# THE SAME VALIDATOR THE WRITE PATH USES, which is the whole point. The editor
# modal has to tell somebody their crontab is wrong while they type, and the
# obvious way to do that is a regex in JavaScript - which is how the engine and
# the browser ended up disagreeing about attachment content types (TKT-713).
# Two validators for one format do not stay equal; they drift, and the drift is
# only discovered when a value the browser accepted is refused on save.
#
# So this asks _cron_parse and reports what it said. It does not decide
# anything itself, which means it cannot disagree with the write path however
# the rules change later. EPC-014, TKT-843.
sub schedule_refusal {
    my ($schedule) = @_;
    return 'A schedule is required - a cron expression, or \'monitor\''
      if !defined $schedule || $schedule eq '';
    return undef if $schedule eq 'monitor';

    local $@;
    return undef if eval { _cron_parse($schedule); 1 };
    my $why = $@ || 'That schedule cannot be read';
    $why =~ s/\s+\z//;
    return $why;
}

my @DAY = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);

my %DAY_NAME = (
    sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
);

my @MONTH = qw(January February March April May June
               July August September October November December);

my %MONTH_NAME = do {
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

sub job_schedule_words {
    my ( $schedule, $restart_every ) = @_;
    return '' if !defined $schedule;

    # A LOOPING MONITOR SAYS SO. His report, 2026-09-04: "If I job original added
    # as a loop and sleep for 5 seconds... didn't show on the card that is a
    # loop." restart_every appears three times in the jobs view and all three are
    # the editor or the save, so the board showed a looping monitor and a
    # one-shot one identically. TKT-915.
    #
    # ADDED TO THE PHRASE RATHER THAN REPLACING IT, because both things are true
    # and the first is the more important: it does run continuously, and the
    # interval is how it comes back when the command inside it ends.
    #
    # THE SECOND ARGUMENT IS OPTIONAL AND MUST STAY SO. Tira::CLI::Browser calls
    # this with a schedule alone, and t/517 asserts a dozen cron phrasings
    # through the one-argument form - a required parameter here would take the
    # whole schedule column with it.
    if ( $schedule eq 'monitor' ) {
        return 'Runs continuously' if !$restart_every;
        my $unit = $restart_every == 1 ? 'second' : 'seconds';
        return "Runs continuously, restarting $restart_every $unit after it ends";
    }

    my @field = split /\s+/, $schedule;
    return $schedule if @field != 5;
    my ( $min, $hour, $dom, $mon, $dow ) = @field;

    # THE OR TRAP, AND IT IS THE ONE THING IN CRON MOST OFTEN GOT WRONG. When
    # BOTH day fields are restricted cron ORs them: "0 0 1 * 1" fires on the 1st
    # of the month AND on every Monday, not on Mondays that fall on the 1st.
    #
    # IT IS DESCRIBED RATHER THAN REFUSED, on his answer to Q-119 - and NOT
    # marked "About", because it is not approximate. It is exact and surprising,
    # and a hedge would describe the wrong difficulty. What it needs is the OR
    # said outright, which "and also" does and no shorter phrasing does. TKT-917.
    my $both_days = $dom ne '*' && $dow ne '*';

    # THE EXPANDER THIS MODULE ALREADY HAS, not a second one. _cron_field_values
    # and %CRON_FIELDS have parsed every cron field since _cron_parse was
    # written - steps, ranges, lists and cron's own "5/10" - and they are the
    # validator the write path uses. I wrote a rival by the same name here and
    # it silently REDEFINED the original, which is how a fresh sub with the same
    # name behaves in Perl: the later one wins and everything that called the
    # first gets the second. TKT-917.
    # NAMES FIRST. Cron accepts "sun" and "jan" and a person writing a schedule
    # by hand usually writes them; _cron_field_values takes numbers, so they are
    # turned into numbers here rather than by teaching the validator a second
    # syntax it would then have to refuse consistently.
    my @field_text = @field;
    $field_text[3] =~ s/([a-z]{3,})/exists $MONTH_NAME{lc $1} ? $MONTH_NAME{lc $1} : $1/gie;
    $field_text[4] =~ s/([a-z]{3,})/exists $DAY_NAME{lc $1}   ? $DAY_NAME{lc $1}   : $1/gie;

    my %values;
    for my $i ( 0 .. 4 ) {
        my $set = _cron_field_values( $field_text[$i], $CRON_FIELDS[$i] );
        return $schedule if !$set;
        $values{ $CRON_FIELDS[$i]{name} } = [ sort { $a <=> $b } keys %{$set} ];
    }
    my $minutes = $values{minute};
    my $hours   = $values{hour};


    # WHICH DAYS, as a phrase appended to whatever the time reads as. Empty when
    # the schedule runs every day, which is the common case and needs no words.
    my $on_day = '';
    my $also   = '';
    if ( $both_days ) {
        # Both halves, joined by "and also" - the one phrasing that cannot be
        # read as an AND of the two conditions.
        $also = _weekday_phrase( $values{'day of week'} );
        return $schedule if !defined $also;
        my $dates = _monthday_phrase( $dom, $mon, \%values );
        return $schedule if !defined $dates;

        # "and also" rather than "and", because "and" reads as an AND of the two
        # conditions - which is the misreading this whole branch exists to stop.
        $on_day = "$dates, and also$also";
    }
    elsif ( $dow ne '*' ) {
        $on_day = _weekday_phrase( $values{'day of week'} );
        return $schedule if !defined $on_day;
    }
    elsif ( $dom ne '*' || $mon ne '*' ) {
        $on_day = _monthday_phrase( $dom, $mon, \%values );
        return $schedule if !defined $on_day;
    }

    # --- and now the time of day ---------------------------------------------

    my $every_minute = @{$minutes} == 60;
    my $every_hour   = @{$hours} == 24;

    if ($every_minute) {
        return "Every minute$on_day" if $every_hour;

        # EVERY MINUTE OF A RESTRICTED HOUR. '* 9 * * *' is every minute between
        # 09:00 and 09:59 - valid, common, and exactly describable - and it came
        # back as raw cron until the coverage gate asked why this line was never
        # reached. That is his Q-119 rule broken in a corner nobody had looked
        # at. TKT-917.
        #
        # ":59" rather than ":00", because the hour is not an instant here: the
        # schedule runs THROUGH it, and "from 09:00 to 09:00" would read as one
        # firing.
        my $span = sub { return sprintf '%02d:%02d', $_[0], $_[1] };
        # A single hour is a span too - 09:00 to 09:59 - not a list of one. It
        # shares the branch rather than getting its own, because "Every minute
        # of 09:00" reads as one firing at nine o'clock, which is the opposite
        # of what it means.
        if ( $hours->[-1] - $hours->[0] == $#{$hours} ) {
            return 'Every minute from '
              . $span->( $hours->[0], 0 ) . ' to ' . $span->( $hours->[-1], 59 )
              . $on_day;
        }
        return 'Every minute of '
          . _and_list( map { $span->( $_, 0 ) } @{$hours} ) . $on_day
          if @{$hours} <= 6;
        return _about(
            'every minute from '
              . $span->( $hours->[0], 0 ) . ' to ' . $span->( $hours->[-1], 59 )
              . $on_day,
            'not every hour between them' );
    }

    # A minute STEP, which is only every-N when N divides the hour. Cron restarts
    # the step at the top of each hour, so */7 fires at 0,7,...,56 and then 0 - a
    # gap of FOUR minutes, not seven. _cron_field_values refuses those, so
    # anything that reaches here with several minutes is an honest step.
    if ( @{$minutes} > 1 ) {
        return $schedule if !$every_hour;
        my $step = _even_step( $minutes, 60 );
        return "Every $step minutes$on_day" if $step && $step > 1;

        # NOT EVEN, SO IT IS MARKED RATHER THAN REFUSED. His answer to Q-119.
        # */7 fires at 0,7,...,56 then 0 - a gap of four - so "every 7 minutes"
        # would be false, and "About every 7 minutes (restarts each hour)" is
        # true, useful, and says where the imprecision is.
        if ( $field[0] =~ m{\A\*/([1-9][0-9]*)\z} ) {
            return _about( "every $1 minutes$on_day", 'restarts each hour' );
        }
        return $schedule;
    }

    # 0 + it, so a zero-padded field does not leak its padding into the words:
    # "09" is a perfectly good cron minute and a poor English one.
    my $at_minute = 0 + $minutes->[0];

    if ($every_hour) {
        return "Every hour, on the hour$on_day" if $at_minute == 0;
        # Singular at one, because "1 minutes past" is the kind of thing a
        # reader notices instead of the schedule.
        my $unit = $at_minute == 1 ? 'minute' : 'minutes';
        return "Every hour at $at_minute $unit past$on_day";
    }

    my $clock = sub { return sprintf '%02d:%02d', $_[0], $at_minute };

    # An hour STEP - his 0 */2 * * *. Same divisibility rule as the minute step,
    # against 24 rather than 60: */5 on hours fires at 0,5,10,15,20 then 0, a
    # four-hour gap, and _cron_field_values has already refused it.
    # A contiguous RANGE of hours is a range, not a step of one - and it is
    # tested before the step so "9-17" does not read as "every 1 hours".
    if ( @{$hours} > 1 && $hours->[-1] - $hours->[0] == $#{$hours} ) {
        return 'Every hour from '
          . $clock->( $hours->[0] ) . ' to ' . $clock->( $hours->[-1] ) . $on_day;
    }

    if ( @{$hours} > 2 && _even_step( $hours, 24 ) ) {
        my $step = _even_step( $hours, 24 );
        my $when = $at_minute == 0
          ? 'on the hour'
          : "at $at_minute " . ( $at_minute == 1 ? 'minute' : 'minutes' ) . ' past';
        return "Every $step hours, $when$on_day";
    }

    # A LIST of hours, which is how twice a day is written - and how an uneven
    # step is written too, since "At 00:00, 05:00, 10:00, 15:00 and 20:00" is
    # EXACTLY right where "every 5 hours" would not be. That is the distinction
    # this sub cares about: not whether a schedule is simple, but whether the
    # sentence is true.
    #
    # CAPPED AT SIX, because past that it stops being a sentence and becomes a
    # data dump - eleven times in a row is harder to check at a glance than the
    # cron it replaced, and the contract has always been that anything this sub
    # cannot say WELL it returns unchanged.
    if ( @{$hours} > 1 ) {
        return 'At ' . _and_list( map { $clock->($_) } @{$hours} ) . $on_day
          if @{$hours} <= 6;

        # TOO LONG TO READ, SO IT IS MARKED RATHER THAN LEFT AS CRON. Eleven
        # times in a row is exact and unreadable; "About every 2 hours from
        # 00:23 to 20:23" is inexact only at the wrap, readable, and honest
        # because it says so. His answer to Q-119.
        my $step = _even_step( $hours, 24 );
        my $gap  = $step || ( $hours->[1] - $hours->[0] );
        return _about(
            "every $gap hours from "
              . $clock->( $hours->[0] ) . ' to ' . $clock->( $hours->[-1] ) . $on_day,
            'restarts each day' );
    }

    my $at = 'at ' . $clock->( $hours->[0] );

    # "Every Monday at 09:00" rather than "Every week, on Monday, at 09:00" - the
    # day is the subject, and the shorter form is what a person would say.
    if ( $on_day =~ s/\A every // ) {
        return "Every $on_day $at";
    }
    return "At " . $clock->( $hours->[0] ) . $on_day if $on_day;
    return "Every day $at";
}

sub _cron_minute_matches {
    my ( $sets, $epoch ) = @_;
    my ( $minute, $hour, $day, $month, $weekday ) = ( localtime $epoch )[ 1, 2, 3, 4, 6 ];
    $month += 1;

    return 0 if !$sets->[0]{$minute};
    return 0 if !$sets->[1]{$hour};
    return 0 if !$sets->[2]{$day};
    return 0 if !$sets->[3]{$month};

    # Sunday is both 0 and 7 in cron, and a schedule naming either means the
    # same day.
    return 0 if !$sets->[4]{$weekday} && !( $weekday == 0 && $sets->[4]{7} );
    return 1;
}

1;

__END__

=head1 NAME

Tira::Job::Schedule - cron schedule parsing, validation and wording

=head1 DESCRIPTION

Five schedule functions (plus the wording cluster below) lifted out of
C<Tira::Job>: C<_cron_field_values> and
C<_cron_parse> (parse and validate a crontab expression, dying with the
field and range that was wrong), C<schedule_refusal> (the same validator,
as a string a caller can show without catching an exception),
C<job_schedule_words> (a schedule as a phrase - "Every 30 minutes" - with
its own helper cluster: C<_ordinal>, C<_weekday_phrase>,
C<_monthday_phrase>, C<_about>, C<_even_step>, C<_and_list>, and the
C<@DAY>/C<@MONTH>/C<%DAY_NAME>/C<%MONTH_NAME> word tables), and
C<_cron_minute_matches> (whether one minute matches a parsed schedule, the
inner test C<job_is_due>'s gap scan calls once per candidate minute).

Reached through a forward of the same name in C<Tira::Job>, required at
the point of use. Not renamed, so every existing caller -
C<Tira::CLI::Browser::Jobs> and C<Tira::CLI::Job>, which already reach
C<schedule_refusal> and C<job_schedule_words> by their fully-qualified
C<Tira::Job::> name - needed no change at all.

=head1 SEE ALSO

L<Tira::Job>

=cut
