package Tira::CLI::Usage;

# Everything that answers "what should I have typed" - the usage lines, the
# policy help, the unknown-option message and the edit distance behind its "did
# you mean".
#
# It is asked for by --help and by the error paths, which is a minority of
# invocations, and it was 143 lines in the file every command had to be read
# through - 136 of subs, and the rest the four lexicals below, which had to come
# with them because a file-scoped `my` cannot be reached across a package
# boundary. TKT-607.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec ();
use Tira;

# The four file-scoped lexicals these read came with them - %RECORD_USAGE,
# %NEEDS_TYPE, $SKILLS_TEXT and %SUPPLIED_BY. A `my` at file scope cannot
# be reached from another package at all, so this is not a preference -
# the module does not compile without them, which is how the extractor's
# blind spot was found: it detects the case and refuses when the variable
# is read on both sides, but had no branch for bringing one along.

# What each record verb takes, so asking a command how to use it does not
# answer about a different one.
#
# Every record command shared one line and the line named create, so
# tira.ticket.move --help said 'Usage: d2 tira.ticket.create --title
# TITLE'. 21 of the 24 record verbs answered about a command that was not the
# one asked about; the three that were right were the three creates. It adapted
# the board - tira.sow.list answered with tira.sow.create - which is why it read
# as considered rather than as a fallback, and why it stood. A wrong answer that
# looks specific is not questioned.
#
# The shapes are the ones verified against the running commands when the command
# reference was given its record section, rather than written from memory: that
# is how discard was found to take no reason. TKT-235.
my %RECORD_USAGE = (
    create  => '--title TEXT [record field arguments]',
    show    => '--ref REF [--fields LIST] [--brief|--full]',
    list    => '[--column SLUG] [--assignee ID] [--fields LIST] [--count]',
    update  => '--ref REF [record field arguments]',
    move    => '--ref REF --column SLUG [--author NAME]',
    clone   => '--ref REF --title TEXT',
    discard => '--ref REF',
    restore => '--ref REF [--column SLUG]',
    missing => '--ref REF',
);

# The commands that cannot work without a type. Their usage line named no
# option at all, so a reader who checked it before running anything was told
# the opposite of the truth: that the command took nothing. TKT-215.
my %NEEDS_TYPE = map { $_ => 1 }
  qw(board.refs board.show column.sync column.update);

# SKILLS.md carries a full usage line for every command it documents - the
# same catalogue docs-match-code already holds every shipped command to - and
# it says more than the bare "[options]" _usage() answered with on its own.
# Read once and cached, relative to this module's own file rather than to
# whichever cli/ script happens to be running, so the answer does not depend
# on how the command was reached. TKT-343.
my $SKILLS_TEXT;

# What supplies the thing a refusal says is missing.
#
# The engine raises these messages and has no notion of a command line, which
# is why they name a thing rather than a flag - "Record reference is required"
# from forty commands, and not one of them says --ref. Measured by running
# every entrypoint with no arguments: 83 refusals that name no option at all.
# The standard is this project's own, and the owner named it: "Policy rule
# card-sandbox-missing needs --enter" takes no guessing.
#
# So the translation lives here, at the boundary where flag names already live,
# and the engine keeps no table of them. Declared rather than derived, and held
# honest by a guard that runs every entrypoint: a message reworded out of this
# table stops naming its option, and the guard says so. TKT-268.
# Two shapes, because two things can be wrong. A thing that is missing is
# supplied by an option; a value that is wrong came in through one, and telling
# somebody to supply what they just supplied would be its own kind of useless.
my %SUPPLIED_BY = (
    'Record reference is required'         => [ 'ref',      'supply it with' ],
    'A card reference is required'         => [ 'ref',      'supply it with' ],
    'A question id is required'            => [ 'id',       'supply it with' ],
    'An attachment reference is required'  => [ 'ref',      'supply it with' ],
    'Record title is required'             => [ 'title',    'supply it with' ],
    'Project name is required'             => [ 'name',     'supply it with' ],
    'Project person is required'           => [ 'person',   'supply it with' ],
    'Person id is required'                => [ 'id',       'supply it with' ],
    'Password is required'                 => [ 'password', 'supply it with' ],
    'Import file is required'              => [ 'file',     'supply it with' ],
    'Replacement pattern is required'      => [ 'pattern',  'supply it with' ],
    'Link type names are required'         => [ 'outward',  'supply it with' ],
    'Checklist item is required'           => [ 'item',     'supply it with' ],
    'Checklist item or status is required' => [ 'item',     'supply it with' ],
    'A warning message is required'        => [ 'message',  'supply it with' ],
    'Gate annotation note is required'     => [ 'note',     'supply it with' ],
    'Evidence annotation note is required' => [ 'note',     'supply it with' ],
    'A question needs some text'           => [ 'text',     'supply it with' ],
    'An answer needs some text'            => [ 'text',     'supply it with' ],
    'How many seconds?'                    => [ 'seconds',  'supply it with' ],
    'A move needs to say who is making it' => [ 'author',   'supply it with' ],
    'A change needs to say who is making it' => [ 'author', 'supply it with' ],
    # Given rather than missing: the option carried a value the command will
    # not take, so it is named rather than asked for.
    'Invalid column name'                  => [ 'name',         'the option is' ],
    'Invalid attachment SHA'               => [ 'sha',          'the option is' ],
    'Invalid gate result'                  => [ 'result',       'the option is' ],
    'Unknown policy rule'                  => [ 'rule',         'the option is' ],
    "Policy '' not found"                  => [ 'id',           'the option is' ],
    'A column layout must be JSON'         => [ 'columns-json', 'the option is' ],
    'A parent is required'                 => [ 'parent', 'supply it with' ],  # hierarchy.link takes no --ref. TKT-689.
    'A child is required'                  => [ 'child',  'supply it with' ],
);

my %COMMAND_OVERRIDE = ( 'record.move' => { 'Invalid column name' => ' - the option is --column' } ); # TKT-689

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: d2 tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';

    if ( $NEEDS_TYPE{ $command // '' } ) {
        my $known = _skills_usage_line($command);
        return "Usage: d2 tira.$command $known\n" if defined $known;
        return "Usage: d2 tira.$command --type ticket|epic|sow [options] [-o toon|json|human]\n";
    }

    if ( defined $type ) {
        my ($verb) = ( $command // '' ) =~ /\.([a-z]+)\z/;

        # SKILLS.md documents a typed verb two ways - a concrete line per
        # type ("tira.ticket.create ...") or one generic line for all three
        # ("tira.<type>.list ...") - and %RECORD_USAGE has drifted from both
        # without anybody noticing, because this branch never checked either
        # one. Tried in that order, so a concrete line wins over the generic
        # placeholder if a command ever carries both. TKT-418.
        my $known = _skills_usage_line("$type.$verb") // _skills_usage_line("<type>.$verb");
        return "Usage: d2 tira.$type.$verb $known\n" if defined $known;

        my $takes = $RECORD_USAGE{ $verb // '' };
        return "Usage: d2 tira.$type.$verb $takes [-o toon|json|human]\n"
          if defined $takes;

        # A record verb this does not know is named rather than described,
        # which is still an answer about the command that was asked.
        return "Usage: d2 tira.$type." . ( $verb // 'command' )
          . " [options] [-o toon|json|human]\n";
    }

    my $known = _skills_usage_line($command);
    return "Usage: d2 tira.$command $known\n" if defined $known;

    # TKT-1005. The internal dispatch name for every sow/epic/ticket verb is
    # literally 'record.$verb' before a caller's own $type is known - this
    # branch is reached with exactly that shape when a caller asks about the
    # dispatch name rather than the typed command a user actually runs. SKILLS.md
    # cannot answer it: 'tira.record.clone' was never a command a user could
    # type (no 'record' symlink directory exists, only ticket/epic/sow), so
    # documenting it there taught the opposite of the truth. %RECORD_USAGE
    # already answers the typed branch above for exactly this reason; asking
    # it here too means the generic and the typed paths agree without a second
    # untypeable line pretending to be documentation.
    if ( $command =~ /\Arecord\.([a-z]+)\z/ ) {
        my $takes = $RECORD_USAGE{$1};
        return "Usage: d2 tira.$command $takes [-o toon|json|human]\n"
          if defined $takes;
    }
    return "Usage: d2 tira.$command [options] [-o toon|json|human]\n";
}
# The skill's own root, found by climbing out of lib/ rather than by counting
# directories. Both readers below used to say ".." twice, which was right while
# they lived in lib/Tira/CLI.pm and silently wrong the moment they moved one
# level deeper into lib/Tira/CLI/ - SKILLS.md and POLICIES.md were then looked
# for inside lib/, both opens failed, and the failure is a fallback rather than
# an error: every command's usage line quietly became a bare "[options]" and
# every policy help became the built-in short form. Five test files caught it;
# nothing in the code said a word.
#
# TKT-719. Lifted into Tira::_skill_root, the one shared implementation
# every call site now delegates to - this file's own copy did not count
# either, but was a second copy of the same climb with no guard for a path
# with no lib/ in it at all, which the shared version added.
sub _skill_root {
    return Tira::_skill_root();
}

sub _skills_usage_line {
    my ($command) = @_;
    if ( !defined $SKILLS_TEXT ) {
        my $path = File::Spec->catfile( _skill_root(), 'SKILLS.md' );
        local $/;
        if ( open my $fh, '<:raw', $path ) {
            $SKILLS_TEXT = <$fh>;
            close $fh;
        }
        $SKILLS_TEXT //= '';
    }
    my ($rest) = $SKILLS_TEXT =~ /^tira\.\Q$command\E\s+(\S.*)$/m;
    return $rest;
}
sub _policy_help {
    my (%args) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return '';
    my $doc = $args{document}
      // File::Spec->catfile( _skill_root(), 'docs', 'POLICIES.md' );
    if ( -f $doc && open my $fh, '<:raw', $doc ) {
        my $text = do { local $/; <$fh> };
        close $fh;
        return $text;
    }
    return _policy_help_fallback();
}
# Said when the document is not there. An installation missing its docs should
# still be able to tell an agent what exists, rather than answering nothing.
sub _policy_help_fallback {
    return join "\n",
      'Tira policies',
      '',
      'Rules: ' . join( ', ', @{ Tira::policy_rules() } ),
      'Actions: ' . join( ', ', @{ Tira::policy_actions() } ),
      '',
      'Declare one:  d2 tira.policy.add --rule <rule> --action <action> [parameters]',
      'See them:     d2 tira.policy.list',
      'Watch:        d2 tira.police            (the owner runs this)',
      'Listen:       d2 tira.policy.bridge     (the agent runs this)',
      '';
}

# The same arrangement for repeated jobs, and for the same reason - the document
# is the answer, this only finds it. TKT-886: his words, "I want to have a
# dedicated helpline for the agent to read like the tira.policies", so that an
# agent stops reaching for crontab or its own in-session loops.
sub _job_help {
    my (%args) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return '';
    my $doc = $args{document}
      // File::Spec->catfile( _skill_root(), 'docs', 'JOBS.md' );
    if ( -f $doc && open my $fh, '<:raw', $doc ) {
        my $text = do { local $/; <$fh> };
        close $fh;
        return $text;
    }
    return _job_help_fallback();
}

# Said when the document is not there, for the reason _policy_help_fallback
# gives: an installation missing its docs should still name what exists rather
# than answering nothing. It matters more here than there - this document exists
# because agents invent their own scheduling, and one that asks for help and
# gets silence has just been taught that the surface is unreliable.
sub _job_help_fallback {
    return join "\n",
      'Tira repeated jobs',
      '',
      'The board owns repeated work. Do not write a crontab entry, and do not',
      'keep a loop inside your own session - a session that ends takes the',
      'schedule with it, and a stopped loop looks exactly like a quiet one.',
      '',
      'A job announces a message or runs a command, on a cron schedule or as a',
      'monitor that stays running. Its output reaches the police bridge, which',
      'is the one channel - you do not need a log per job to watch.',
      '',
      'Make one:     d2 tira.job.add --schedule "0 * * * *" --message "TEXT"',
      '              d2 tira.job.add --schedule "0 * * * *" --command "COMMAND"',
      '              d2 tira.job.add --schedule monitor --command "COMMAND"',
      'See them:     d2 tira.job.list',
      'Change one:   d2 tira.job.update --id JOB-001 --schedule "0 */2 * * *"',
      'Start one:    d2 tira.job.start --id JOB-001    (monitor kind)',
      'Run one now:  d2 tira.job.run --id JOB-001',
      'Remove one:   d2 tira.job.delete --id JOB-001',
      'Listen:       d2 tira.policy.bridge            (one bridge, not a tail each)',
      '';
}
# What an unknown option gets, now: named the way "Command not found" names
# a mistyped verb - the closest declared names this command actually
# answers to, not silence past "Invalid command-line options". TKT-298.
sub _unknown_option_message {
    my ( $unknown, $spec ) = @_;
    my $known = _declared_option_names($spec);
    my @lines;
    for my $bad ( @{$unknown} ) {
        push @lines, "Unknown option: $bad";

        # A VALUE that begins with two dashes, not a mistyped flag. The two are
        # told apart by the one thing that distinguishes them here: $bad is the
        # first whitespace-delimited word of the rejected argument, so if it is
        # EXACTLY an option this command declares, the argument cannot have been
        # that option - a bare declared option parses. It was a value carrying
        # more text after the name.
        #
        # Worth separating because a card about an option names that option in
        # its title, so this is ordinary here rather than exotic. And the old
        # answer was the harmful one: the "Did you mean" list is computed from
        # the caller's own value, so it suggested back the exact string they had
        # just typed, which reads as a correct option being rejected. TKT-742.
        if ( grep { $_ eq $bad } @{$known} ) {
            # This function only sees the rejected token and the command's
            # spec, not which earlier option was expecting a value - so the
            # example below names the VALUE, never a specific carrier option.
            # Naming one would be a guess, and a wrong guess ("--title=...")
            # on a command with no --title would be worse than the vague
            # "Did you mean" this message replaces.
            push @lines,
              "--$bad is an option this command has, so this looks like a VALUE",
              'that begins with two dashes rather than a mistyped flag.',
              "Join it to its option to pass it as a value: --option=--$bad ...";
            next;
        }

        my %distance = map { $_ => Tira::_edit_distance( $bad, $_ ) } @{$known};
        my @near = sort { $distance{$a} <=> $distance{$b} || $a cmp $b }
          grep { $distance{$_} <= 3 } keys %distance;
        push @lines, 'Did you mean:', ( map { "  --$_" } @near[ 0 .. ( $#near > 2 ? 2 : $#near ) ] )
          if @near;
    }
    return join( "\n", @lines );
}
sub _names_the_option {
    my ( $message, $command ) = @_;
    for my $said ( sort keys %{ ( defined $command ? $COMMAND_OVERRIDE{$command} : undef ) // {} } ) {
        next if index( $message, $said ) < 0;
        my $suffix = $COMMAND_OVERRIDE{$command}{$said};
        return index( $message, $suffix ) >= 0 ? $message : "$message$suffix";
    }
    for my $said ( sort keys %SUPPLIED_BY ) {
        next if index( $message, $said ) < 0;
        my ( $flag, $phrase ) = @{ $SUPPLIED_BY{$said} };
        return $message if $message =~ /--\Q$flag\E\b/;
        return "$message - $phrase --$flag";
    }
    return $message;
}
# Every long name a command's own @spec actually answers to - both sides of
# a '|' alias, with Getopt::Long's value/repeat/negation syntax (=s, =s@,
# :i, !) stripped back to the bare flag. Built from the same @spec the
# parse just used, so a suggestion can never name a flag the command does
# not really have.
sub _declared_option_names {
    my ($spec) = @_;
    my @names;
    for ( my $i = 0; $i < @{$spec}; $i += 2 ) {
        ( my $names = $spec->[$i] ) =~ s/[=:!].*//;
        push @names, split /\|/, $names;
    }
    return \@names;
}
1;
