package Tira::CLI::Wizard;

# tira.onboard's guided questions, and the line editor that asks them.
#
# Only one command in the whole CLI ever prompts - project.new stays purely
# argument-driven so that no script or agent invoking it can be left waiting on
# input - and this is that command's 353 lines. Tira::CLI loads it when onboard
# actually runs. TKT-607.
#
# WHAT STAYED IN Tira::CLI: _expand_home, which the option handling in run()
# uses for every command and not only for the wizard's answers, and
# _agent_available, which the doctor asks too. Both are called from here by
# their full names, which says at the call site that they live in the index.

use strict;
use warnings;

use File::Spec ();
use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

sub _project_wizard {
    my ( $tira, $in, $option ) = @_;
    print "Tira project setup — answer the questions, or press Ctrl-D to abort.\n\n";
    my %answers;

    # The directory comes first because everything else can be pre-filled from
    # the project already living there. Asking it second would mean offering
    # one project's answers while writing to another.
    # Asking first is only useful if it can answer itself: offer whatever
    # project is already resolvable rather than making somebody type the path
    # before any of the pre-filling can help.
    my $suggested = $option->{dir}
      // eval {
        $tira->discover_project( defined $option->{project} ? ( project => $option->{project} ) : () );
      }
      // '.';
    my ( $stored, $default ) = _wizard_all_defaults( $tira, $suggested, $option );
    my $dir = _ask( $in, 'Project directory', $suggested );
    return ( undef, 2 ) if !defined $dir;
    $answers{dir} = Tira::CLI::_expand_home($dir);
    ( $stored, $default ) = _wizard_all_defaults( $tira, $answers{dir}, $option )
      if $answers{dir} ne $suggested;
    print "\nEditing the project already at that directory — press enter to keep each answer.\n\n"
      if %{$stored};

    while (1) {
        my $name = _ask( $in, 'Project name', $default->{name} );
        return ( undef, 2 ) if !defined $name;
        if ( $name eq '' ) {
            print "  A project needs a name.\n";
            next;
        }
        $answers{name} = $name;
        last;
    }

    my $members = _ask( $in, 'People, separated by commas',
        $default->{members} ? join( ', ', @{ $default->{members} } ) : '' );
    return ( undef, 2 ) if !defined $members;
    # Enter means "none yet", not "a person with an empty name" — the
    # empty-string guard exists for an explicit --members "" on a command line.
    $answers{members} = [$members] if $members ne '';

    my %default_prefix = ( sow => 'SOW', epic => 'EPC', ticket => 'TKT' );
    for my $type (qw(sow epic ticket)) {
        while (1) {
            my $prefix = _ask( $in, "Reference prefix for \u$type records",
                $default->{"${type}_prefix"} // $default_prefix{$type} );
            return ( undef, 2 ) if !defined $prefix;
            if ( $prefix !~ /\A[A-Z][A-Z0-9-]{0,31}\z/ ) {
                print "  Invalid prefix: it must start with a capital letter and use capitals, digits, and hyphens.\n";
                next;
            }
            $answers{"${type}_prefix"} = $prefix;
            last;
        }
    }

    my $shared = _ask_yes( $in, 'Do all three boards use the same columns?',
        $default->{columns_shared} // 1 );
    return ( undef, 2 ) if !defined $shared;
    if ($shared) {
        my $columns = _ask( $in, 'Columns, in order, separated by commas',
            $default->{columns} ? join( ', ', @{ $default->{columns} } ) : '' );
        return ( undef, 2 ) if !defined $columns;
        $answers{columns} = [$columns] if $columns ne '';
    }
    else {
        for my $type (qw(sow epic ticket)) {
            my $columns = _ask( $in, "Columns for the \u$type board",
                $default->{"${type}_columns"} ? join( ', ', @{ $default->{"${type}_columns"} } ) : '' );
            return ( undef, 2 ) if !defined $columns;
            $answers{"${type}_columns"} = [$columns] if $columns ne '';
        }
    }

    # Asked whether or not anything can send reminders: it decides what the
    # staleness report says, which is useful with no automation at all.
    while (1) {
        my $stuck = _ask( $in, 'Minutes before a card counts as stuck (blank for never)',
            $default->{notify_after} );
        return ( undef, 2 ) if !defined $stuck;
        last if $stuck eq '';
        if ( $stuck !~ /\A[0-9]+(?:\.[0-9]+)?\z/ || $stuck <= 0 ) {
            print "  That must be a positive number of minutes.\n";
            next;
        }
        $answers{notify_after} = $stuck;
        last;
    }

    # With no coding agent installed there is nothing to configure and nothing
    # that could deliver, so none of this is asked.
    if ( Tira::CLI::_agent_available('claude') ) {
        # TKT-459 already made project_update accept any registered, active
        # person as the agent - not only literally 'claude' - so a project
        # whose agent is genuinely someone else (its own example: 'zenbot')
        # can declare it here too. TKT-560: this question used to refuse
        # anything but 'claude', stale since that engine change shipped.
        my $agent = _ask( $in, 'Which coding agent should be reminded', $default->{agent} // 'claude' );
        return ( undef, 2 ) if !defined $agent;
        $answers{agent} = $agent if $agent ne '';
        while (1) {
            my $session = _ask( $in, 'Session id of the agent to remind', $default->{session} );
            return ( undef, 2 ) if !defined $session;
            last if $session eq '';
            if ( $session !~ /\A[A-Za-z0-9_-]{1,128}\z/ ) {
                print "  A session id is letters, digits, hyphens and underscores.\n";
                next;
            }
            $answers{session} = $session;
            last;
        }
        while (1) {
            my $collector = _ask( $in, 'Name for this project reminder job',
                $default->{collector} // Tira::_column_slug( $answers{name} ) );
            return ( undef, 2 ) if !defined $collector;
            last if $collector eq '';
            if ( $collector !~ /\A[a-z][a-z0-9-]{0,63}\z/ ) {
                print "  That must be lowercase letters, digits and hyphens.\n";
                next;
            }
            $answers{collector} = $collector;
            last;
        }
    }

    # One number of minutes, not two. The owner read the second as a repeat of
    # the first, and he was right to: there is no point looking more often than
    # the shortest window that could make anything stale. An explicit
    # --heartbeat still wins for anyone who wants to tune it.
    $answers{heartbeat} = $option->{heartbeat} // $answers{notify_after}
      if defined $answers{session}
      && defined( $option->{heartbeat} // $answers{notify_after} );

    # Which kind of project this is, asked rather than assumed. The questions
    # are the engine's, so what onboarding asks can be read by a test instead
    # of inferred from a sequence of prints. Left unanswered it stays unset,
    # and an unset project behaves exactly as every project does today.
    for my $question ( @{ $tira->onboarding_questions } ) {
        print "\n$question->{why}\n";
        while (1) {
            my $answer = _ask( $in, $question->{text}, $stored->{ $question->{id} } );
            return ( undef, 2 ) if !defined $answer;
            last if $answer eq '';
            if ( !grep { $_ eq $answer } @{ $question->{options} } ) {
                print '  Answer with ' . join( ' or ', @{ $question->{options} } ) . ".\n";
                next;
            }
            $answers{ $question->{id} } = $answer;
            last;
        }
    }

    print "\nAbout to create:\n";
    print "  name       $answers{name}\n";
    print "  directory  $answers{dir}\n";
    print "  people     " . ( join( ', ', @{ $answers{members} // [] } ) || '(none)' ) . "\n";
    print "  prefixes   sow $answers{sow_prefix}, epic $answers{epic_prefix}, ticket $answers{ticket_prefix}\n";
    for my $key ( grep { /_columns\z|\Acolumns\z/ } sort keys %answers ) {
        print "  $key " . join( ', ', @{ $answers{$key} } ) . "\n";
    }
    for my $key (qw(mode notify_after agent session collector heartbeat)) {
        print "  $key " . ( $answers{$key} // '(none)' ) . "\n" if exists $answers{$key};
    }
    print "\n";
    my $confirmed = _ask_yes( $in, 'Create this project?', 1 );
    return ( undef, 2 ) if !defined $confirmed;
    return ( undef, 1 ) if !$confirmed;
    return ( \%answers, 0 );
}
# Everything an existing project already knows, so re-running onboarding is a
# matter of pressing enter rather than typing it all again.
sub _wizard_defaults {
    my ( $tira, $dir ) = @_;
    return {} if !defined $dir || $dir eq '';
    my $project = eval { $tira->project_show( project => $dir ) } or return {};
    my %defaults = ( name => $project->{name} );
    my @people = map { $_->{id} } @{ $project->{people} // [] };
    $defaults{members} = [ join ', ', @people ] if @people;
    $defaults{$_} = $project->{$_}
      for grep { defined $project->{$_} } qw(collector agent session heartbeat notify_after);
    my $mode = eval { $tira->project_mode( project => $dir ) };
    $defaults{mode} = $mode if defined $mode;
    my %columns;
    for my $type (qw(sow epic ticket)) {
        my $refs = eval { $tira->board_refs( project => $dir, type => $type ) };
        $defaults{"${type}_prefix"} = $refs->{prefix} if $refs;
        my $list = eval { $tira->column_list( project => $dir, type => $type ) } or next;
        $columns{$type} = join ', ', map { $_->{label} // $_->{name} } @{$list};
        $defaults{"${type}_columns"} = [ $columns{$type} ];
    }
    my @distinct = keys %{ { map { $_ => 1 } values %columns } };
    $defaults{columns} = [ $distinct[0] ] if @distinct == 1;
    $defaults{columns_shared} = ( @distinct == 1 ? 1 : 0 ) if %columns;
    return \%defaults;
}
# Command-line flags win over what the project already stores, but only over
# the project they were given for: naming a different one rebuilds the defaults
# from scratch rather than merging, so a setting the new project does not have
# cannot be inherited from the old one by pressing enter.
sub _wizard_all_defaults {
    my ( $tira, $dir, $option ) = @_;
    my $stored = _wizard_defaults( $tira, $dir );
    my %default = ( %{$stored},
        map { $_ => $option->{$_} } grep { defined $option->{$_} } keys %{$option} );
    return ( $stored, \%default );
}
# Returns the finished line, or undef when the user abandons the prompt.
sub _edit_line {
    my ( $in, $prompt, $restore ) = @_;
    my ( $buffer, $cursor ) = ( '', 0 );
    _redraw( $prompt, $buffer, $cursor );
    while (1) {
        my $char = getc($in);
        if ( !defined $char || $char eq "\x04" || $char eq "\x03" ) {
            $restore->();
            print "\n";
            return undef;
        }
        if ( $char eq "\r" || $char eq "\n" ) {
            $restore->();
            print "\n";
            return $buffer;
        }
        if ( $char eq "\x01" ) { $cursor = 0 }                        # Ctrl-A
        elsif ( $char eq "\x05" ) { $cursor = length $buffer }        # Ctrl-E
        elsif ( $char eq "\x15" ) { $buffer = ''; $cursor = 0 }       # Ctrl-U
        elsif ( $char eq "\x0b" ) { substr $buffer, $cursor, length($buffer) - $cursor, '' }  # Ctrl-K
        elsif ( $char eq "\x7f" || $char eq "\x08" ) {
            if ( $cursor > 0 ) { substr $buffer, --$cursor, 1, '' }
        }
        elsif ( $char eq "\e" ) {
            my $bracket = getc($in);
            my $code = defined $bracket && $bracket eq '[' ? getc($in) : undef;
            if ( defined $code ) {
                if    ( $code eq 'D' ) { $cursor-- if $cursor > 0 }
                elsif ( $code eq 'C' ) { $cursor++ if $cursor < length $buffer }
                elsif ( $code eq 'H' ) { $cursor = 0 }
                elsif ( $code eq 'F' ) { $cursor = length $buffer }
            }
        }
        elsif ( $char =~ /\A[[:print:]]\z/ ) {
            substr $buffer, $cursor, 0, $char;
            $cursor++;
        }
        _redraw( $prompt, $buffer, $cursor );
    }
}
sub _ask {
    my ( $in, $question, $default ) = @_;
    my $shown = defined $default && $default ne '' ? " [$default]" : '';
    my $prompt = "$question$shown: ";
    my $answer;
    if ( my $restore = _raw_mode($in) ) {
        $answer = _edit_line( $in, $prompt, $restore );
    }
    else {
        print $prompt;
        $answer = <$in>;
    }
    return undef if !defined $answer;
    chomp $answer;
    $answer =~ s/\A\s+|\s+\z//g;
    return length $answer ? $answer : ( defined $default ? $default : '' );
}
sub _ask_yes {
    my ( $in, $question, $default ) = @_;
    while (1) {
        my $answer = _ask( $in, "$question [" . ( $default ? 'Y/n' : 'y/N' ) . ']', '' );
        return undef if !defined $answer;
        return $default if $answer eq '';
        return 1 if $answer =~ /\Ay(?:es)?\z/i;
        return 0 if $answer =~ /\An(?:o)?\z/i;
        print "  Please answer yes or no.\n";
    }
}
sub _redraw {
    my ( $prompt, $buffer, $cursor ) = @_;
    my $column = length($prompt) + $cursor + 1;
    print "\r\e[2K$prompt$buffer\r\e[${column}G";
    return;
}
# Line editing without a dependency: Term::ReadLine's editing implementations
# are not installed anywhere this runs, so relying on one would silently give
# the user nothing. POSIX termios is core, so the editor is written directly
# against it and degrades to a plain read whenever input is not a terminal.
sub _raw_mode {
    my ($fh) = @_;
    my $fd = fileno($fh);
    return undef if !defined $fd || $fd < 0 || !-t $fh;
    require POSIX;
    my $saved = POSIX::Termios->new;
    return undef if !eval { $saved->getattr($fd) };
    my $raw = POSIX::Termios->new;
    $raw->getattr($fd);
    $raw->setlflag( ( $raw->getlflag // 0 ) & ~( POSIX::ICANON() | POSIX::ECHO() ) );
    $raw->setcc( POSIX::VMIN(),  1 );
    $raw->setcc( POSIX::VTIME(), 0 );
    $raw->setattr( $fd, POSIX::TCSANOW() );
    return sub { $saved->setattr( $fd, POSIX::TCSANOW() ); return };
}
# project.new and onboard, lifted out of Tira::CLI::_invoke. They belong here
# rather than in the index because onboard IS this module's command - the
# wizard was already here and the block that calls it was still in the
# dispatcher, which is the split arriving halfway. TKT-607.

sub project_new_or_onboard {
    my ( $tira, $args, $option, $command ) = @_;
    my %args = %{$args};

    # Before anything is written, not after. project_mode is called below
    # once the project exists, and it refuses anything but its two values
    # - which used to mean an invalid --mode produced a failed command AND
    # a fully created project, with nothing to roll back and nothing
    # saying so. "It failed" and "it half worked" are different facts, and
    # only one of them tells the reader to go and look at the directory;
    # the next attempt then meets a project that should not be there.
    #
    # The wizard's own loop already re-asks against these same options, so
    # ordinary interactive use never got here. What did was the --mode
    # flag on project.new, and the browser onboarding form, whose mode
    # field renders its options as a hint and validates nothing before
    # calling back into this dispatch. Checking here covers both, because
    # both arrive here.
    #
    # The options come from onboarding_questions() rather than a literal
    # pair, so a third mode cannot be added there and silently refused
    # here. TKT-562.
    if ( defined $option->{mode} ) {
        my ($question) = grep { $_->{id} eq 'mode' } @{ $tira->onboarding_questions };
        my @allowed = @{ $question->{options} // [] };
        die "--mode must be one of: " . join( ', ', @allowed ) . "\n"
          if @allowed && !grep { $_ eq $option->{mode} } @allowed;
    }

    my $summary = $tira->project_new(
        name => $option->{name}, dir => $option->{dir} // '.',
        members => $option->{members}, columns => $option->{columns},
        map( { ( "${_}_columns" => $option->{"${_}_columns"} ) }
            grep { defined $option->{"${_}_columns"} } qw(sow epic ticket) ),
        ( defined $option->{digits} ? ( digits => $option->{digits} ) : () ),
        map( { ( "${_}_prefix" => $option->{"${_}_prefix"} ) }
            grep { defined $option->{"${_}_prefix"} } qw(sow epic ticket) ),
        map( { ( $_ => $option->{$_} ) }
            grep { defined $option->{$_} } qw(notify_after collector agent session heartbeat) ),
        ( $option->{nested} ? ( nested => 1 ) : () ),
    );

    # Written after the project exists, because it is a fact about the
    # project rather than one of the things that makes one. Unanswered
    # leaves it unset, and unset is every board that exists today.
    $tira->project_mode( project => $option->{dir} // '.', mode => $option->{mode} )
      if defined $option->{mode};

    # Collecting the settings and leaving the job unregistered
    # looked like it had worked. Onboarding registers it, and reports the
    # name it will really answer to, which is not the name that was typed.
    if ( $command eq 'onboard' && defined $summary->{project}{heartbeat} ) {
        # Project_show carries no root, so use the directory that was created.
        my $job = eval { $tira->collector_install( project => $option->{dir} // '.' ) };
        if ($job) {
            print "\nRegistered the reminder job as '$job->{name}'.\n"
              . "Start it with: dashboard collector start $job->{name}\n\n";
            $summary->{collector} = $job;
        }
    }
    return $summary;
}

1;

__END__

=head1 NAME

Tira::CLI::Wizard - the onboarding questions, and the line editor that asks them

=head1 DESCRIPTION

C<_project_wizard> is the body behind C<tira.onboard>: the guided questions, the
defaults offered for each, and C<_ask>, C<_ask_yes>, C<_edit_line>, C<_redraw>
and C<_raw_mode> - the small line editor that lets an answer be corrected
before it is given.

C<tira.onboard> is the only command in the CLI that prompts. C<project.new> is
deliberately argument-driven so that no script or agent invoking it can be left
waiting on input. So this module is loaded by exactly one command, and
C<Tira::CLI> requires it at that point rather than compiling it for every
invocation.

=head2 What stayed in Tira::CLI

C<_expand_home> is used by the option handling in C<run> for every command, not
only for the wizard's answers. C<_agent_available> is asked by the doctor too.
Both are called from here by their full names.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it.

It calls into no sibling module. This paragraph said otherwise until 4.74 -
one note written once and pasted into all eight, describing a chain three of
them do not sit in.

=head1 SEE ALSO

L<Tira::CLI>

=cut
