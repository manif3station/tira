package Tira::Job;

# Repeated jobs: a schedule the board owns, rather than a loop a session owns.
#
# WHY THIS EXISTS, and it is worth keeping because the failure was quiet.
# Three standing hunts - hourly bugs, two-hourly improvements, three-hourly
# doc-gaps - ran as in-session monitors. On 2026-09-02 all three had been
# dead for hours and nobody noticed, because a loop that has stopped and a
# loop with nothing to report produce identical output: none. Michael asked
# "The bug hunting and improvement hunting and doc-gap hunting loops all
# stoped?" and the answer was yes. The agent had no way to tell.
#
# A schedule on the board is visible, survives any session, and is policed
# like every other record. EPC-014, TKT-836.
#
# THE CENTRAL RULE IS THE REFUSAL. A malformed schedule is rejected when it
# is written, naming what was wrong, and nothing is stored. Storing it would
# rebuild the same ambiguity one layer down: a job that never fires because
# its cron is nonsense is indistinguishable from a job with nothing to
# announce, and the board would be claiming a schedule it does not have.
#
# TWO OUTPUT MODES, his msg 6487: "either set to run a command and output to
# the police bridge or direct message to the bridge". A job carries a command
# OR a message, never both and never neither, and which one it is is stored
# explicitly rather than inferred from which field is populated - a caller
# reading the record should not have to guess.
#
# TWO SCHEDULE KINDS, same message: a crontab string, or the literal
# 'monitor' for a long-running poller. schedule_kind records which, so no
# caller re-parses the schedule to find out.
#
# IN ITS OWN MODULE FROM THE START. TKT-746 is decomposing lib/Tira.pm - three
# concerns lifted so far, 15,264 lines down to 14,177 - so new code goes
# beside those rather than into the file they are being pulled out of. Tira
# keeps thin forwarders that require this lazily, the same shape Tira::Toon,
# Tira::Tasklist and Tira::Render already use.

use strict;
use warnings;

use File::Spec;
use POSIX ();

sub _job_path {
    my ( $self, $root ) = @_;
    return File::Spec->catfile( $root, '.tira', 'jobs.json' );
}

sub _job_read {
    my ( $self, $root ) = @_;
    my $path = _job_path( $self, $root );
    return [] if !-f $path;
    open my $fh, '<:raw', $path or die "Cannot read jobs '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close jobs '$path': $!\n";
    return Tira::json_object()->utf8->decode($content);
}

# The five cron fields, each with the range it is allowed to name. Held as
# data rather than as five hand-written checks so a refusal can say which
# field was wrong and what its range is, which is the difference between "bad
# schedule" and something a person can act on.
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

sub _job_next_id {
    my ( $root, $jobs ) = @_;
    my $max = 0;
    for my $job ( @{$jobs} ) {
        my ($number) = ( $job->{id} // '' ) =~ /(\d+)\z/;
        $max = $number if defined $number && $number > $max;
    }
    return sprintf( 'JOB-%03d', $max + 1 );
}

# Validates the schedule and the mode together, because they are the two
# things a caller can get wrong and both refusals want to happen before
# anything is written.
sub _job_fields {
    my (%args) = @_;

    my $schedule = $args{schedule};
    die "A schedule is required - a cron expression, or 'monitor'\n"
      if !defined $schedule || $schedule eq '';

    my $kind = $schedule eq 'monitor' ? 'monitor' : 'cron';
    _cron_parse($schedule) if $kind eq 'cron';

    my $has_command = defined $args{command} && $args{command} ne '';
    my $has_message = defined $args{message} && $args{message} ne '';
    die "A job needs either a command to run or a message to announce\n"
      if !$has_command && !$has_message;
    die "A job takes either a command or a message, not both - "
      . "a record carrying both cannot say which the bridge should get\n"
      if $has_command && $has_message;

    return (
        schedule      => $schedule,
        schedule_kind => $kind,
        mode          => $has_command ? 'command' : 'message',
        command       => $has_command ? $args{command} : undef,
        message       => $has_message ? $args{message} : undef,
    );
}

sub job_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %fields = _job_fields(%args);
    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $now  = $self->{clock}->();
        my $job  = {
            id => _job_next_id( $root, $jobs ), %fields,
            enabled => 1, last_run => undef,
            created_at => $now, last_updated => $now,
        };
        push @{$jobs}, $job;
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

sub job_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return _job_read( $self, $root );
}

sub _job_find {
    my ( $jobs, $id ) = @_;
    my ($job) = grep { $_->{id} eq ( $id // '' ) } @{$jobs};
    die "No job '$id'\n" if !$job;
    return $job;
}

sub job_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );

        # Validated against the job as it WOULD be, not against the arguments
        # alone - otherwise changing only the schedule of a command-mode job
        # would be refused for having no command, and changing only the
        # message would silently leave a stale command behind it.
        my %merged = (
            schedule => $args{schedule} // $job->{schedule},
            ( defined $args{command} ? ( command => $args{command} )
              : defined $args{message} ? ( message => $args{message} )
              : $job->{mode} eq 'command' ? ( command => $job->{command} )
              : ( message => $job->{message} ) ),
        );
        my %fields = _job_fields(%merged);

        %{$job} = ( %{$job}, %fields );
        $job->{enabled} = $args{enabled} ? 1 : 0 if defined $args{enabled};
        $job->{last_updated} = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

sub job_delete {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';
    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );
        $self->_write_json( _job_path( $self, $root ),
            [ grep { $_->{id} ne $args{id} } @{$jobs} ] );
        return $job;
    } );
}

# Is this job due at this instant? The instant is ALWAYS an argument - never
# the wall clock - so an assertion is about the schedule rather than about
# when the suite happened to run, which is the same reason every other dated
# behaviour in this engine takes an injected clock.
sub job_is_due {
    my ( $self, $job, $when ) = @_;
    return 0 if !$job;
    return 0 if exists $job->{enabled} && !$job->{enabled};

    # A monitor runs continuously rather than on a tick, so it is never
    # "due" - asking is a category error, and answering yes would make the
    # police start it once a minute.
    my $schedule = $job->{schedule} // '';
    return 0 if $schedule eq 'monitor';

    my $sets = eval { _cron_parse($schedule) } or return 0;

    my ( $year, $month, $day, $hour, $minute ) =
      $when =~ /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/
      or die "Cannot read the time '$when'\n";

    my $weekday = ( POSIX::mktime( 0, 0, 12, $day, $month - 1, $year - 1900 ) )
      ? ( localtime POSIX::mktime( 0, 0, 12, $day, $month - 1, $year - 1900 ) )[6]
      : 0;

    return 0 if !$sets->[0]{ $minute + 0 };
    return 0 if !$sets->[1]{ $hour + 0 };
    return 0 if !$sets->[2]{ $day + 0 };
    return 0 if !$sets->[3]{ $month + 0 };

    # Sunday is both 0 and 7 in cron, and a schedule naming either means the
    # same day.
    return 0 if !$sets->[4]{$weekday} && !( $weekday == 0 && $sets->[4]{7} );
    return 1;
}

1;

__END__

=head1 NAME

Tira::Job - repeated jobs, a schedule the board owns

=head1 DESCRIPTION

A repeated job carries a schedule - a crontab expression or the literal
C<monitor> - and either a command to run or a message to announce, and the
police acts on it when it comes due. EPC-014.

It exists because a schedule that lived in a session died with it: three
standing hunts stopped and went unnoticed for hours, since a loop that has
stopped and a loop with nothing to report look identical from outside. A
schedule on the board is visible, durable and policeable.

=head1 THE REFUSAL IS THE POINT

A malformed schedule is rejected by C<job_add> and C<job_update> when it is
written, naming the field that was wrong and the range it takes, and nothing
is stored. This is deliberate rather than defensive: a job whose cron is
nonsense would never fire, and a job that never fires is indistinguishable
from a job with nothing to say - which is precisely the ambiguity this
feature was built to remove. Storing it would rebuild that ambiguity one
layer down.

=head1 A JOB IS ONE MODE OR THE OTHER

Either a command, whose output the police sends to the bridge, or a message
it announces directly. Never both - a record carrying both cannot say which
the bridge should get - and never neither. C<mode> records which, so a reader
never has to infer it from which field happens to be populated.

=head1 CALL IT THROUGH TIRA

C<Tira> is the public entry point and keeps a forwarder for each verb here,
requiring this module at the call site. Every sub takes C<$self> - a blessed
C<Tira> - as its first argument.

=cut
