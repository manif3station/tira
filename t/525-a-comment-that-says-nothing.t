#!/usr/bin/env perl
# A comment with no comment in it.
#
# TKT-753, EPC-007. `comment.add --text ''` is accepted, stored, and printed
# back. `comment_add` writes
#
#     body => $args{text} // '',
#
# with no check at all, and it is ALONE IN THAT among the commands it sits
# beside. Every sibling already refuses content that says nothing:
#
#     evidence_add        "Evidence summary is required"
#     warning_add         "A warning message is required"
#     question_answer     "An answer needs some text"
#     checklist_add       "Checklist item is required"
#     required_item_add   "Required item is required"
#
# HALF OF THIS CARD WAS ALREADY FIXED WHEN IT WAS PICKED UP, and that is worth
# writing down rather than quietly dropping. It was filed claiming an empty
# comment satisfied `discard-unexplained`, so the rule demanding a reason
# accepted none. Measured in a container on 2026-09-04 the rule FIRES:
#
#     discard-unexplained on a card with ONLY empty comments
#       -> "discarded with no reason given - leave a comment saying why..."
#     control: a card with a REAL comment -> silent, as it should be
#
# TKT-638, TKT-777 and TKT-778 rebuilt that branch after this card was filed -
# they were about WHICH comment explains a discard - and closed the hole on the
# way past. It now greps `( $_->{body} // '' ) =~ /\S/`.
#
# So the harm is smaller than the card claims and is not nothing: an empty
# comment is a record that says nothing, returned by comment.list and rendered
# by the dashboard, so a reader counting comments on a card gets a number that
# overstates what was said.
#
# BOTH HALVES ARE ASSERTED HERE. The refusal is the fix; the rule's behaviour is
# a control, because the two now agree about what counts as saying something and
# a change to either that broke that agreement is the failure worth catching.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'board' );
    my $store = File::Spec->catdir( $tmp, 'police' );
    my $tira  = Tira->new;
    $tira->project_new(
        name => 'Empty', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'EMS', epic_prefix => 'EME', ticket_prefix => 'EMT',
    );
    return ( $tira, $root, $store );
}

sub card {
    my ( $tira, $root, $title ) = @_;
    return $tira->create_record( project => $root, type => 'ticket',
        title => $title, description => 'x', author => 'claude' )->{ref};
}

# --- a real comment still works ----------------------------------------------
#
# The control, and it comes first deliberately: a refusal that also broke
# ordinary commenting would be a far worse defect than the one it fixed, and
# every card on this board is commented.

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Ordinary' );

    my $comment = $tira->comment_add( project => $root, ref => $ref,
        author => 'claude', text => 'set aside, superseded by EMT-002' );

    is( ( $comment->{body} // $comment->{text} ), 'set aside, superseded by EMT-002',
        'an ordinary comment is stored with its body intact - the control, since '
          . 'a refusal that caught real comments would be the worse defect' );

    is( scalar @{ $tira->comment_list( project => $root, ref => $ref ) }, 1,
        'and it is the one comment on the card' );
}

# --- and a comment with nothing in it is REFUSED -----------------------------

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Empty' );

    # any failure is what this means: the only intended way out is the refusal,
    # and a failure for another reason is equally a comment that was not stored.
    my $ok  = eval { $tira->comment_add( project => $root, ref => $ref,
            author => 'claude', text => '' ); 1 };
    my $why = $@ // '';

    ok( !$ok, 'AN EMPTY --text IS REFUSED. Today it is stored: comment_add '
          . 'writes body => $args{text} // \'\' with no check, exits 0, and '
          . 'prints the comment back - which reads as confirmation' );

    like( $why, qr/text|comment/i,
        'and the refusal says what is missing, rather than failing somewhere '
          . 'further in about a body that is not there' );

    is( scalar @{ $tira->comment_list( project => $root, ref => $ref ) }, 0,
        'and nothing was written - a refusal that stored the comment anyway '
          . 'would be the worst of both' );
}

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Whitespace' );

    my $ok = eval { $tira->comment_add( project => $root, ref => $ref,
            author => 'claude', text => "  \n\t " ); 1 };

    ok( !$ok, 'A WHITESPACE-ONLY --text IS REFUSED TOO. A space is not a smaller '
          . 'comment than none, which this codebase settled on TKT-585 for '
          . '--command/--proof: whitespace was cheaper than doing the work' );

    is( scalar @{ $tira->comment_list( project => $root, ref => $ref ) }, 0,
        'and nothing was written for that one either' );
}

# --- the rule and the command agree about what counts as saying something ----
#
# This half of the card is already fixed, and it is asserted as a CONTROL rather
# than as a claim about the change. The value is the agreement: comment_add is
# about to refuse what discard-unexplained already ignores, and if either side
# later relaxes its test they will disagree about the same string - which is the
# split that cost TKT-713 an engine and a browser answering differently.

{
    my ( $tira, $root, $store ) = board();
    $tira->policy_add( project => $root, rule => 'discard-unexplained',
        action => 'log-only', author => 'claude' );

    my $silent = card( $tira, $root, 'Discarded saying nothing' );
    $tira->record_discard( project => $root, ref => $silent, type => 'ticket',
        author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @said = map { join ' ', grep { defined && length } @{$_}{qw(message detail)} }
      @{ $pass->{violations} || [] };

    ok( scalar( grep { /no reason given/i } @said ),
        'discard-unexplained fires on a card discarded with nothing said - the '
          . 'rule this card was filed about, and it is no longer fooled: '
          . 'TKT-638/777/778 rebuilt that branch to grep for a body matching '
          . '\S, which is the same test comment_add is about to apply' )
      or diag( 'violations: ' . join( ' ;; ', @said ) );
}

{
    my ( $tira, $root, $store ) = board();
    $tira->policy_add( project => $root, rule => 'discard-unexplained',
        action => 'log-only', author => 'claude' );

    my $explained = card( $tira, $root, 'Discarded with a reason' );
    $tira->comment_add( project => $root, ref => $explained, author => 'claude',
        text => 'set aside: the defect it names was fixed by another card' );
    $tira->record_discard( project => $root, ref => $explained, type => 'ticket',
        author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @said = map { join ' ', grep { defined && length } @{$_}{qw(message detail)} }
      @{ $pass->{violations} || [] };

    ok( !scalar( grep { /no reason given/i } @said ),
        'and stays silent when a real reason was written - the control that '
          . 'makes the line above a measurement rather than a rule that fires '
          . 'on everything' )
      or diag( 'violations: ' . join( ' ;; ', @said ) );
}

# --- and a discard that carries no comment at all still works ----------------
#
# The risk the solution names. record_discard takes a --comment and passes it
# through, so a refusal in comment_add could break discarding for anybody who
# does not supply one. Asserted rather than assumed.

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Discarded with no comment' );

    my $ok = eval { $tira->record_discard( project => $root, ref => $ref,
            type => 'ticket', author => 'claude' ); 1 };
    my $why = $@ // '';

    ok( $ok, 'a discard with NO comment still works - comment_add is not reached '
          . 'when there is nothing to write, so refusing an empty body must not '
          . 'refuse the discard itself' )
      or diag("it died: $why");

    is( ( $tira->record_show( project => $root, ref => $ref, type => 'ticket' )
            ->{column} // '' ),
        'discard', 'and the card really is discarded' );
}

done_testing();

__END__

=head1 NAME

525-a-comment-that-says-nothing.t - an empty comment body is refused

=head1 WHY

TKT-753. C<comment_add> writes C<< body => $args{text} // '' >> with no check, so
C<comment.add --text ''> is stored, exits 0 and prints the comment back. It is
alone in that among its siblings - C<evidence_add>, C<warning_add>,
C<question_answer>, C<checklist_add> and C<required_item_add> all refuse content
that says nothing.

=head1 WHAT IS ASSERTED

That an ordinary comment is unaffected, which is the control; that an empty and
a whitespace-only body are both refused, that the refusal names what is missing,
and that nothing is written when it fires.

Then, as controls rather than as claims about this change: that
C<discard-unexplained> fires on a card discarded saying nothing and stays silent
when a reason was written. The card was filed claiming that rule accepted an
empty comment; it does not, since TKT-638/777/778 rebuilt the branch to grep for
a body matching C<\S>. What matters now is the B<agreement> - the command is
about to refuse exactly what the rule already ignores, and a later change to
either that broke that agreement is the failure worth catching.

Finally that a discard carrying no comment at all still works, which is the risk
the refusal introduces.

=head1 WHAT IS NOT ASSERTED

C<comment_update>. It has the same shape and a different question behind it -
whether blanking an existing comment is a legitimate edit - and widening this
card to cover it would turn a one-line fix into an argument.

=cut
