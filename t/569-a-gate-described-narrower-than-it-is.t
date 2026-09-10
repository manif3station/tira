#!/usr/bin/env perl
# TKT-627. Three documents say the unjudged-answer gate is scoped to the
# column an answer was given in. The gate is card-wide, and always has been.
#
# WHAT THE CODE DOES. _unjudged_answer_violation (lib/Tira/CLI/Move.pm since
# TKT-1041 lifted the move-path guards out of lib/Tira/CLI.pm, which now only
# carries a one-line forward of the same name) refuses a forward move while
# ANY unjudged answer sits on the card:
#
#     my @unjudged = grep {
#         $_->{answer} && !$_->{discarded_at} && !( $_->{answer}{mark} // '' );
#     } @{ $current->{questions} // [] };
#
# There is no column in that filter, and there could not be: an answer record
# is { text, author, answered_at, read_at, mark } and carries no column at
# all. So the documented behaviour is not merely absent, it is unrepresentable
# without a new field.
#
# WHICH WAY TO FIX IT, and the card decided this before I did. Making the code
# column-scoped means stamping a column onto every answer at answer time and
# leaves every answer written before that change unscoped for ever. Correcting
# three sentences describes a defensible gate - any unjudged answer holds the
# card, everywhere - and costs nothing. So the documents move.
#
# WHY A TEST RATHER THAN JUST AN EDIT. The sentences were written in good
# faith and drifted from the code; nothing noticed for a year. This holds both
# ends: the docs must not re-acquire the column claim, and the code must not
# quietly become column-scoped while the docs say otherwise.
#
# WHERE THE BEHAVIOUR IS PROVED. Not here. t/407 owns this gate's behaviour,
# and the card-wide scenario - answer in one column, refused leaving a later
# one - was added there rather than duplicated into this file, which reads
# source and documents only. Splitting them the other way would put one
# decision in two places, which is the fault t/566 was written to catch.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI;

sub doc {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- the code's own answer, read rather than assumed ------------------------

{
    # TKT-1041 lifted this gate's own body into Tira::CLI::Move; CLI.pm now
    # carries only a one-line forward of the same name.
    my $cli = Suite::cli_source('Move.pm');
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $cli, qr/\S/, 'the command surface is there to be read' );

    my ($gate) = $cli =~ /(sub\s+_unjudged_answer_violation\b.*?\n\})/s;
    ok( defined $gate, 'the unjudged-answer gate was found, to read what it filters on' )
      or BAIL_OUT('the gate moved - update this pattern rather than deleting the assertion');

    like( $gate, qr/\$current->\{questions\}/,
        'it reads the whole card\'s questions' );

    # Comments stripped: the gate explains the column INDEX comparison it uses
    # for forward-only, so the word appears in prose while the filter itself
    # has nothing to do with which column an answer came from.
    my ($filter) = $gate =~ /(my\s+\@unjudged\s*=\s*grep\s*\{.*?\}\s*\@\{[^;]*;)/s;
    ok( defined $filter, 'the unjudged filter itself was found' );
    # non-empty is the whole claim: a denial against an empty capture passes
    # for the wrong reason, which is what t/147 exists to catch.
    like( $filter, qr/\S/, 'the filter has text in it to deny things about' );
    unlike( $filter, qr/column/i,
        'and it filters on answered, not-discarded and unmarked - with no column '
          . 'anywhere in it, which is what card-wide means' );
}

# --- and the data model could not support the documented behaviour ---------
#
# The decisive fact. A column-scoped gate needs to know which column an answer
# was given in, and nothing records it.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the denial below needs a real subject.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    # Spans to the record's own close rather than the first brace: the fields
    # include $args{author}, so a [^}]* pattern stops inside it and never
    # reaches answered_at at all - which is how this assertion first failed
    # for a reason that had nothing to do with what it was testing.
    my ($written) = $engine =~
      /(\$entry->\{answer\}\s*=\s*\{.*?\n\s*\};)/s;
    ok( defined $written, 'the answer record as it is written was found' );
    # non-empty is the whole claim, for the same reason as the filter above.
    like( $written, qr/\S/, 'the record has fields in it to deny a column among' );
    unlike( $written, qr/column/,
        'an answer carries no column, so a column-scoped gate is not merely '
          . 'unimplemented but unrepresentable without a new field' );
}

# --- nor may the code's own commentary ------------------------------------
#
# Found only when the document sweep was widened past the three files the card
# named: the comment directly above the gate said "a card does not leave the
# column an answer was given in", which is where the three documents were
# written from. A guard that watches the copies and not the original would
# have let the whole thing be reintroduced from source.

{
    my $cli = Suite::cli_source('CLI.pm');
    # non-empty is the whole claim: the denial below needs a real subject.
    like( $cli, qr/\S/, 'the command surface is there to be read' );
    unlike( $cli, qr/does not leave the\s+#?\s*column an answer was given in/is,
        "the gate's own comment does not describe it as column-scoped - the "
          . 'sentence the three documents were written from' );
}

# --- so no document may claim the gate is scoped to a column ---------------

my %DOCUMENTS = (
    'docs/POLICIES.md' => 'the rule table, where somebody declaring the policy reads',
    'SKILLS.md'        => 'the use-case prose, where somebody learning the board reads',
    'Changes'          => 'the 4.52 entry, where the claim was first written down',
);

for my $path ( sort keys %DOCUMENTS ) {
    my $text = doc($path);
    # non-empty is the whole claim: a denial against an unreadable file passes
    # for the wrong reason.
    like( $text, qr/\S/, "$path is there to be read" );

    # Whitespace-tolerant, because the same claim is line-wrapped differently
    # in each file and phrased two ways - "move forward out of" in two of
    # them, "does not leave" in the third. A pattern matching only one
    # wording would have reported two of the three as already correct.
    unlike( $text, qr/the column an answer was\s+given in/is,
        "$path does not claim the gate is scoped to the answer's column - "
          . $DOCUMENTS{$path} );
}

done_testing();

__END__

=head1 NAME

569-a-gate-described-narrower-than-it-is.t - the unjudged-answer gate is documented as what it is

=head1 DESCRIPTION

TKT-627. C<_unjudged_answer_violation> refuses a forward move while any
unjudged answer sits on the card, with no column in its filter - and an answer
record carries no column, so a column-scoped gate could not be written without
a new field. Three documents said otherwise. Correcting them describes a
defensible gate and costs nothing, where changing the code would need that
field and would leave every existing answer unscoped. This holds both ends: the
documents must not re-acquire the claim, and the filter must not quietly gain a
column while they say it has none.

=cut
