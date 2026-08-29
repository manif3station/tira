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
# %NEEDS_TYPE, $SKILLS_TEXT and %SUPPLIED_BY. A `my` at file
# scope cannot be reached from another package at all, so this is not a
# preference - the module does not compile without them, which is how the
# extractor's blind spot was found: it detects the case and refuses when the
# variable is read on both sides, but had no branch for bringing one along.

# What each record verb takes, so asking a command how to use it does not
# answer about a different one.
#
# Every record command shared one line and the line named create, so
# tira.ticket.move --help said 'Usage: dashboard tira.ticket.create --title
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

    # Given rather than missing: the option carried a value the command will
    # not take, so it is named rather than asked for.
    'Invalid column name'                  => [ 'name',         'the option is' ],
    'Invalid attachment SHA'               => [ 'sha',          'the option is' ],
    'Invalid gate result'                  => [ 'result',       'the option is' ],
    'Unknown policy rule'                  => [ 'rule',         'the option is' ],
    "Policy '' not found"                  => [ 'id',           'the option is' ],
    'A column layout must be JSON'         => [ 'columns-json', 'the option is' ],
);

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: dashboard tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';

    if ( $NEEDS_TYPE{ $command // '' } ) {
        my $known = _skills_usage_line($command);
        return "Usage: dashboard tira.$command $known\n" if defined $known;
        return "Usage: dashboard tira.$command --type ticket|epic|sow [options] [-o toon|json|human]\n";
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
        return "Usage: dashboard tira.$type.$verb $known\n" if defined $known;

        my $takes = $RECORD_USAGE{ $verb // '' };
        return "Usage: dashboard tira.$type.$verb $takes [-o toon|json|human]\n"
          if defined $takes;

        # A record verb this does not know is named rather than described,
        # which is still an answer about the command that was asked.
        return "Usage: dashboard tira.$type." . ( $verb // 'command' )
          . " [options] [-o toon|json|human]\n";
    }

    my $known = _skills_usage_line($command);
    return "Usage: dashboard tira.$command $known\n" if defined $known;
    return "Usage: dashboard tira.$command [options] [-o toon|json|human]\n";
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
# Counting is what broke, so this does not count. It climbs until it is out of
# lib/, which is true wherever under lib/ this file is moved to next.
sub _skill_root {
    my $here = File::Spec->rel2abs(__FILE__);
    my @parts = File::Spec->splitdir( ( File::Spec->splitpath($here) )[1] );
    pop @parts while @parts && $parts[-1] ne 'lib';
    pop @parts;
    return File::Spec->catdir(@parts);
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
# What an unknown option gets, now: named the way "Command not found" names
# a mistyped verb - the closest declared names this command actually
# answers to, not silence past "Invalid command-line options". TKT-298.
sub _unknown_option_message {
    my ( $unknown, $spec ) = @_;
    my $known = _declared_option_names($spec);
    my @lines;
    for my $bad ( @{$unknown} ) {
        my %distance = map { $_ => _edit_distance( $bad, $_ ) } @{$known};
        my @near = sort { $distance{$a} <=> $distance{$b} || $a cmp $b }
          grep { $distance{$_} <= 3 } keys %distance;
        push @lines, "Unknown option: $bad";
        push @lines, 'Did you mean:', ( map { "  --$_" } @near[ 0 .. ( $#near > 2 ? 2 : $#near ) ] )
          if @near;
    }
    return join( "\n", @lines );
}
sub _names_the_option {
    my ($message) = @_;
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
# Levenshtein distance, the standard three-operation edit count - the same
# measure a spelling-correction "did you mean" is built on anywhere it
# exists. Iterative, not recursive: the option lists here are short enough
# (a low hundred, at most) that clarity wins over avoiding an O(n*m) table.
sub _edit_distance {
    my ( $left, $right ) = @_;
    my @prev = ( 0 .. length $right );
    for my $i ( 1 .. length $left ) {
        my @row = ($i);
        for my $j ( 1 .. length $right ) {
            if ( substr( $left, $i - 1, 1 ) eq substr( $right, $j - 1, 1 ) ) {
                $row[$j] = $prev[ $j - 1 ];
                next;
            }
            my $least = $prev[$j];
            $least = $row[ $j - 1 ]     if $row[ $j - 1 ] < $least;
            $least = $prev[ $j - 1 ]    if $prev[ $j - 1 ] < $least;
            $row[$j] = 1 + $least;
        }
        @prev = @row;
    }
    return $prev[-1];
}
1;

__END__

=head1 NAME

Tira::CLI::Usage - the usage lines, the help, and "did you mean"

=head1 DESCRIPTION

C<_usage> returns the C<Usage:> line C<--help> prints for a command.
C<project.create> is written out; everything else comes from SKILLS.md's own
usage catalogue via C<_skills_usage_line>, so the documentation and the help are
one text rather than two that drift.

C<_unknown_option_message>, C<_names_the_option>, C<_declared_option_names> and
C<_edit_distance> are the refusal an unknown option gets, and the suggestion
that comes with it.

C<_policy_help> and C<_policy_help_fallback> answer the same question for
policies.

All of it is asked for by C<--help> and by the error paths, which is a minority
of invocations - so C<Tira::CLI> loads this module at the point one of them is
taken.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it.

It calls into no sibling module. This paragraph said otherwise until 4.74 -
one note written once and pasted into all eight, describing a chain three of
them do not sit in.

=head2 _usage

This entry came with the sub. It was left behind in
L<Tira::CLI>'s POD when the code moved in 4.74 - a heading describing a sub that
is no longer beneath it, which is the exact fault this card has produced in six
other forms, and it was found by a check that reads every C<=head2> in every
module and asks where that sub actually lives. TKT-607.

Returns the C<Usage:> line C<--help> prints for a command. C<project.create>
is written out here; everything else comes from SKILLS.md's own usage
catalogue via C<_skills_usage_line>, which greps for a line beginning
C<tira.E<lt>commandE<gt> >. A command with no line there falls back to a bare
C<[options]>, which names nothing.

Two shapes of failure, and the second is the dangerous one. A bare
C<[options]> at least admits it is withholding something. A line that
enumerates the optional flags and omits the mandatory ones looks complete, so
a caller composes from it with no reason to doubt it - which is what happened
to C<checklist.update>: it named three optional flags and not the
C<--command>/C<--proof> pair it refuses C<--status done> without, and another
board's agent wrote four calls from it, suppressed their output, and believed
four entries were ticked while the checklist read 0/9.

The pair was written as one bracketed unit, C<[--command TEXT --proof TEXT ...]>,
rather than two independent optionals: it was required together and repeatable,
and two brackets would have been true about the parser and false about the
command.

Since 4.64 that is no longer true and the line says
C<[--command TEXT ... [--proof TEXT ...]]> - the proofs nest inside the
commands as a group rather than pairing off one bracket at a time.

The nesting is doing exact work and the obvious shorter form is WRONG. Written
C<[--command TEXT [--proof TEXT] ...]> it would say each command may
independently carry a proof, so one command with a proof beside one without
would be legal. It is not: give any proofs at all and the counts must match,
"Every --command needs a matching --proof". Either all of them are proved or
none are. Measured, after writing that shorter form first and checking it. A C<--command> is now usable on its own, which
records what is being run and leaves the item where it is; the proof arrives
afterwards, repeating its command. What marks the item done is C<--status
done>, which refuses without the pair - a full pair given with C<--status
pending> is accepted, stored, and leaves the item pending. So the pair is still
required TOGETHER to mark something done, and no longer required at all to say
something has started. The nesting is what makes both true in one line, and it is the reason
this entry is worth reading rather than a formatting note: the bracket shape is
a claim about when the flags are needed, and TKT-628 changed when. TKT-575,
TKT-628.
Forty-nine commands still fall back to C<[options]>; t/410 holds that set as a
ledger so a new one cannot join it silently, and reads C<_usage> itself rather
than the SKILLS.md lookup, since what matters is what C<--help> prints.
TKT-575.

=head1 SEE ALSO

L<Tira::CLI>

=cut
