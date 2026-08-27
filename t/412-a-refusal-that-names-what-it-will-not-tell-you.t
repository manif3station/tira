#!/usr/bin/env perl

# The refusal lists what is blocking a card and then tells you to use an id it
# did not give you.
#
#   return "Cannot move $args{ref} out of $from - required actions not done: "
#     . join( '; ', map { $_->{item} } @unmet ) . ".\n"
#     . "  Mark them done, then move again:  d2 tira.required-action.update "
#     . "--ref $args{ref} --id REQ-NNN --status done\n";
#
# Two faults in four lines. @unmet holds the entries and each carries its id;
# the map takes the text and drops the id on the floor. And the command it
# hands back carries the literal REQ-NNN, so acting on the refusal means
# running required-action.list, matching each item by its text, and reading off
# the id - on a card with 75 items across a dozen columns, by eye.
#
# That cross-reference has already put proofs against the wrong ids twice on
# this board.
#
# Measured, not imagined: refusing ZSD-288 out of planning produced ONE line of
# over a thousand characters covering 12 items whose own texts contain
# semicolons, backticks and inline command examples - joined with '; ' into
# prose that has to be re-parsed by eye to see where one item ends.
#
# The shape to copy is already in the same file. TKT-591's entry gate, written
# today, ends its refusal like this:
#
#     REQ-004  Verify all details in the card
#   Mark one, then move again:
#     d2 tira.required-action.update --ref EGT-001 --id REQ-004 --status done ...
#
# One item per line, id beside text, and a real id in the command. This file
# holds the three older guards to what the fourth one already does.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T22:15:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Refusals that help', dir         => $root,
    members       => ['ada'],              columns     => ['backlog, planning, review, done'],
    sow_prefix    => 'RHS',                epic_prefix => 'RHE',
    ticket_prefix => 'RHT',                author      => 'ada',
);

# Item texts carrying the punctuation the real ones do - a semicolon inside an
# item is what turns a '; '-joined list into something nobody can parse.
my @ITEMS = (
    'Assign yourself to the card; nobody else can be assumed',
    'Link the related tasks to this card',
    'Run `prove -lr t` and record what it said',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'planning', author => 'ada',
    required_action => [@ITEMS],
);

# A second column with its own items, so the card carries more than one
# column's worth - which is the whole reason required-action.list cannot answer
# "what is blocking me here". On the board this was measured against, one card
# held 75 items across a dozen columns and three of them were the ones in the
# way.
$tira->column_update(
    project => $root, type => 'ticket', name => 'backlog', author => 'ada',
    required_action => [ 'Something backlog wanted', 'And another thing backlog wanted' ],
);

sub move {
    my (%opt) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [
                '--type', 'ticket', '--ref', $opt{ref}, '--column', $opt{column},
                '--author', 'ada', '-o', 'toon',
            ],
        );
    };
    select $old;
    return ( $tira->record_show( project => $root, type => 'ticket', ref => $opt{ref} ), $said // '' );
}

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with three things to do', author => 'ada',
);
move( ref => $card->{ref}, column => 'planning' );
my ( $held, $refusal ) = move( ref => $card->{ref}, column => 'review' );

is( $held->{column}, 'planning', 'the card is refused and stays where it was - the gate itself is not in question' );

my $current = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
my @unmet = grep { ( $_->{column} // '' ) eq 'planning' } @{ $current->{required_items} // [] };
is( scalar @unmet, 3, 'and it is blocked by the three items the column declared' );

# --- every blocking item is named with the id needed to act on it -------------

for my $item (@unmet) {
    like( $refusal, qr/\Q$item->{id}\E/,
        "the refusal names $item->{id}, which is what tira.required-action.update asks for" );
}

# --- one item per line, so a dozen items do not become a wall ----------------

my @item_lines = grep { /REQ-\d+/ } split /\n/, $refusal;
is( scalar @item_lines, 3,
    'each blocking item is on its own line rather than joined into one - item texts contain semicolons of their own' );

unlike( $refusal, qr/\Q$ITEMS[0]\E; \Q$ITEMS[1]\E/,
    'and they are not semicolon-joined into prose that has to be re-parsed by eye' );

# --- the count is stated, so a reader knows what they face before reading ----

like( $refusal, qr/\b3\b/,
    'the refusal states how many items are blocking, so the size of the job is known before the list is read' );

# --- the suggested command carries a real id, not a placeholder --------------

unlike( $refusal, qr/REQ-NNN/,
    'the command handed back does not carry the REQ-NNN placeholder' );

my ($suggested) = $refusal =~ /(d2 tira\.required-action\.update [^\n]+)/;
ok( $suggested, 'the refusal ends with a required-action.update command to run' );

SKIP: {
    skip 'no suggested command to check', 2 if !$suggested;
    like( $suggested, qr/--id REQ-\d+/,
        'and it carries a real id from the list above it' );
    my ($given_id) = $suggested =~ /--id (REQ-\d+)/;
    ok( ( grep { $_->{id} eq ( $given_id // '' ) } @unmet ),
        'which is one of the items actually blocking this card, not an id from somewhere else on it' );
}

# --- the same question, answerable without being refused first ---------------
#
# The other half of the card. required-action.list returns every item on a card
# across every column - 75 on the board this was measured on - so the only way
# to learn what is blocking you today is to try a move and be refused. That is a
# strange shape for a system whose whole purpose is telling an agent what to do
# next.

move( ref => $card->{ref}, column => 'backlog' );
move( ref => $card->{ref}, column => 'planning' );

my $everything = $tira->required_item_list(
    project => $root, type => 'ticket', ref => $card->{ref},
);
cmp_ok( scalar @{$everything}, '>', 3,
    'required-action.list returns more than the items gating this column, which is why it does not answer the question' )
  or diag( 'the card carries only ' . scalar( @{$everything} ) . ' items, so this board cannot show the distinction' );

my $blocking = eval {
    Tira::CLI::_outstanding_here( $tira,
        project => $root, type => 'ticket', ref => $card->{ref} );
};
is_deeply(
    [ sort map { $_->{id} } @{ $blocking // [] } ],
    [ sort map { $_->{id} } @unmet ],
    'asking what is outstanding here answers with exactly the items a move would be refused for' )
  or diag( $@ ? "it refused: $@" : 'it answered with something else' );

done_testing();

__END__

=head1 NAME

t/412-a-refusal-that-names-what-it-will-not-tell-you.t - the move refusal must
give the ids it tells the caller to use, and the same question must be
answerable without being refused first

=head1 DESCRIPTION

C<_column_required_action_violation> builds its message with
C<join( '; ', map { $_->{item} } @unmet )> and then suggests a command
containing the literal C<REQ-NNN>. The ids are in C<@unmet> the whole time.

Acting on that refusal therefore means running C<required-action.list>, finding
each item by matching its text, and reading off the id - and that
cross-reference has already produced proofs recorded against the wrong ids
twice on this board. Measured on a real card: 12 items, one line, over a
thousand characters, item texts containing their own semicolons and backticks.

The second half is the absence of a way to ask before moving.
C<required-action.list> returns every item on the card across every column, so
the only way to discover what is blocking a move is to attempt one and be
refused.

The shape being asked for already exists: TKT-591's entry-required-action gate,
written the same day, prints one item per line with its id and ends with a
command carrying a real one. These assertions hold the older guards to what the
newer one already does.

=cut
