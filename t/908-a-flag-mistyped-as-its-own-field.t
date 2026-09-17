#!/usr/bin/env perl
# A write flag that disagrees with its stored field should say so when it
# is mistyped, not just refuse.
#
# TKT-908, EPC-007. docs/commands.md already names four write/read pairs -
# gate --details/details, evidence --summary/summary, checklist --item/item,
# comment --text/body - and comment is the only one where the write flag and
# the stored field name DISAGREE. MEASURED WHILE WORKING TKT-753: t/141, t/86
# and t/523 all called comment_add with `body => ...` instead of `text => ...`
# - the engine only reads $args{text}, so all three stored an EMPTY comment,
# for as long as they existed, and passed anyway (the rules they exercise
# only care that a comment exists). TKT-753 already fixed the SILENCE -
# comment_add refuses a body that says nothing - but the message a caller
# who wrote `body => ...` gets back is "A comment needs some text", which is
# true and no help at all: they believe they supplied one. This card makes
# the refusal say which write-side flag carries the value they gave it under
# the read-side field's own name.
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
    my $tira  = Tira->new;
    $tira->project_new(
        name => 'Flag', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'FLS', epic_prefix => 'FLE', ticket_prefix => 'FLT',
    );
    return ( $tira, $root );
}

sub card {
    my ( $tira, $root, $title ) = @_;
    return $tira->create_record( project => $root, type => 'ticket',
        title => $title, description => 'x', author => 'claude' )->{ref};
}

# --- the mistake this card is about ------------------------------------------

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Mistyped' );

    my $ok = eval { $tira->comment_add( project => $root, ref => $ref,
            author => 'claude', body => 'Look at this example, it is the best evidence on the card' ); 1 };
    my $why = $@ // '';

    ok( !$ok, 'passing body => ... (the STORED field name) instead of text => ... '
          . 'is still refused - the plain "needs some text" refusal from TKT-753 '
          . 'must not regress' );

    like( $why, qr/--text/,
        'AND THE REFUSAL NAMES --text. The caller passed the read-side field '
          . 'name where the write-side flag belongs; today they get "A comment '
          . 'needs some text" back, which is true and no help at all because '
          . 'they believe they supplied one' );

    is( scalar @{ $tira->comment_list( project => $root, ref => $ref ) }, 0,
        'and nothing was written - same as any other refused comment' );
}

# --- a genuinely empty --text is still the plain refusal, not this one ------
#
# The two cases must stay distinguishable: a caller who truly supplied
# nothing gets the plain message, not one pointing at a flag they never used.

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Genuinely empty' );

    my $ok = eval { $tira->comment_add( project => $root, ref => $ref,
            author => 'claude', text => '' ); 1 };
    my $why = $@ // '';

    ok( !$ok, 'an empty --text is still refused' );

    unlike( $why, qr/--text/,
        'but the message does NOT claim a --text was passed under the wrong '
          . 'name - a caller who supplied nothing at all gets the plain '
          . 'refusal, distinguishable from the mistyped-flag case above' );

    like( $why, qr/text/i, 'and it still says what is missing' );
}

# --- no working call changes behaviour ---------------------------------------

{
    my ( $tira, $root ) = board();
    my $ref = card( $tira, $root, 'Ordinary' );

    my $comment = $tira->comment_add( project => $root, ref => $ref,
        author => 'claude', text => 'a real comment' );

    is( ( $comment->{body} // $comment->{text} ), 'a real comment',
        'an ordinary --text call is completely unaffected' );
}

done_testing();

__END__

=head1 NAME

908-a-flag-mistyped-as-its-own-field.t - a stored field name passed where a
write flag belongs gets a refusal that says so

=head1 WHY

TKT-908. C<comment.add> takes C<--text> and stores it as C<body> - the only
one of four write/read pairs named in F<docs/commands.md> where the flag and
the stored field disagree. Three fixtures in this repository called
C<comment_add> with C<< body => ... >> instead of C<< text => ... >>, storing
an empty comment for as long as they existed and passing anyway. TKT-753
already fixed the silence; this card fixes the message, so a caller who made
that exact mistake is told which flag carries the value they gave under its
stored name, instead of being told only that they gave nothing.

=head1 WHAT IS ASSERTED

That C<< body => ... >> without C<text> is still refused, that the refusal
names C<--text>, that a genuinely empty C<--text> keeps the plain refusal
(the two cases stay distinguishable), and that no working call changes
behaviour.

=cut
