package Tira::CLI::Move;

# The move-path guards and their bookkeeping, lifted out of Tira::CLI so the
# index stays an index (TSK-183, t/430) - TKT-1041, mirroring how TKT-607
# already lifted the record verbs into Tira::CLI::Records.
#
# Every function here still takes $tira/%args (or the equivalents the caller
# already had in hand) rather than closing over anything, exactly as they did
# inside Tira::CLI::_invoke - only the file they live in changed. The POD
# describing these guards ("The four guards on the move path" and the
# per-function =head2 entries) stays in Tira::CLI.pm, deliberately: t/430
# asserts that heading is still there, since a reader following the move path
# looks at the index first, and moving the documentation away from the file
# that still names it in that index would cost the very thing this lift is
# for.
#
# THEY ARE NOT RENAMED. Every one is still called through Tira::CLI's own
# name - _columns_for, _column_chain_violation, and so on - by a one-line
# forward in Tira::CLI.pm (require'd at the point of use, never `use`d at the
# top, per t/430's own lazy-loading check), so every existing caller inside
# Tira::CLI, and every caller elsewhere that already reaches these by their
# fully-qualified Tira::CLI:: name (Tira::CLI::Browser, Tira::CLI::Records,
# and several tests), needed no change at all.

use strict;
use warnings;

use Tira;
use Tira::CLI ();

sub _columns_for {
    my ( $tira, $args, $known ) = @_;
    if ( !defined $args->{type} || $args->{type} eq '' ) {
        my $type = ref $known eq 'HASH' ? $known->{type} : undef;
        if ( !defined $type || $type eq '' ) {
            my $seen = eval { $tira->record_show( %{$args} ) };
            $type = ref $seen eq 'HASH' ? $seen->{type} : undef;
        }

        # Written back into the caller's own arguments rather than kept to a
        # local copy. The chain guard ends its refusal with the move to make
        # instead - "d2 tira.<type>.move" - and formats it from %args, so
        # recovering the type for the lookup alone left the gate correctly
        # closed and the caller told to run "d2 tira..move", with an
        # uninitialized warning beside it. The other two guards name a command
        # of their own (required-action.update, question.mark) and never
        # interpolate the type, so this matters to one refusal in three; it is
        # written here rather than there because the next guard to end with a
        # typed command should not have to rediscover it. Recovering a fact and
        # then not telling the caller is how the first version of this fix
        # passed every test about the gate while still misdirecting the person
        # who hit it. Codex review, TKT-597.
        $args->{type} = $type if defined $type && $type ne '';
    }
    return eval { $tira->column_list( %{$args} ) };
}

sub _column_chain_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq ( $args{column} // '' );
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    my $from_idx = $index{$from};
    my $to_idx   = $index{ $args{column} };

    # Backward is always fine, fork or no fork.
    return undef if $to_idx <= $from_idx;

    my ($from_col) = grep { $_->{name} eq $from } @{$columns};
    my $fork = $from_col ? ( $from_col->{next} // [] ) : [];
    my $blocked;
    if ( @{$fork} ) {
        if ( !grep { $_ eq $args{column} } @{$fork} ) {
            my $options = join( ' or ', @{$fork} );
            $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $options.\n"
              . "  Move there first, e.g.:  d2 tira.$args{type}.move --ref $args{ref} --column $fork->[0]\n";
        }
    }
    elsif ( $to_idx > $from_idx + 1 ) {
        my $next_name = $columns->[ $from_idx + 1 ]{name};
        $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $next_name.\n"
          . "  Move there first:  d2 tira.$args{type}.move --ref $args{ref} --column $next_name\n";
    }
    return undef if !defined $blocked;

    my @log = @{ $current->{gate_passing_log} // [] };
    my $all_gated = 1;
    SKIPPED: for my $j ( $from_idx + 1 .. $to_idx - 1 ) {
        my $name = $columns->[$j]{name};
        next SKIPPED if grep { ( $_->{gate} // '' ) eq $name && ( $_->{result} // '' ) eq 'pass' } @log;
        $all_gated = 0;
        last SKIPPED;
    }
    return undef if $all_gated;
    return $blocked;
}

# A column names what must be done before a card leaves it (TKT-427); the
# move refuses, naming which of that column's required items are still
# unmarked, instead of the checklist item existing as a suggestion nobody is
# made to act on. discard is exempt, same as the chain check above and for
# the same reason: abandoning work is not leaving a stage undone. Checked in
# this same CLI-only dispatch layer - the dashboard's own move provider calls
# record_move directly and is untouched.
#
# Only a forward departure is checked. A backward move is how a card escapes
# a column it cannot currently satisfy - the unmet item may be exactly what
# failed, e.g. a test column's own 'tests green' - so gating retreat the same
# way as progress would leave a card with nowhere to go. This matches the
# chain check's own backward exemption.
# What a card must already have done before it may be worked in a column.
#
# The mirror of the gate below, and deliberately not a variant of it: that one
# asks what is unfinished in the column being LEFT, this asks what is unmet in
# the column being ENTERED. The owner's example is work that belongs to neither
# column's own business - "Verify all details in the card", between backlog and
# tests-red - which is why it cannot be expressed as an exit action on the
# column before it. TKT-591.
#
# The items are populated BEFORE the refusal, on purpose. An entry gate is
# satisfied from outside the column it guards, so if the list only appeared once
# the card was inside there would be nothing to mark and no way in. The first
# attempt therefore brings the list onto the card and refuses; the second, once
# the items carry their evidence, goes through.
#
# Forward moves only, like every other gate here. A card being sent back is not
# asked to qualify for where it is retreating to (TKT-455) - the unmet thing may
# be exactly what it is going back to fix.
# Putting a column's entry template on a card, without deciding anything about
# whether the card may be there.
#
# Shared by the gate below and by the browser move provider, and the split is
# TKT-452's, stated where the browser path already makes it: the gating half is
# CLI-only, because a human dragging a card is not an agent skipping a gate,
# but keeping the card accurate for whoever reads it next is not enforcement
# and has to happen either way. A card dragged into a column would otherwise
# carry that column's exit actions and none of its entry ones, which is a card
# that lies about what was asked of it.
#
# Returns what it could NOT add, as [text, why] pairs, rather than swallowing
# the failure: the caller decides what that means. The gate refuses on it; the
# browser path, which cannot refuse, still has it to report. TKT-591.
sub _populate_entry_required_actions {
    my ( $tira, $args, $to, $columns, $record ) = @_;
    my ($to_col) = grep { $_->{name} eq $to } @{ $columns // [] };
    my @template = @{ ( $to_col ? $to_col->{entry_required_actions} : undef ) // [] };
    return [] if !@template;

    my @failed;
    for my $entry (@template) {
        # TKT-936/Q-154: same conditional shape as the exit template below.
        my ( $text, $touches ) = ref $entry eq 'HASH' ? ( $entry->{text}, $entry->{touches} ) : ( $entry, undef );
        next if $touches && !Tira::CLI::_record_touches_any( $tira, $args, $touches );

        # Always call required_item_add - its dedup (TKT-497) is what stamps entry=>1 onto a pre-existing item (TKT-652). TKT-783.
        my $added = eval {
            $tira->required_item_add( %{$args}, item => $text, status => 'pending',
                column => $to, source => 'required-action', entry => 1 );
            1;
        };
        next if $added;
        my $why = $@ // 'no reason given';
        $why =~ s/\s+/ /g;
        $why =~ s/\A\s+|\s+\z//g;
        push @failed, [ $text, $why ];
    }
    return \@failed;
}

sub _column_entry_required_action_violation {
    my ( $tira, %args ) = @_;
    my $to = $args{column} // '';
    return undef if $to eq '' || $to eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq $to;

    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{$to};
    return undef if $index{$to} < $index{$from};

    my ($to_col) = grep { $_->{name} eq $to } @{$columns};
    my @template = @{ ( $to_col ? $to_col->{entry_required_actions} : undef ) // [] };
    return undef if !@template;

    my $unpopulated = _populate_entry_required_actions( $tira, \%args, $to, $columns, $current );
    my @unpopulated = @{$unpopulated};
    if (@unpopulated) {
        return "Cannot move $args{ref} into $to - "
          . scalar(@unpopulated)
          . " of its entry required actions could not be put on the card, so none of them can be worked.\n"
          . join( '', map { "  " . ( length $_->[0] ? _first_line( $_->[0] ) : '(an empty entry action)' )
                . "  ($_->[1])\n" } @unpopulated )
          . "  Fix the column's entry list, then move again:\n"
          . "    d2 tira.column.update --type $args{type} --name $to --entry-required-action TEXT\n";
    }

    my $refreshed = eval { $tira->record_show(%args) } // $current;
    my %exempt = map { ( ref($_) eq 'HASH' ? $_->{item} : $_ ) => 1 }
      @{ $refreshed->{required_exempt} // [] };
    # TKT-936/Q-154: an unmatched conditional was never placed above and must not count as wanted, or a pre-existing item sharing its text reads as satisfying it.
    my %wanted = map { ( ref $_ eq 'HASH' ? $_->{text} : $_ ) => 1 }
      grep { ref $_ ne 'HASH' || Tira::CLI::_record_touches_any( $tira, \%args, $_->{touches} ) } @template;
    my @unmet = grep {

        # Trusted on the marker OR a live text match against the CURRENT
        # entry template - either is sufficient evidence this item is an
        # entry obligation. The marker alone survives a column rename
        # (TKT-652: an item populated under the old wording keeps gating
        # after the column's entry text changes, since its stored text no
        # longer matches %wanted but its marker still says entry). The text
        # match alone is what keeps TKT-445/t/422's "do the work early"
        # capability working: a manual required-action.add item, or one
        # written before this column ever had an entry template, has no
        # marker but still satisfies a live-matching entry requirement,
        # symmetric with how it already satisfies the exit list.
        ( $_->{column} // '' ) eq $to
          && ( $_->{entry} || $wanted{ $_->{item} // '' } )
          && !$exempt{ $_->{item} }
          && !_item_is_done($_);
    } @{ $refreshed->{required_items} // [] };
    return undef if !@unmet;

    return "Cannot move $args{ref} into $to - "
      . ( @unmet == 1 ? 'an entry required action is' : scalar(@unmet) . ' entry required actions are' )
      . " not done. The card stays in $from:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{item} ) . "\n" } @unmet )
      . "  They are on the card now, so they can be done from here.\n"
      . "  Mark one, then move again:\n"
      . "    d2 tira.required-action.update --ref $args{ref} --id $unmet[0]{id} --status done --command TEXT --proof TEXT\n";
}

# What is blocking this card HERE, answerable without attempting a move.
#
# required-action.list returns every item on a card across every column - 75 on
# the card this was measured against - so the only way to learn what is in the
# way was to try a move and be refused. That is a strange shape for a system
# whose whole purpose is telling an agent what to do next, and it is why the
# refusal was the only place the answer existed.
#
# Deliberately the SAME selection the refusal makes - the column the card is
# in, minus this card's exemptions, minus anything already done - rather than a
# second definition that could drift from it. If these two ever disagree, the
# agent is told one thing and refused for another.
#
# Not named card.required or anything like it: tira.card.required already
# exists and answers which FIELDS a complete card needs, which is a different
# question, and a third similarly-named thing would mislead. TKT-598.
# The one selection. Both the refusal and the on-demand answer call this, so
# "they cannot drift" is a fact about the code rather than a promise in a
# comment - the first version of this card left the refusal with its own copy
# of the grep while the comment beside it claimed otherwise, which codex review
# caught and which is the same shape as a POD promising a report nothing wrote.
sub _unmet_in_column {
    my ( $record, $column ) = @_;
    return [] if ref $record ne 'HASH';
    return [] if !defined $column || $column eq '';
    my %exempt = map { ( ref($_) eq 'HASH' ? $_->{item} : $_ ) => 1 }
      @{ $record->{required_exempt} // [] };
    return [ grep {
        ( $_->{column} // '' ) eq $column
          && !$exempt{ $_->{item} }
          && !_item_is_done($_);
    } @{ $record->{required_items} // [] } ];
}

# Answering the same question on demand. The card must exist: turning a failed
# read into an empty list would say "nothing is blocking you" about a ref that
# is missing, misspelled or unreadable, and say it with exit 0 - while the same
# command without --blocking says "Record 'X' not found" and exits 2. Codex
# probed exactly that. A question about a card that is not there has no answer,
# so the error is left to travel.
sub _outstanding_here {
    my ( $tira, %args ) = @_;
    my $current = $tira->record_show(%args);
    return _unmet_in_column( $current, $current->{column} );
}

sub _column_required_action_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq ( $args{column} // '' );
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    return undef if $index{ $args{column} } < $index{$from};

    # The column's template is a baseline, not an absolute: a card can carry
    # its own exemptions from specific items (tira.<type>.update
    # --exempt-required TEXT), for a situation the column-wide template does
    # not fit. Checked here rather than by the card silently omitting the
    # item, so the exemption is a decision on record, not an absence nobody
    # can tell from a genuine oversight. TKT-439.
    # An exemption recorded before TKT-473 is a bare string; one recorded
    # since carries {item, reason, exempted_at, author}. Both name the item
    # the same way to _unmet_in_column, which is where the exemption is now
    # honoured for this guard and for the on-demand answer alike.

    # Required items are their own list, tagged by the column they belong
    # to - not a card's checklist, which stays purely manual. Gating reads
    # this list directly rather than cross-referencing the column's live
    # template, so a card-specific item an agent added
    # (tira.required-action.add) gates exactly like a template-derived one -
    # it was never part of the column's template to begin with. TKT-445.
    # Status is free text, same as checklist - only the comparison against
    # "done" is case-insensitive, so --status Done is not read as still
    # outstanding and refused forever with a message that names the very
    # word the person already used. TKT-434.
    my @unmet = @{ _unmet_in_column( $current, $from ) };
    return undef if !@unmet;

    # One item per line with the id beside it, and the suggested command
    # carrying a REAL id from that list.
    #
    # This used to join the item texts with '; ' and then hand back a command
    # containing the literal REQ-NNN - so acting on the refusal meant running
    # required-action.list, finding each item by matching its text, and reading
    # off the id. On a card with 75 items across a dozen columns that is a
    # cross-reference by eye, and it put proofs against the wrong ids twice on
    # this board. The ids were in @unmet the whole time; the map took the text
    # and dropped them.
    #
    # Measured before it was changed: refusing a real card out of planning
    # produced one line of over a thousand characters covering 12 items whose
    # own texts contain semicolons, backticks and inline command examples -
    # joined with '; ' into prose that has to be re-parsed by eye to see where
    # one item ends and the next begins. TKT-598.
    return "Cannot move $args{ref} out of $from - "
      . ( @unmet == 1 ? '1 required action is' : scalar(@unmet) . ' required actions are' )
      . " not done:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{item} ) . "\n" } @unmet )
      . "  Mark one, then move again:\n"
      . "    d2 tira.required-action.update --ref $args{ref} --id $unmet[0]{id} --status done --command TEXT --proof TEXT\n";
}

# The preventive half of TKT-583, and the owner placed it at the move on
# purpose: "remind the agent when the move a card into a new column ... Go
# through them 1 by 1 and provide the proof and command 1 at a time. DO NOT
# LEAVE IT AT LAST AND USE THE SAME PROOF FOR ALL REQUIRED ACTION ITEMS."
#
# The refusal in required_item_update catches a reuse once it is attempted.
# This is earlier: the move is when the new column's list arrives, and the
# reuse happens when an agent reaches the end of that column's work holding a
# list it never read item by item and one recent command. Reminding here is
# the last moment before the habit has anything to act on.
#
# Printed to STDERR so it reaches a person without joining the command's
# machine-readable output, and only when the column actually brought
# required actions with it - a reminder that fires on every move is one
# nobody reads. TSK-168.
# Whether a required item is finished, asked once.
#
# TKT-657. Four places compared a status against 'done' by hand. Three
# lowercased first and _remind_one_at_a_time did not, so an item marked 'Done'
# - the capital the CLI accepts, and which TKT-434 deliberately made the gates
# tolerate - was DONE to every gate and OUTSTANDING to the move-in reminder,
# which then told an agent to work items already finished.
#
# The drift is the argument for the predicate, not the tidiness. This was the
# third instance of one fault in a single day: the dashboard compared against
# the literal 'done' (TKT-601), tools/card-holes did it twice in opposite
# directions and refused a real release (TKT-671), and these four were the
# third. Four hand-written comparisons cannot be guarded as a set - TKT-671's
# ledger greps tools/ for exactly this and cannot see lib/ - but a named
# predicate can be grepped for, and t/422 does.
#
# Nothing is normalised on write. 'Done' stays 'Done' on the card; this is the
# one place that reads it.
sub _item_is_done {
    my ($item) = @_;
    return lc( ( ref $item eq 'HASH' ? $item->{status} : $item ) // '' ) eq 'done';
}

sub _remind_one_at_a_time {
    my ( $tira, $args, $column ) = @_;
    return if !defined $column || $column eq '';

    my $record = eval { $tira->record_show( %{$args} ) } or return;
    my @here = grep { ( $_->{column} // '' ) eq $column && !_item_is_done($_) }
      @{ $record->{required_items} // [] };
    return if !@here;

    print {*STDERR} "\n"
      . "This column brought " . scalar(@here) . " required action(s) with it.\n"
      . "Read them first, then work them ONE AT A TIME, each with its own\n"
      . "--command and --proof from the run that actually satisfied it.\n"
      . "Do not leave them to the end and do not use the same proof for all of\n"
      . "them - one piece of evidence cannot prove two different instructions.\n\n";
    return;
}

# An answer that was read, acted on, and never judged.
#
# Reading is automatic - question_list stamps read_at on the way past, and
# lib/Tira.pm says so: "Reading is what marks an answer read - the agent does
# nothing extra." Judging is a deliberate tira.question.mark that nothing asks
# for until answer-unjudged fires hours later, by which time the card is
# finished and the agent has moved on. Observed twice in one session on this
# board, hours apart, by the agent that had just filed the card about it.
#
# So the prompt is moved to the moment it belongs to: a card does not move
# forward while ANY answer on it carries no mark, from whichever column that
# answer was given in. This comment said "does not leave the column an answer
# was given in" until 5.83, which was never what the code did - three
# documents were written from that reading and stayed wrong for a year
# (TKT-627).
#
# This reads the question's own mark rather than raising a required-action item
# to stand in for it, and that is the point rather than a shortcut. A required
# item is marked done with a command and a proof like any other, so an agent
# can satisfy it in the same sweep as everything else without ever forming a
# view - which is the "acknowledgement the agent can click through" TKT-584's
# third acceptance criterion rules out. There is nothing here to satisfy but
# the act itself.
#
# Four things stay ungated on purpose. An UNANSWERED question: waiting on the
# owner is its normal state and question-unanswered is a different rule about a
# different person. A DISCARDED one: nobody owes a judgement on a withdrawn
# question. An answer marked NOT-OK: the gate wants an assessment, not
# agreement, and answer-not-ok-unresolved already watches what follows a cross.
# And READING: a check that consulted read_at would release itself on the way
# past, which is not a check.
#
# answer-unjudged is untouched and stays the backstop for whatever escapes
# this - a card discarded, or a board where the move never comes. TKT-584.
sub _unjudged_answer_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq ( $args{column} // '' );

    # Forward moves only, the same index comparison the required-action gate
    # makes. A backward move is unconditional by TKT-455's design, because the
    # thing left unmet may be exactly what the card is retreating to fix - and
    # an unjudged answer is a particularly good reason to retreat, since the
    # person who would judge it may be why the card is going back. Written
    # without this at first, which refused a card being sent back to fix
    # something; found by probing, not by a test, because none of t/407's
    # assertions moved a card backward.
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    return undef if $index{ $args{column} } < $index{$from};

    my @unjudged = grep {
        $_->{answer} && !$_->{discarded_at} && !( $_->{answer}{mark} // '' );
    } @{ $current->{questions} // [] };
    return undef if !@unjudged;

    # The answer is located on the CARD, not in the column being left. The
    # older wording - "out of $from - an answer has not been judged" - put the
    # column and the answer in one breath, and read as though the answer
    # belonged to $from. It was not only the reader who took it that way:
    # three documents wrote that reading down as the rule, and stayed wrong
    # for a year (TKT-627). The move being refused is still named, because
    # that is what the reader is holding; what changes is where the answer is
    # said to live, which is anywhere on the card.
    return "Cannot move $args{ref} out of $from - this card carries "
      . ( @unjudged == 1 ? 'an answer' : scalar(@unjudged) . ' answers' )
      . " nobody has judged:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{text} ) . "\n" } @unjudged )
      . "  Judge it, then move again:\n"
      . "    d2 tira.question.mark --ref $args{ref} --id $unjudged[0]{id} --mark ok|not-ok\n";
}

# One line of a question, short enough to sit in a refusal beside its id.
sub _first_line {
    my ($text) = @_;
    my ($line) = split /\n/, ( $text // '' );
    $line //= '';
    return length($line) > 72 ? substr( $line, 0, 69 ) . '...' : $line;
}

# A card returning to the queue, and the tasks that still say somebody is on it.
#
# The board already understands that retreating undoes claims of progress: a
# backward move resets the required items between destination and origin,
# keeping their proof (TKT-455). Tasks were never part of that, so a card could
# sit in backlog while its tasklist went on reading "working" until somebody
# ran a second command nobody prompts for. The owner asked for it to happen on
# the move itself.
#
# Anchored to backlog because it is the default builtin column - a fix point
# every board has, so this needs no per-board configuration. A retreat that
# stops short of the queue is not the same statement about the work.
#
# Three decisions, each deliberate:
#
#   A DONE task is left alone. It records work that actually happened, and a
#   card retreating does not unmake it.
#
#   The reset CROSSES the session boundary. Tasklist items are session-scoped
#   (TKT-537), and on a multi-agent board the tasks most needing reset belong
#   to somebody else's session - a reset that respected the boundary would do
#   nothing in exactly the case it exists for.
#
#   A task naming MORE THAN ONE card is not reset, and is named in the output.
#   Q-088: "Never reset a task with more than one linked card, and say so in
#   the output so it is visible rather than silent." There is no status true
#   about both cards at once, and a silent skip is indistinguishable from the
#   feature being broken - the person moving the card is the only one who can
#   judge whether that task needed resetting by hand. TKT-596.
sub _reset_linked_tasks_on_return {
    my ( $tira, $args, $to ) = @_;
    return if ( $to // '' ) ne 'backlog';
    my $ref = $args->{ref};
    return if !defined $ref || $ref eq '';

    # Only project and all_sessions are meant to reach tasklist_list - not
    # the move's whole argument set. A move carrying --status (an option
    # move itself does nothing with, parsed only because Getopt shares one
    # @spec across every command) used to splat straight through and
    # tasklist_list treats status as a filter, dying on a value it does not
    # recognise - silently cancelling the reset below. TKT-632.
    my $items = eval {
        $tira->tasklist_list( project => $args->{project}, all_sessions => 1 );
    };
    if ( ref $items ne 'ARRAY' ) {
        my $why = $@ || 'no reason given';
        $why =~ s/\s+/ /g;
        printf {*STDERR} "\nCould not check for linked tasks to reset: %s\n", substr( $why, 0, 200 );
        return;
    }

    my ( @reset, @skipped, @failed );
    for my $item ( @{$items} ) {
        my @refs = @{ $item->{refs} // [] };
        next if !grep { $_ eq $ref } @refs;
        next if ( $item->{status} // 0 ) != 1;
        if ( @refs > 1 ) { push @skipped, $item; next }

        # A failure here is SAID, not swallowed. Written first as a bare eval
        # whose failure left the task neither reset nor mentioned - the task
        # would go on reading "working" and the move would report nothing,
        # which is indistinguishable from there having been no task at all.
        # That is the same silent-skip fault this card's own multi-ref rule
        # exists to avoid, one line lower down.
        my $ok = eval {
            $tira->tasklist_update(
                %{$args}, id => $item->{id}, status => 'pending',
                session => $item->{session} // '',
            );
            1;
        };
        if   ($ok) { push @reset,  $item }
        else       { push @failed, [ $item, $@ ] }
    }
    return if !@reset && !@skipped && !@failed;

    print {*STDERR} "\n";
    printf {*STDERR} "%d task(s) reset to pending, because %s went back to the queue:\n",
      scalar @reset, $ref
      if @reset;
    printf {*STDERR} "  %s  %s\n", $_->{id}, _first_line( $_->{text} ) for @reset;
    if (@skipped) {
        printf {*STDERR} "%d task(s) left alone, each linked to more than one card -\n"
          . "check by hand whether they should still say working:\n", scalar @skipped;
        printf {*STDERR} "  %s  %s  (also on %s)\n", $_->{id}, _first_line( $_->{text} ),
          join( ', ', grep { $_ ne $ref } @{ $_->{refs} // [] } )
          for @skipped;
    }
    if (@failed) {
        printf {*STDERR} "%d task(s) could NOT be reset and still say working -\n"
          . "reset them by hand:\n", scalar @failed;
        for my $pair (@failed) {
            my ( $item, $why ) = @{$pair};
            $why //= 'no reason given';
            $why =~ s/\s+/ /g;
            printf {*STDERR} "  %s  %s  (%s)\n", $item->{id},
              _first_line( $item->{text} ), substr( $why, 0, 80 );
        }
    }
    print {*STDERR} "\n";
    return;
}

# The other half of TKT-427, applied after a move succeeds: the destination
# column's required-action template is added to the card's checklist,
# skipping anything it already carries so re-entering a column never
# duplicates. A backward move resets to undone every required item belonging
# to a column from the new position through the old one, inclusive on both
# ends - owner's own example, EPC-002 comment 17:11:14: chain
# backlog->planning->doc->code->test->review, a card at test moved back to
# planning resets required items for test, code, doc AND planning itself,
# because redoing the work means every one of those checks - including the
# column landed on - needs satisfying again on the way back through. Until
# 3.13 the destination was excluded, so an item already done there stayed
# done even though the card was landing back on that exact column; the
# owner asked for it included (TG msg 4342). TKT-455. discard is excluded
# on both sides: its position in the declared column order is not a
# statement about how much work it undoes. Since TKT-678, an item declared --administrative-action on its column is exempt from this reset entirely - see the admin-exemption check in _apply_column_required_actions below.
sub _apply_column_required_actions {
    my ( $tira, $args, $from, $to, $columns, $record ) = @_;
    return
      if !defined $from || !defined $to || $from eq 'discard' || $to eq 'discard'
      || $from eq $to || ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return if !exists $index{$from} || !exists $index{$to};
    my $from_idx = $index{$from};
    my $to_idx   = $index{$to};

    # Required items live on their own list, each tagged with the column it
    # applies to (TKT-445) - not the card's checklist, which this mechanism
    # never touches again. Dedup and reset both match on (column, item)
    # rather than item text alone, so an identical required-action string
    # declared on two different columns can never be confused for one item.
    my @required_items = @{ $record->{required_items} // [] };

    if ( $to_idx > $from_idx ) {
        Tira::CLI::_populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );
    }
    elsif ( $to_idx < $from_idx ) {
        my %admin; for my $col ( @{$columns} ) { $admin{ $col->{name} } = { map { ( $_, 1 ) } @{ $col->{administrative_actions} // [] } } }
        my @reset; for my $item (@required_items) {
            next if !defined $item->{column} || !exists $index{ $item->{column} };
            my $item_idx = $index{ $item->{column} };
            next if $item_idx < $to_idx || $item_idx > $from_idx;
            next if $admin{ $item->{column} }{ $item->{item} };    # TKT-678/Q-100: declared per-item exemption

            # Same case-insensitive comparison as the move-out gate above -
            # an item marked --status Done is genuinely done, and must reset
            # on the way back through exactly as --status done would. TKT-434.
            next if !_item_is_done($item);
            # column deleted, not spread: $args carries the MOVE's own
            # destination, which disagrees with most items reset here by
            # range rather than by name - TKT-700's new guard would refuse.
            my %reset_args = %{$args};
            delete $reset_args{column};
            $tira->required_item_update( %reset_args, id => $item->{id}, status => 'pending', source => 'required-action' );
            push @reset, $item->{item};
        }

        # A backward move-in is still a move-in: the destination column's own
        # template must be on the card even if it was never populated on an
        # earlier forward pass - which happens when the template was declared
        # after the card had already left that column once, exactly what
        # TKT-458 hit in practice. TKT-464.
        Tira::CLI::_populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );

        # zen-framework's report (TKT-525): a card moved all the way back
        # into Backlog - always the structurally-first column, so this reset
        # is the most extreme case the branch above already handles - looked
        # broken because nothing said why a done item, proof intact, now
        # reads pending. The reset is correct (TKT-455); what was missing was
        # an explanation on the card itself. Michael's answer to Q-079: keep
        # the reset, add the comment. One comment per move, not one per item,
        # and only when something actually reset - a backward move that
        # resets nothing has nothing to explain.
        if (@reset) {
            eval {
                $tira->comment_add( %{$args},
                    text => "Moved backward from $from to $to: " . scalar(@reset)
                      . ' required item(s) reset to pending, proof kept - '
                      . join( ', ', @reset )
                      . '. This is the intended backward-move design (redoing work from here means every check between here and where you were needs satisfying again), not something undone by hand.',
                );
            };
        }
    }
    return;
}

=head1 NAME

Tira::CLI::Move - the move-path guards and the bookkeeping that follows a move

=head1 DESCRIPTION

Every function here is CALLED FROM OUTSIDE this module through C<Tira::CLI>'s
own name - a one-line forward, required at the point of use rather than
C<use>d at the top, exactly mirroring how C<Tira::CLI::Records> and
C<Tira::CLI::Serve> are already reached. Nothing here is renamed, so every
existing external caller - C<Tira::CLI>'s own dispatcher, and the callers
elsewhere that already reach some of these by their fully-qualified
C<Tira::CLI::> name (C<Tira::CLI::Browser>, C<Tira::CLI::Records>, and a
handful of tests) - needed no change at all. Calls BETWEEN these functions,
inside this module, are made directly by their own short name, not through
that forward - the two functions this file calls that still live in
C<Tira::CLI> (C<_populate_column_required_actions>, C<_record_touches_any>,
themselves one-line forwards to C<Tira::CLI::Records>/C<Tira::CLI::Serve>)
are the only calls here that cross back out, and they are qualified.

The four guards that run on every C<move> (C<_column_chain_violation>,
C<_column_required_action_violation>, C<_unjudged_answer_violation>,
C<_column_entry_required_action_violation>), the bookkeeping that follows a
successful one (C<_apply_column_required_actions>, C<_remind_one_at_a_time>,
C<_reset_linked_tasks_on_return>), and the smaller helpers only they call
(C<_columns_for>, C<_unmet_in_column>, C<_outstanding_here>,
C<_populate_entry_required_actions>, C<_item_is_done>, C<_first_line>) are
documented in full in C<Tira::CLI>'s own POD, deliberately left there: t/430
asserts C<=head2 The four guards on the move path> is still in that file's own
text, since a reader following the move path opens the index first.

=head1 SEE ALSO

L<Tira::CLI>

=cut

1;
