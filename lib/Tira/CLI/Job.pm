package Tira::CLI::Job;

# The four repeated-job verbs, kept out of Tira::CLI for the reason every
# other concern module here exists: the index says a thing exists and where,
# and does not hold it. Adding these inline took lib/Tira/CLI.pm to 3,028
# lines and t/430 refused it at 3,000 - the guard doing its job rather than
# an obstacle to route around by raising the number.
#
# THE REFUSAL FOR A MALFORMED SCHEDULE IS NOT HERE. It comes from
# Tira::Job::_cron_parse, and this module only surfaces it. Two validators
# for one format is how the engine and the browser ended up disagreeing
# about attachment content types (TKT-713), and TKT-843 will meet the same
# temptation in JavaScript. EPC-014, TKT-837.

use strict;
use warnings;

# --command is shared with required-action proofs, which take it repeatably as
# 'command=s@'. Declaring a second 'command=s' for jobs is what t/450 refuses:
# Getopt::Long prints "Duplicate specification" to STDERR on every invocation,
# and TKT-576 records the last time that shipped. So the array form is read
# here instead. Two of them is refused rather than silently taking one - a job
# runs exactly one command, and quietly dropping the other is the same fault
# the whole option guard above exists to prevent.
sub _command_of {
    my ($option) = @_;
    my $given = $option->{command};
    return undef if !defined $given;
    return $given if !ref $given;
    return undef if !@{$given};
    die "A job runs one command - give --command once, not " . scalar( @{$given} ) . " times\n"
      if @{$given} > 1;
    return $given->[0];
}

# Anything that is not recognisably true was previously false, so
# --enabled banana quietly disabled a job and said nothing. That is the "a
# wrong flag that parses looks accepted" fault the option guard two files away
# exists to prevent, and this board refuses the same shape everywhere else: a
# checklist status of 'todo' is refused rather than guessed, and a malformed
# cron is refused rather than treated as never-due. Found by a documentation
# review before it shipped, which is why the accepted words are now a list
# rather than a regex with an implicit else.
my %ENABLED = (
    ( map { $_ => 1 } qw(1 yes true on) ),
    ( map { $_ => 0 } qw(0 no false off) ),
);

sub _enabled_of {
    my ($given) = @_;
    my $value = $ENABLED{ lc $given };
    die "Unknown --enabled value '$given' - the words that work are "
      . join( ', ', sort keys %ENABLED ) . "\n"
      if !defined $value;
    return $value;
}

# Start a monitor, and record what it started as.
#
# WHY open3 AND NOT fork/setsid/exec. A hand-rolled detach puts the child's
# redirections and its exec in a branch that only ever runs in the child
# process, where Devel::Cover cannot follow it - so the mandatory 100%
# statement gate would be met by writing the fork out again in a shape nobody
# runs, or by lowering the gate. open3 is already this codebase's spawn (see
# run_due_job) and does the forking in code that is not ours to cover. The
# monitor is reparented when this process exits, which is what "keeps running"
# needs; it is not setsid'd, and a terminal hangup would still reach it. That
# is a real difference from a daemon and is written here rather than implied.
#
# OUTPUT GOES TO A FILE, not to a pipe. A pipe nobody drains fills at about
# 64KB and blocks the monitor forever - the deadlock TKT-841 was reviewed for,
# rebuilt in the one place where there is no reader at all.
sub _start_monitor {
    my ( $tira, $args, $job ) = @_;

    die "Job $job->{id} is a cron job - it runs when due, and is not started\n"
      if ( $job->{schedule_kind} // '' ) ne 'monitor';
    die "Job $job->{id} is disabled - enable it before starting it\n"
      if !$job->{enabled};

    my @command = split ' ', ( $job->{command} // '' );
    die "Job $job->{id} has no command to run\n" if !@command;

    my $log = $tira->job_log_path( %{$args}, id => $job->{id} );
    open my $handle, '>>', $log
      or die "Cannot open the monitor's log at '$log': $!\n";

    require IPC::Open3;
    my $to = '>&' . fileno($handle);
    my $pid = eval { IPC::Open3::open3( my $in, $to, $to, @command ) };
    if ( !$pid ) {
        my $why = $@ || 'could not be started';
        $why =~ s/\s+\z//;
        close $handle;
        die "$command[0]: $why\n";
    }
    close $handle;

    # SPAWNING AND RECORDING MUST NOT COME APART. The process exists the
    # instant open3 returns; the board only learns its pid on the next line.
    # If that write fails - a held lock, a full disk - the old code left a
    # RUNNING monitor that the board had no pid for, which monitor-dead then
    # reported dead on every pass while job.start, run again, started a second
    # copy. A live monitor reported dead is the noise that gets this rule
    # ignored, and a silent duplicate is worse.
    #
    # So the child is killed if it cannot be recorded, and the failure is
    # raised. Leaving nothing running is the state the caller can retry from.
    my $started = eval { $tira->job_started( %{$args}, id => $job->{id}, pid => $pid ) };
    if ( !$started ) {
        my $why = $@ || 'the start could not be recorded';
        $why =~ s/\s+\z//;
        kill 'TERM', $pid;
        waitpid $pid, 0;
        die "Started $job->{id} as pid $pid but could not record it, so it "
          . "was stopped again rather than left running unrecorded: $why\n";
    }
    return $started;
}

sub dispatch {
    my ( $tira, $args, $option, $command ) = @_;

    return $tira->job_list( %{$args} ) if $command eq 'job.list';

    if ( $command eq 'job.start' ) {
        my ($job) = grep { $_->{id} eq ( $args->{id} // '' ) }
          @{ $tira->job_list( %{$args} ) };
        die "No job $args->{id} on this board\n" if !$job;
        return _start_monitor( $tira, $args, $job );
    }

    my $job_command = _command_of($option);

    return $tira->job_add(
        %{$args},
        schedule => $option->{schedule},
        ( defined $job_command ? ( command => $job_command ) : () ),
        ( defined $option->{message} ? ( message => $option->{message} ) : () ),
    ) if $command eq 'job.add';

    return $tira->job_update(
        %{$args},
        ( defined $option->{schedule} ? ( schedule => $option->{schedule} ) : () ),
        ( defined $job_command        ? ( command  => $job_command )        : () ),
        ( defined $option->{message}  ? ( message  => $option->{message} )  : () ),
        ( defined $option->{enabled} ? ( enabled => _enabled_of( $option->{enabled} ) ) : () ),
    ) if $command eq 'job.update';

    return $tira->job_delete( %{$args} ) if $command eq 'job.delete';

    # NOT a fallthrough. This used to be a bare `return $tira->job_delete(...)`
    # with no condition, safe only because the caller admits exactly four verbs
    # and the other three return above it - so the safety lived in a regex in
    # another file. TKT-841 and TKT-842 are both queued to add behaviour here,
    # and adding a verb to that regex without adding a branch here would have
    # DELETED the job instead of running it. A destructive default is the wrong
    # way round: the unknown case should refuse, and deleting should need to be
    # asked for by name.
    die "Tira::CLI::Job cannot dispatch '$command'\n";
}

1;

__END__

=head1 NAME

Tira::CLI::Job - the command bodies for repeated jobs

=head1 DESCRIPTION

C<tira.job.add>, C<list>, C<update> and C<delete>, lifted out of
C<Tira::CLI> so the index stays an index. Required at the point one of those
verbs runs, so a command that is not about jobs never compiles it.

What makes a schedule valid is decided in L<Tira::Job>, not here. This
module passes the arguments through and lets the engine's refusal reach the
caller unchanged, so the command line and the stored record cannot disagree.

=head1 STARTING A MONITOR

C<tira.job.start> is here rather than in the engine because starting one
means spawning a process, and the engine is forbidden every shell-invoking
construct. It records the pid through C<Tira::Job::job_started>, which is
what makes a later death detectable at all - without it the C<monitor-dead>
rule would guard a state nothing on the board could produce, and every
enabled monitor would read as dead on every pass.

Two decisions here are worth keeping. The spawn is C<IPC::Open3>, not a
hand-rolled C<fork>/C<setsid>/C<exec>: the child half of a hand-rolled detach
runs where C<Devel::Cover> cannot follow it, so the mandatory 100% statement
gate could only be met by writing code nobody runs, or by lowering the gate.
The honest cost is that the monitor is reparented rather than session-led, so
a terminal hangup still reaches it.

And the output goes to a B<file>, not a pipe. A pipe with no reader fills at
around 64KB and blocks the writer forever - the deadlock TKT-841 was reviewed
for, which would be rebuilt here in the one place where there is no reader at
all. A monitor blocked on a full pipe is a stopped monitor that still looks
started, which is the failure this whole epic is about.

=cut
