#!/usr/bin/env perl
# Adding a column does not silently narrow a rule.
#
# His complaint, and the measurement behind it. He had to spot a card parked in
# tests-red for six hours himself, and the reason nothing said so was that
# checklist-idle and card-duration were declared for the implement column only,
# on a board with five working columns. A card could sit untouched in four of
# them for ever.
#
# That is this project's own written warning happening to it: a rule naming one
# column stops covering the board the moment somebody adds another, silently,
# which is the shape of every check found not firing here. Nobody did anything
# wrong - the columns were added later, and a policy that was complete when it
# was written quietly stopped being complete.
#
# What is reported is a working column that no column-scoped policy mentions at
# all, rather than every rule that does not cover every column. The wider
# version was written first and running the review against this project's own
# board killed it: it demanded gate-missing be declared for tests-red, where a
# card has no gate to show yet, and nothing could have answered that.
#
# His words for the fix: set up the correct policies yourself, then I come round
# behind and check. Doing that once is not the deliverable. The gap reopens
# every time a column is added, so what is built here is the noticing.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Shipped qw(runnable_ok);
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Watched', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);

sub reported {
    my ($store) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'column-unwatched' } @{ $pass->{violations} } ];
}

# --- a board that has not asked hears nothing ---------------------------------------

is( scalar @{ reported( File::Spec->catdir( $tmp, 'quiet' ) ) }, 0,
    'a board that has not declared the rule hears nothing' );

$tira->policy_add( project => $root, rule => 'column-unwatched',
    action => 'bridge-reminder' );

# --- a column-scoped rule that covers every working column is silent -------------------

$tira->policy_add( project => $root, rule => 'checklist-idle',
    column => $_, age => '2h', action => 'bridge-reminder' )
  for qw(implement verify);

is( scalar @{ reported( File::Spec->catdir( $tmp, 'covered' ) ) }, 0,
    'a rule declared for every working column says nothing' );

# --- then somebody adds a column ------------------------------------------------------
#
# The moment the gap opens. Nobody did anything wrong: the policy was complete
# when it was written.

$tira->column_add( project => $root, type => 'ticket', name => 'document',
    after => 'verify' );

my $found = reported( File::Spec->catdir( $tmp, 'gap' ) );
is( scalar @{$found}, 1, 'adding a column is noticed' );
like( $found->[0]{detail}, qr/document/, 'naming the column nothing watches' );
like( $found->[0]{detail}, qr/checklist-idle/,
    'and the rule that is declared for the others, so there is something to extend' );

# --- and closing the gap silences it ---------------------------------------------------

{
    $tira->policy_add( project => $root, rule => 'checklist-idle',
        column => 'document', age => '2h', action => 'bridge-reminder' );
    is( scalar @{ reported( File::Spec->catdir( $tmp, 'closed' ) ) }, 0,
        'declaring the rule for the new column closes it' );
}

# --- a rule nobody scoped by column is not this ------------------------------------------
#
# A board-wide rule covers every column by construction. Reporting one would be
# telling an agent to narrow something that is already as wide as it can be.

{
    my $wide = File::Spec->catdir( $tmp, 'wide' );
    my $other = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $other->project_new(
        name => 'Wide', dir => $wide, members => ['claude'],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'WDS', epic_prefix => 'WDE', ticket_prefix => 'WDT',
    );
    $other->policy_add( project => $wide, rule => 'column-unwatched',
        action => 'bridge-reminder' );
    $other->policy_add( project => $wide, rule => 'conversation-not-folded',
        action => 'bridge-reminder' );

    my $pass = $other->police_pass( project => $wide,
        store => File::Spec->catdir( $tmp, 'wide-store' ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'column-unwatched' } @{ $pass->{violations} } ], [],
        'a rule declared board-wide is not reported, because it already covers everything' );
}

# --- which rule belongs where is not this rule's business -------------------------------------
#
# The version of this that shipped first asked whether every column-scoped rule
# covered every working column, and running the review it also ships against
# this project's own board showed what that costs: gate-missing is declared for
# verify, push and done, deliberately, because a card in tests-red has nothing
# to show a gate yet. The wider check demanded it be declared for tests-red too,
# and there would have been no way to answer that - a violation nobody can close
# is the complaint mt5-ai made about card-damaged, arriving from the other side.
#
# So the question is the narrow one: a column that no column-scoped policy
# mentions at all. That is not a judgment about which rule belongs where, it is
# a place work happens that the policies do not know exists.

{
    $tira->policy_add( project => $root, rule => 'gate-missing',
        column => 'done', action => 'bridge-reminder' );
    is_deeply( reported( File::Spec->catdir( $tmp, 'ending' ) ), [],
        'a rule deliberately scoped to some columns and not others is not second-guessed' );

    # And the ending column is never demanded either: work does not happen
    # there, so a rule watching for idleness in it would report every finished
    # card for ever.
    my $ending = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'ending-detail' ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { ( $_->{detail} // '' ) =~ /\bdone\b/ }
          grep { $_->{rule} eq 'column-unwatched' } @{ $ending->{violations} } ],
        [], 'and the finished column is never asked for' );
}

# --- a board that says where work ends is asked, rather than guessed at ----------------------
#
# `done` is the fallback for a board that has marked nothing, not the answer. A
# board whose work ends somewhere it named must have that column left out too -
# otherwise the first thing this rule would say to a board with a `shipped`
# column is that nothing watches it, which is true and useless.

{
    my $named = File::Spec->catdir( $tmp, 'named-ending' );
    my $board = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $board->project_new(
        name => 'Named Ending', dir => $named, members => ['claude'],
        columns => ['backlog, implement, shipped'],
        sow_prefix => 'NES', epic_prefix => 'NEE', ticket_prefix => 'NET',
    );
    # On every board, because columns are per board and so is the marking. A
    # board that says where tickets end and leaves its epics unmarked has said
    # nothing about where epics end, and this asks all three - the same reading
    # card-unassigned takes, after an epic finishing somewhere the tickets do
    # not was judged against the wrong list.
    $board->column_update( project => $named, type => $_, name => 'shipped', terminal => 1 )
      for qw(sow epic ticket);
    $board->policy_add( project => $named, rule => 'column-unwatched',
        action => 'bridge-reminder' );
    $board->policy_add( project => $named, rule => 'checklist-idle',
        column => 'implement', age => '2h', action => 'bridge-reminder' );

    my $pass = $board->police_pass( project => $named,
        store => File::Spec->catdir( $tmp, 'named-store' ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'column-unwatched' } @{ $pass->{violations} } ], [],
        'a column the board marked as its ending is not reported as unwatched' );
}

# --- and it takes neither a column nor a period -------------------------------------------
#
# It is about the columns OTHER policies name, so scoping it to one column would
# be asking it to watch a single place for something only visible across the
# whole board - and a gap is a gap the moment the column exists, not after it
# has been open for an hour. Both are refused when they are set, rather than
# stored and quietly ignored, which is the fault t/185 is about.

{
    ok( !eval {
            $tira->policy_add( project => $root, rule => 'column-unwatched',
                column => 'implement', action => 'bridge-reminder' );
            1;
        },
        'a column scope is refused, because the rule is about every column at once' );
    like( $@, qr/column/i, 'and says so' );

    ok( !eval {
            $tira->policy_add( project => $root, rule => 'column-unwatched',
                age => '1h', action => 'bridge-reminder' );
            1;
        },
        'and a period is refused, because a gap is a gap the moment it opens' );
    like( $@, qr/age|period|wait/i, 'and says so' );

    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Not a board' )->{ref};
    ok( !eval {
            $tira->policy_add( project => $root, rule => 'column-unwatched',
                ref => $card, action => 'bridge-reminder' );
            1;
        },
        'and so is a card scope, for the same reason board-still refuses one' );
    like( $@, qr/card|scope|whole board/i, 'and says so' );
}

# --- and one place to read the whole set --------------------------------------------------
#
# His words: set up the correct policies yourself, then I come round behind and
# check. Checking means reading it somewhere, and reading it out of policy.list
# means holding the catalogue in your head to see what is missing.

{
    # A rule refused on purpose, because the three states are the point: a
    # reviewer has to be able to tell a decision from an omission, which is the
    # distinction the declined list exists for.
    $tira->policy_decline( project => $root, rule => 'commit-without-card',
        reason => 'this board is not the repository, so a commit here names nothing',
        author => 'claude' );

    my $review = $tira->policy_review( project => $root );

    ok( scalar @{ $review->{declared} }, 'the review lists what is declared' );
    ok( exists $review->{unanswered}, 'and what nobody has decided either way' );

    my ($refused) = grep { $_->{rule} eq 'commit-without-card' } @{ $review->{declined} };
    ok( $refused, 'a rule that was refused appears among the declined' );
    like( $refused->{reason}, qr/repository/,
        'with the reason somebody gave, so a decision can be told from an omission' );

    my ($idle) = grep { $_->{rule} eq 'checklist-idle' } @{ $review->{declared} };
    ok( $idle, 'a declared rule appears with its name' );
    is_deeply( [ sort @{ $idle->{columns} } ], [qw(document implement verify)],
        'and the columns it covers, so a gap can be seen rather than worked out' );

    # Every rule in the catalogue is accounted for exactly once, which is what
    # makes this a review rather than a listing.
    # Declined carries a reason with it, so it is a list of records rather than
    # of names. Counting it as names put HASH(0x...) in the tally, and the
    # assertion only passed before because this board had declined nothing -
    # a check that cannot fail until somebody gives it data.
    my %seen;
    $seen{ $_->{rule} }++ for @{ $review->{declared} }, @{ $review->{declined} };
    $seen{$_}++ for @{ $review->{unanswered} };
    is_deeply( [ sort keys %seen ], [ sort @{ Tira::policy_rules() } ],
        'and every rule in the catalogue is accounted for, once' );
}

# --- and an agent, or he, can actually type it -----------------------------------------------
#
# A review nobody can run is a data structure. mt5-ai have reported three command
# families they could not find because they were documented outside the manual
# they had captured, so it is named in both.

{
    require Tira::CLI;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'policy.review', tira => $tira,
            argv => [ '-o', 'json' ] ) };
    };
    is( $status, 0, 'the command runs' ) or diag($err);

    my $answered = Tira::json_decode($out);
    ok( scalar @{ $answered->{declared} },   'and answers with what is declared' );
    ok( exists $answered->{unanswered},      'and what is left to decide' );
}

runnable_ok( File::Spec->catfile(qw(skills policy cli review)),
    'and it ships as an entrypoint an agent can reach' );

for my $document (qw(SKILLS.md docs/commands.md)) {
    open my $fh, '<', $document or die "$document: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr/tira\.policy\.review/, "$document names it" );
}

done_testing;

__END__

=head1 NAME

187-a-column-nobody-is-watching.t - adding a column does not silently narrow a rule

=head1 DESCRIPTION

C<checklist-idle> and C<card-duration> were declared for one column on a board
with five, so a card could sit untouched in four of them for ever - which is how
a card came to be parked in C<tests-red> for six hours with nothing saying so.
The policy was complete when it was written; a column added later narrowed it
silently.

C<column-unwatched> reports a rule that some columns are scoped to and others
are not, naming the rule and the column it no longer covers. A rule declared
board-wide is not reported, because it already covers everything.

C<tira.policy.review> answers the other half: every rule in the catalogue,
declared with its columns, declined with its reason, or unanswered - in one
place, so a gap can be seen rather than worked out.

=cut
