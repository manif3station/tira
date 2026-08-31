package Tira::CLI::Records;

# The two command bodies that were the largest blocks left inside
# Tira::CLI::_invoke: creating a record, and the question verbs.
#
# record.create is 187 lines because creating a card is where every field on a
# card gets validated, defaulted and cross-checked - which is worth its own file
# and is worth nobody having to read to change anything else.
#
# THEY TAKE \%args RATHER THAN CLOSING OVER IT. Inside _invoke both blocks read
# %args, $option and $command from the dispatcher's scope; here those arrive as
# arguments and nothing else about them changed.

use strict;
use warnings;

use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

sub record_create {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};

    # A card created directly into implement, or verify, or done never
    # needs the move TKT-426's chain check would refuse - reusing the
    # existing column-roles vocabulary ('which column is the backlog' is
    # already a role every board can answer) rather than a new mechanism.
    # Checked here, in the dispatch layer, so create_record itself - and
    # the dashboard's own create flow, which calls it directly - is
    # untouched. TKT-428.
    # Assigned before it is dereferenced, deliberately. eval BLOCK returns
    # undef when its block dies, so eval {...}->{entry} applies the arrow to
    # that undef OUTSIDE the eval's protection - and column_roles reaches
    # discover_project, which dies when there is no project. That made the one
    # failure this eval exists to tolerate the one that crashed it, with a
    # Perl file and line number where every other command refuses cleanly.
    # Splitting the two lets discover_project's own die reach the caller.
    # TKT-747.
    my $roles = eval { $tira->column_roles(%args) } // {};
    my $entry = $roles->{entry};

    # 'entry' may now name more than one column (TKT-496) - a board can
    # start new cards in more than one place. Normalised to a list here
    # so the single-entry case (still the common one) needs no branch of
    # its own: with exactly one entry, this behaves exactly as before -
    # the same column either matches or is refused.
    my @entries = ref $entry eq 'ARRAY' ? @{$entry} : ( defined $entry && $entry ne '' ? ($entry) : () );
    if (@entries) {
        if ( defined $args{column} && $args{column} ne '' ) {
            die "Cannot create $args{type} in $args{column} - the entry column"
              . ( @entries > 1 ? 's are ' . join( ', ', @entries ) : ' is ' . $entries[0] ) . ".\n"
              . "  Create there instead:  d2 tira.$args{type}.create --title TITLE --column $entries[0]\n"
              if !grep { $_ eq $args{column} } @entries;
        }
        else {
            # No column named: the first declared entry column, which is
            # exactly today's only entry column when there is just one -
            # nothing changes for a board that has never declared more.
            $args{column} = $entries[0];
        }
    }

    # A card landing in a column that carries required_actions needs an
    # author for the required_item_add calls below - and until now that
    # was discovered only by getting there: create_record has no author
    # requirement of its own (hundreds of test fixtures and the
    # dashboard's own create flow rely on that), so the record was
    # already written by the time required_item_add's own author check
    # died, leaving an orphaned, unattributed card on disk that a retry
    # with --author then duplicated rather than completed. Checked here,
    # before anything is written, using whichever column the card is
    # actually about to land in - entry role or explicit --column,
    # falling back to the same 'backlog' default create_record itself
    # uses. TKT-485.
    if ( !defined $args{author} || $args{author} eq '' ) {
        my $landing = defined $args{column} && $args{column} ne '' ? $args{column} : 'backlog';
        my $columns = eval { $tira->column_list(%args) };
        if ( ref $columns eq 'ARRAY' ) {
            my ($about_to_land) = grep { $_->{name} eq $landing } @{$columns};
            die "A change needs to say who is making it\n"
              if $about_to_land && @{ $about_to_land->{required_actions} // [] };
        }
    }

    # The record itself stays exactly what is stored - an agent can trust
    # that what it holds is what is on disk. The advice about it belongs to
    # the layer that talks to agents, not to the data.
    my $created = $tira->create_record(%args);

    # Where it landed, read from the board rather than repeated from the
    # request. --column used to be accepted and discarded, and a create that
    # cannot say where the card is is how three projects came to believe
    # theirs were somewhere they had never been. Asking the board means the
    # answer cannot drift from the truth the way a second copy of the
    # default would.
    # Only what finds the card. Passing the whole request would hand it the
    # caller's --fields as well, and a create that asked for two fields
    # would come back with no column at all.
    my $column = $tira->record_show(
        ref => $created->{ref},
        ( defined $args{project} ? ( project => $args{project} ) : () ),
    )->{column};

    # A column's required-action template is populated on every move-in
    # (TKT-427), but creation is not a move, so a card landing directly
    # in its entry column - or any column carrying required_actions -
    # never received them. Populated here into the card's own
    # required_items list, tagged with this landing column (TKT-445, not
    # checklist); the dashboard's own create flow, calling create_record
    # directly, is untouched. TKT-439.
    #
    # BOTH templates, since TKT-681. This used to read required_actions
    # alone, under a comment saying it mirrored the move-in logic exactly.
    # It did - it mirrored _populate_column_required_actions, which is the
    # EXIT seeder. Entry actions on a move come from a different function,
    # _populate_entry_required_actions, which creation never called. So a
    # card created straight into a column with an entry list was born past
    # a gate it could never be asked to pass: no items recorded, nothing
    # checking it, the gate not failed but skipped in silence.
    #
    # That function is called here rather than its logic repeated. The
    # whole cause of this bug was one path copying another's logic instead
    # of calling it, and a third copy would be the same mistake again.
    my $columns = eval { $tira->column_list(%args) };
    my ( @entry_seeded, @exit_seeded );
    if ( ref $columns eq 'ARRAY' ) {
        my ($landed) = grep { $_->{name} eq $column } @{$columns};
        @exit_seeded  = @{ $landed->{required_actions} // [] };
        @entry_seeded = @{ $landed->{entry_required_actions} // [] };

        $tira->required_item_add( %args, ref => $created->{ref},
            item => $_, status => 'pending', column => $column, source => 'required-action' )
          for @exit_seeded;

        # CREATION IS NEVER REFUSED FOR ONE OF THESE, and cannot be. A
        # required action's proof is a command and its output, and before
        # the card exists there is nothing to run a command against - the
        # owner's own reasoning on TSK-250. So they are recorded as
        # pending and the caller is told, rather than the create failing.
        my $unplaced = Tira::CLI::_populate_entry_required_actions(
            $tira, { %args, ref => $created->{ref} }, $column, $columns, $created );
        if ( @{ $unplaced // [] } ) {
            printf {*STDERR} "%s was created in %s, but %d of that column's entry required action(s) could not be put on the card: %s\n",
              $created->{ref}, $column, scalar @{$unplaced},
              join( '; ', map { ( length $_->[0] ? $_->[0] : '(an empty entry action)' ) . " - $_->[1]" } @{$unplaced} );
            my %failed = map { $_->[0] => 1 } @{$unplaced};
            @entry_seeded = grep { !$failed{$_} } @entry_seeded;
        }

        if ( @exit_seeded || @entry_seeded ) {

            # $created was captured before these writes; re-read so what
            # the caller sees is what is actually stored, the same
            # discipline record.move's own return already holds to.
            $created = $tira->record_show(
                ref => $created->{ref},
                ( defined $args{project} ? ( project => $args{project} ) : () ),
            );
        }
    }

    # And SAY so. The exit template has been seeded on create since
    # TKT-439 and printed by nothing, so an agent met those items only
    # when a move was refused - a silence older than the one this card was
    # raised for, and fixing only the newer one would have left it.
    #
    # To STDERR, because stdout is the card: -o json has to stay a
    # document an agent can parse, and the browser move path already
    # reports its entry-population failures this way.
    if ( @entry_seeded || @exit_seeded ) {

        # One item, one mention - WITHIN a list as well as across the two.
        #
        # required_item_add stores an item once however many times it is
        # asked for, and column_update does NOT dedupe a template, so both
        # kinds of repetition are storable: the same text twice inside one
        # list, and the same text in both lists. "Verify all details in
        # the card" is a plausible thing to owe on the way in and again
        # before leaving.
        #
        # Reported raw, the message contradicted the card twice over - a
        # count of two for one stored item, and the SAME REQ id printed
        # twice beside it, which reads as two items that happen to share
        # an id. Entry wins a text owed both ways, being the stricter:
        # owed now rather than owed eventually.
        my %seen;
        @entry_seeded = grep { !$seen{$_}++ } @entry_seeded;
        @exit_seeded  = grep { !$seen{$_}++ } @exit_seeded;

        # WITH THE IDS, because the point is to be actionable from the
        # message alone. The move refusal already names each item as
        # "REQ-001  the text" so acting on it is copying what was printed;
        # a create warning that listed only texts and then said "--id
        # REQ-NNN" would send its reader to ticket.show to map one to the
        # other, which is the cross-reference that has already put proofs
        # against the wrong ids on this board.
        my %id_of;
        for my $item ( @{ $created->{required_items} // [] } ) {
            next if ( $item->{column} // '' ) ne $column;
            $id_of{ $item->{item} // '' } //= $item->{id};
        }
        my $name = sub {
            join '; ', map { ( $id_of{$_} ? "$id_of{$_} " : '' ) . $_ } @{ $_[0] };
        };

        my @said;
        push @said, sprintf( "%d entry required action(s), owed now: %s",
            scalar @entry_seeded, $name->( \@entry_seeded ) ) if @entry_seeded;
        push @said, sprintf( "%d exit required action(s), owed before it leaves %s: %s",
            scalar @exit_seeded, $column, $name->( \@exit_seeded ) ) if @exit_seeded;
        my $first = ( $id_of{ ( @entry_seeded, @exit_seeded )[0] // '' } ) // 'REQ-NNN';
        printf {*STDERR} "%s was created in %s carrying %s\n  Work them one at a time: d2 tira.required-action.update --ref %s --id %s --status done --command TEXT --proof TEXT\n",
          $created->{ref}, $column, join( ', and ', @said ), $created->{ref}, $first;
    }

    my $reminder = $tira->record_reminder($created);
    return { %{$created}, column => $column,
        ( defined $reminder ? ( reminder => $reminder ) : () ) };
}

sub question_verbs {
    my ( $tira, $args, $option, $command ) = @_;
    my %args = %{$args};
    # $1 below is this match's, not the dispatcher's. The block read the
    # capture left by the if() it used to sit inside; as a sub it sets its
    # own, so a stale match elsewhere cannot choose the branch.
    $command =~ /\Aquestion\.(ask|list|answer|update|mark|discard)\z/ or return;
    my $action = $1;

    # By card reference alone: the reference already names the board, so
    # asking for the board as well would be asking for what is known.
    my %question = ( project => $args{project} );
    $question{ref} = $option->{ref_list}[0] if $option->{ref_list};
    $question{$_} = $option->{$_} for grep { defined $option->{$_} } qw(id text mark author reason);
    # ask as well as update. The option was accepted, refused on every
    # command it does not belong to - "A voice note belongs to the
    # question.ask, question.update and question.voice commands" - and then
    # passed through for update alone, so asking with a recording produced a
    # question whose own reminder told its author to supply the recording
    # they had just supplied. question_add has always attached it, after the
    # question exists so a bad recording fails the voice rather than the
    # question, and the manual has always documented it. Only this line
    # disagreed.
    $question{voice} = $option->{voice}
      if defined $option->{voice} && ( $action eq 'update' || $action eq 'ask' );
    $question{file} = $option->{file} if defined $option->{file} && $action eq 'answer';
    $question{caller_kind} = $option->{caller_kind} if defined $option->{caller_kind} && $action eq 'ask';
    $question{options} = $option->{options} if $option->{options};
    $question{status} = $option->{status} if defined $option->{status};
    $question{since} = $option->{since} if defined $option->{since};
    die "Peek is available on the question.list command\n"
      if $option->{peek} && $action ne 'list';
    $question{peek} = 1 if $option->{peek};
    return $tira->question_add(%question) if $action eq 'ask';
    return $tira->question_list(%question) if $action eq 'list';
    return $tira->question_answer(%question) if $action eq 'answer';
    return $tira->question_update(%question) if $action eq 'update';
    return $tira->question_discard(%question) if $action eq 'discard';
    return $tira->question_mark(%question);
}

1;

__END__

=head1 NAME

Tira::CLI::Records - creating a record, and the question verbs

=head1 DESCRIPTION

C<record_create> is the body behind C<tira.sow.create>, C<tira.epic.create> and
C<tira.ticket.create> - 187 lines, because creating a card is where every field
is validated, defaulted and cross-checked.

C<question_verbs> answers C<question.ask>, C<question.list>, C<question.answer>,
C<question.update>, C<question.mark> and C<question.discard>.

=head2 The capture that had to be re-taken

C<question_verbs> chose its branch from C<$1> - the capture left by the C<if>
in C<_invoke> it used to sit inside. A sub cannot read a caller's capture
safely: C<$1> would hold whatever the last match anywhere happened to leave, and
the block would take a branch rather than fail, which is the worse of the two
outcomes. So it matches C<$command> itself and sets its own.

=head2 Asking about a board that is not there

C<record_create> reads the C<entry> column role to decide where a card may
start, and that read has to survive there being no project at all. The lookup
is wrapped in C<eval> because a board declaring no entry role must still create
cards - but until 4.80 the guard was applied to the lookup's B<result>:

    my $entry = eval { $tira->column_roles(%args) }->{entry};

C<eval BLOCK> returns undef when its block dies, so the arrow dereferenced that
undef outside the protection the eval was written to give. C<column_roles>
reaches C<discover_project>, which dies when there is no project - so the one
failure the eval existed to absorb was the one that escaped it, and a create run
outside a project answered with C<Can't use an undefined value as a HASH
reference at lib/Tira/CLI/Records.pm line 36> where the other board-seeking
commands surfaced C<discover_project>'s own C<No Tira project found from '...'>
- C<record.show> and C<comment.add> were both measured giving it in the
identical condition.

Assigning before dereferencing lets that die reach the caller, which is why the
fix adds no message of its own. The C<// {}> matters as much as the split: a
board that cannot answer the question has no entry role, and creation carries
on. TKT-747.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it.

It calls into no sibling module. This paragraph said otherwise until 4.74 -
one note written once and pasted into all eight, describing a chain three of
them do not sit in.

=head1 SEE ALSO

L<Tira::CLI>

=cut
