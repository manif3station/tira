package Tira::CLI::Options;

use strict;
use warnings;

# The option guard, one concern lifted out of Tira::CLI.
#
# Two declared tables and the refusal that enforces them: which options name
# the job another option does, and which options only some commands read. Both
# exist so a flag that parses but is never read cannot look accepted - a
# command that reports success without doing anything is worse than one that
# fails.
#
# Lifted on TKT-837 to make room under t/430's 3,000-line cap on
# lib/Tira/CLI.pm, which the repeated-job verbs would otherwise have breached.
# That is the remedy TKT-746 and TKT-751 already prescribe for an oversized
# file: move a concern out rather than raise the number.

# Where one option names the job another option does. Refused rather than
# silently discarded: a wrong flag that parses looks accepted, and a command
# that reports success without doing anything is worse than one that fails.
my %MISLEADING_OPTIONS = (
    'assign.set'    => [ [ 'assignee', 'person' ] ],
    'assign.add'    => [ [ 'assignee', 'person' ] ],
    'assign.remove' => [ [ 'assignee', 'person' ] ],

    # Evidence carries a summary, a link and an attachment. --details is
    # gate.add's, and evidence.add accepted it and threw it away: the entry it
    # printed looked complete because the summary was there, so nothing said
    # that half of what was typed had gone nowhere. A night of evidence on this
    # board lost its reasoning that way.
    'evidence.add'  => [ [ 'details', 'summary' ] ],
);

# An option the shared parser knows and a few commands read.
#
# --field names the field tira.history reports on, and the fields tira.search
# and tira.replace work over. Every other command took it, stored it and
# dropped it: a record update given --field exited zero and printed the card
# back, which reads as confirmation because the card is right there. An hour of
# this project's own writing went that way - a card raised from a bug hunt,
# filled in with six of them, and still a title when the push gate refused the
# release for it.
#
# Declared rather than derived, for the same reason %MISLEADING_OPTIONS is:
# there is no per-command list of the options each command uses, and inventing
# one would refuse things that work today. What is declared is an option whose
# readers are known.
#
# The readers were counted from the engine rather than from the CLI. Reading
# only the CLI found one - history.list, which names the option explicitly -
# and missed search and replace, which receive it in the arguments every
# command passes through. A refusal written from that count would have broken
# two working commands.
my %OPTION_READ_BY = (
    # The gate a move would not set. Accepted, dropped, exit 0, whole card
    # printed - which reads as confirmation because the card is right there.
    # It costs more than --field did: a board whose rules require the gate to
    # move with every transition makes "move and set the gate" the most natural
    # thing to type, so the correct action was being expressed in one command
    # and silently half-done. Refused rather than made to work, because that is
    # reversible and quietly doing half of a transition is not. TKT-281.
    sdlc_gate => {
        flag     => 'sdlc-gate',
        commands => qr/\Arecord\.(?:create|update)\z/,
        instead  => 'tira.<type>.update --sdlc-gate, which is the command that sets it',
    },

    # The reason a discard would not record. Accepted, dropped, exit 0, whole
    # card printed - and it happened twice in ten minutes on this project's own
    # board, with discard-unexplained firing both times.
    #
    # It costs more than --sdlc-gate did. The dropped value is the reason a card
    # was set aside, and discard-unexplained exists precisely to require that
    # reason, so the option that looks like the way to satisfy the rule is the
    # one way that cannot. TKT-302.
    comment => {
        flag     => 'comment',
        # The commands that DO read it, which is what this table lists - the
        # first draft named record.discard here and so declared the broken
        # command to be the one that works.
        commands => qr/\A(?:comment\.|attachment\.discard\z)/,
        instead  => 'tira.comment.add --ref REF --text TEXT, which is the command that records a reason',

        # attachment.discard reads --comment as an identifier - which
        # comment to detach the attachment from - not a reason, so of the
        # exempted commands it is the one where a caller could plausibly
        # mean the wrong thing. A value that cannot be a comment id is
        # refused the same way, rather than accepted and quoted back as a
        # missing identifier: measured live, 'tira.attachment.discard
        # --comment "Set aside because it was the wrong file"' answered
        # "Comment 'Set aside...' not found" and recorded nothing. TKT-373.
        shape_checked_on => qr/\Aattachment\.discard\z/,
        shape            => qr/\ACMT-\d+\z/,
    },

    fields => {
        flag     => 'field',
        commands => qr/\A(?:history\.list|search|replace)\z/,
        instead  => 'the options that set a field - --key-detail, --deliverable,'
          . ' --acceptance, --test-step and the rest the command reference lists',
    },

    # A link an evidence entry carries. Read in exactly one place in the whole
    # engine, evidence_add - so release.record (TKT-345) accepted --uri,
    # dropped it, and exited 0 with an evidence entry that looked complete
    # because the summary was right there. Same shape as sdlc_gate and
    # comment above: TKT-431.
    uri => {
        flag     => 'uri',
        commands => qr/\Aevidence\.add\z/,
        instead  => 'tira.evidence.add --ref REF --summary TEXT --uri TEXT, which is the command that reads it',
    },

    # Whether this board is worked by one agent or a chain of them. Accepted,
    # dropped, exit 0, whole project printed - the same shape as sdlc_gate and
    # comment above, on the project rather than a card. Several rules mean
    # different things between the two modes, so a board that believes it
    # declared chain and is still single gets different behaviour from every
    # one of them, with nothing to say why. TKT-382.
    mode => {
        flag     => 'mode',
        # project.new and onboard read it too - both write it themselves,
        # straight after the project exists, the same way this table's other
        # entries name every command that genuinely reads an option rather
        # than only the one whose name matches it.
        commands => qr/\A(?:project\.mode|project\.new|onboard)\z/,
        instead  => 'tira.project.mode --mode VALUE, which is the command that sets it',
    },
);

sub _refuse_unread_options {
    my ( $command, $option ) = @_;
    for my $name ( sort keys %OPTION_READ_BY ) {
        my $rule = $OPTION_READ_BY{$name};
        my $given = $option->{$name};
        next if !defined $given;
        next if ref $given eq 'ARRAY' && !@{$given};
        if ( $command =~ $rule->{commands} ) {
            next
              if !$rule->{shape_checked_on}
              || $command !~ $rule->{shape_checked_on}
              || $given =~ $rule->{shape};
        }
        die "$command does not act on --$rule->{flag}. Use $rule->{instead}.\n";
    }

    # And the rest of the surface, derived rather than listed. The table above
    # grew one entry per incident - TKT-281, TKT-302 - and each entry covered
    # the option somebody had already been bitten by. These two lists come from
    # the engine, so a field added to record_update is refused on the commands
    # that will not write it without anybody remembering to add it here.
    #
    # Which commands read what was measured rather than assumed, and the obvious
    # rule turned out to be wrong: record.create reads all eighteen append
    # fields and loses none, so "only update writes fields" would have broken
    # every card this project raises. Only the replacements are update-only.
    # Scoped to the record verbs that move a card about without writing its
    # fields, rather than to every command in the tool. The first draft applied
    # everywhere and broke the browser dashboard: --title is a card field on
    # create and update AND a display flag on tira.dashboard, which shows titles
    # beside references. A guard wide enough to catch every drop is also wide
    # enough to refuse commands that read the same word for something else.
    my %guarded = map { $_ => 1 }
      qw(record.move record.discard record.restore record.clone);
    my %flag_of = (
        problem_or_feature => 'problem', solution_needed => 'solution-needed',
        sdlc_gate => 'sdlc-gate', fix_version => 'fix-version',
        agent_session => 'agent-session', due_date => 'due-date',
        start_date => 'start-date', labels => 'label',
        affects_versions => 'affects-version', key_details => 'key-detail',
        deliverables => 'deliverable', test_steps => 'test-step',
        scope_in => 'scope-in', scope_out => 'scope-out',
    );
    for my $field ( @{ Tira::card_fields() } ) {
        next if !$guarded{$command};

        # The one option clone genuinely reads. Kept by name because a clone
        # without a title is refused for the title, and a first probe of this
        # read that refusal as a refusal of the option beside it.
        next if $command eq 'record.clone' && $field eq 'title';

        my $given = $option->{$field};
        next if !defined $given;
        next if ref $given eq 'ARRAY' && !@{$given};
        my $flag = $flag_of{$field} // $field;
        $flag =~ tr/_/-/;
        die "$command does not act on --$flag. Use tira.<type>.update --$flag,"
          . " which is the command that writes it.\n";
    }
    for my $field ( @{ Tira::card_field_replacements() } ) {
        # The replacements are update-only, so create is guarded here and not
        # above: it reads all eighteen append fields and loses none, measured.
        next if $command !~ /\Arecord\.(?:create|move|discard|restore|clone)\z/;
        next if $command eq 'record.update';
        my $given = $option->{ 'set_' . ( $field =~ s/_replace\z//r ) };
        next if !defined $given;
        ( my $flag = 'set-' . ( $field =~ s/_replace\z//r ) ) =~ tr/_/-/;
        die "$command does not act on --$flag. Use tira.<type>.update --$flag,"
          . " which is the command that replaces it.\n";
    }
    return;
}

# %MISLEADING_OPTIONS is read by Tira::CLI::_invoke, which stayed behind. It is
# reached through this accessor rather than by poking the package variable, so
# the table has exactly one owner and a caller cannot quietly add to it.
sub misleading_for {
    my ($command) = @_;
    return $MISLEADING_OPTIONS{ $command // '' } // [];
}

1;

__END__

=head1 NAME

Tira::CLI::Options - the option guard, lifted out of Tira::CLI

=head1 DESCRIPTION

C<%MISLEADING_OPTIONS> names the pairs where one option does the job another
claims; C<%OPTION_READ_BY> names options the shared parser knows but only some
commands read. C<_refuse_unread_options> enforces the second, and
C<misleading_for> hands the first to L<Tira::CLI>'s own C<_invoke>, which is
the only other reader.

Both tables are B<declared rather than derived>, and that is deliberate: there
is no per-command list of the options each command actually uses, and
inventing one would refuse things that work today. What is declared is an
option whose readers are known.

=head1 CALL IT THROUGH TIRA::CLI, NOT DIRECTLY

This module is an implementation detail of command dispatch. C<Tira::CLI>
loads it with C<require> at the two points that need it.

=head1 IF YOU EDIT THIS MODULE

=over 4

=item * B<Adding an option to the Getopt table is not enough.> An option that
no command reads belongs in one of these tables, or it will be accepted and
silently dropped. TKT-581 collects the instances that were missed; the one
that cost most was C<--details> on C<evidence.add>, which printed a
complete-looking entry while half of what was typed went nowhere.

=item * B<Do not derive the per-command list.> It has been considered and
rejected: the readers of C<--field> were counted from the engine rather than
the CLI, and a count taken from the CLI alone would have broken C<search> and
C<replace>, which receive it through the arguments every command passes.

=back

=head1 WHAT MUST NOT REGRESS

The refusal must name the option and where it belongs. A bare "unknown option"
sends the caller looking for a typo when the flag was real and simply had no
reader here.

=cut
