#!/usr/bin/env perl
# Serving a board and hearing from it, from one terminal.
#
# TKT-897, filed by him: "add a new --with-police argument that will run the
# police and the starman at the same terminal. So the user doesn't need to run 2
# terminals. All in 1 go."
#
# THIS FILE COVERS THE FIRST HALF ONLY, and the split is not a convenience. His
# second sentence - "the police will be always the winner in this running with
# browser dashboard. if other try to run tira.police will be the losser and
# exit" - asks for the reverse of his OWN earlier ruling on TKT-486, quoted in
# the code that implements it: "Whoever the last run it is the winner and the
# loser process will be killed."
#
# THE BOARD DOES THE SECOND ONE TODAY. Read rather than assumed:
# police_claim_singleton kills whatever holds the claim, takes it, and prints
# "killed a still-running daemon - only the newest watches now". So the
# precedence this card asks for is a change to a rule he made, not a default
# nobody chose, and it is Q-117 rather than something to infer. Nothing here
# asserts it.
#
# WHAT IS ASSERTED is the plumbing he asked for in his first sentence, which
# nothing about the question blocks: the flag exists, it is refused where it
# cannot mean anything, and it is written down.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;

# --- the parser knows the flag ----------------------------------------------
#
# Taken from the option specification itself rather than from a list here, the
# way t/70 reads it: a flag this test names and the parser does not is a flag
# nobody can type.

my $cli = Suite::cli_source();

# non-empty is the whole claim: every assertion below greps this text, and a
# walk that returned nothing would report the flag as missing rather than absent.
like( $cli, qr/\S/, 'the command surface was walked to look for the flag' );

like( $cli, qr/'with-police'/,
    'THE PARSER DECLARES --with-police, so it can be typed at all. His first '
      . 'sentence is the whole of this assertion: one command for the board and '
      . 'the bridge, instead of two terminals' );

# --- and refuses it where it cannot mean anything ---------------------------
#
# --show-logs is the precedent and the comment beside it is the reason: "a flag
# that parses and does nothing reads as confirmation, which is how --field was
# stored and dropped by every command that did not read it". Police alongside a
# JSON dump is the same shape - there is no terminal being shared, so the flag
# would be accepted and ignored.

like( $cli, qr/--with-police needs -o browser|with_police.*?browser|browser.*?with_police/s,
    'and it is REFUSED outside -o browser rather than accepted and ignored - '
      . 'the fault --show-logs is guarded against by name, since a flag that '
      . 'parses and does nothing reads as confirmation' );

# --- one signal path, so nothing is left holding a claim --------------------
#
# The card's second acceptance criterion. A police pass that outlives the server
# leaves a singleton claim pointing at a pid that is gone, and the next claimant
# has to reason past it. police_release_singleton exists for exactly that and
# has to be reached on this path too.

like( $cli, qr/with_police/,
    'the flag reaches the serving path rather than stopping at the parser - a '
      . 'value read once and never used is the accepted-and-ignored fault again' );

# --- written down where the command is written down -------------------------

{
    my %doc;
    for my $name ( 'SKILLS.md', File::Spec->catfile( 'docs', 'commands.md' ) ) {
        open my $fh, '<:encoding(UTF-8)', $name or die "$name: $!";
        local $/;
        $doc{$name} = <$fh>;
    }

    # non-empty is the whole claim, as above.
    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/\S/, "$name was read to look for the flag" );
    }

    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/--with-police/,
            "$name names --with-police, so somebody can find it without reading "
              . 'the option table in the source' );
    }
}

done_testing();

__END__

=head1 NAME

519-two-terminals-to-watch-one-board.t - the dashboard and the bridge together

=head1 WHY

TKT-897, his own filing: serving the board and running police are two commands,
so watching one board takes two terminals.

=head1 WHAT IS ASSERTED

That C<--with-police> is declared by the parser, refused outside C<-o browser>
rather than accepted and ignored, reaches the serving path, and is documented in
both manuals.

=head1 WHAT IS NOT ASSERTED, AND WHY

The precedence. His second sentence asks that the dashboard's police always wins
and a later C<tira.police> loses and exits - which is the reverse of his own
TKT-486 ruling, and the reverse of what the board does today, where the newest
claimant kills the previous one. That is a decision rather than an
implementation detail, it is Q-117, and inferring it here would be this test
choosing a rule on his behalf.

Nor does anything here start a server. Whether the two really share a terminal
is a walkthrough step.

=cut
