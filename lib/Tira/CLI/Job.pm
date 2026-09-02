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

sub dispatch {
    my ( $tira, $args, $option, $command ) = @_;

    return $tira->job_list( %{$args} ) if $command eq 'job.list';

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

    return $tira->job_delete( %{$args} );
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

=cut
