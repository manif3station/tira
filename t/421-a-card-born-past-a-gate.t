#!/usr/bin/env perl

# A card created straight into a column is born past that column's entry gate.
#
# TKT-681, from the owner's question on TSK-250: "Do the entry required action
# items apply to create new ticket command too? ... but where do they store the
# proof when there is no ticket?"
#
# That question settles the design. A required action's proof is a command and
# its output, and before the card exists there is nothing to run a command
# against - so creation cannot be blocked on one. His answer: create the card
# anyway, record the items as pending, and print a warning listing them.
#
# Two templates exist on every column. required_actions is what a card must do
# to LEAVE; entry_required_actions is what it must have done to be moved IN.
# The move path places both - the exit template through
# _populate_column_required_actions and the entry template through
# _populate_entry_required_actions, which is called at CLI.pm:2429 and 1068.
# The create path (CLI.pm:3340) reads only the exit template, under a comment
# saying it mirrors the move-in logic "exactly". It mirrored the function that
# does half the job.
#
# Reproduced before this file was written: a card moved in is refused and
# carries the entry item; a card created in is allowed, carries only the exit
# item, and its output mentions no required action at all.
#
# THE SECOND SILENCE IS OLDER THAN THE FIRST. The exit template has been seeded
# on create since TKT-439 and printed by nothing, so an agent meets those items
# only when a move is refused. This asks for both to be printed, told apart.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-08-28T19:10:00+0100' } );
$tira->project_new(
    name => 'Born past a gate', dir => $root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BSW', epic_prefix => 'BEP', ticket_prefix => 'BTK',
);

# Both templates on one column, which is the only shape where this is visible:
# a column that is both somewhere a card can be created and somewhere with an
# entry list.
$tira->column_update(
    project => $root, type => 'ticket', name => 'implement',
    required_action       => ['EXIT: prove the thing'],
    entry_required_action => ['ENTRY: say what you will run'],
);

sub run_cli {
    my ( $command, @argv ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    # A general-purpose capture rather than a refusal assertion, so it declares
    # itself the way t/149 asks: any failure is what this means. The one
    # assertion that reads it wants the call NOT to have failed - creation must
    # never be refused for an unsatisfied entry action - and for that reading,
    # a death from any cause is a genuine failure of the claim. The refusal
    # this file DOES assert, the refused move, is checked on its message rather
    # than on this flag.
    my $died = !eval {
        Tira::CLI->run( command => $command, tira => $tira,
            argv => [ '--type', 'ticket', @argv, '-o', 'toon' ] );
        1;
    };
    my $why = $@;
    select $old;
    return { out => $stdout // '', err => $said // '', died => $died, why => $why };
}

sub items_on {
    my ($ref) = @_;
    my $record = eval { $tira->record_show( project => $root, type => 'ticket', ref => $ref ) }
      or return [];
    return $record->{required_items} // [];
}

sub named {
    my ( $ref, $wanted ) = @_;
    return grep { ( $_->{item} // '' ) eq $wanted } @{ items_on($ref) };
}

# --- the mechanism exists, on the way in -----------------------------------
#
# An anchor rather than an achievement, and it is here so the failures below
# read as "creation does not do what moving does" rather than "entry actions do
# not work". If this one ever fails, everything under it is measuring the wrong
# thing.

my $moved = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'a card that moves in' );
my $move = run_cli( 'record.move', '--ref', $moved->{ref}, '--column', 'implement', '--author', 'ada' );

ok( scalar named( $moved->{ref}, 'ENTRY: say what you will run' ),
    'a card MOVED into the column receives its entry required action' );
# Asserted on what the command SAYS, not on whether it threw. Tira::CLI catches
# the refusal and prints it - the first version of this checked $move->{died}
# and failed against working code, which would have read as "entry gates are
# broken" and sent the whole file chasing the wrong thing.
like( $move->{out} . $move->{err}, qr/Cannot move \S+ into implement/,
    'and the move is refused until that action is done - the gate the created card never meets' );

# --- a card created straight into the same column ---------------------------

my $create = run_cli( 'record.create', '--title', 'a card that starts there',
    '--column', 'implement', '--author', 'ada' );
my ($born) = ( $create->{out} // '' ) =~ /(BTK-\d+)/;
ok( $born, 'the card was created' ) or BAIL_OUT('no ref to test against');

ok( !$create->{died},
    'creation is NOT refused for an unsatisfied entry action - there is nothing to run a command against before the card exists' );

ok( scalar named( $born, 'EXIT: say what you will run' ) == 0,
    'the exit template is not confused with the entry one' );
ok( scalar named( $born, 'EXIT: prove the thing' ),
    'the exit template is still seeded on create, as it has been since TKT-439' );

ok( scalar named( $born, 'ENTRY: say what you will run' ),
    'and the entry template is seeded too - the card is asked what it was born past' );

my ($entry_item) = grep { ( $_->{item} // '' ) eq 'ENTRY: say what you will run' } @{ items_on($born) };
is( ( $entry_item ? $entry_item->{column} : undef ), 'implement',
    'tagged with the column it belongs to, so the gate can find it' );
is( ( $entry_item ? $entry_item->{status} : undef ), 'pending',
    'and pending, because nothing has been proved about a card that did not exist a moment ago' );

# --- and the card is TOLD, which is the half that is easy to under-build -----
#
# The exit items have been seeded silently since TKT-439, so an agent meets
# them when a move is refused. Printing only the new entry items would leave
# that older silence in place.

# ASSERTED ON STDERR ALONE, and the reason is a trap this file already fell
# into. -o toon prints the whole created card, and the card's own
# required_items list contains the item text - so an assertion against stdout
# passes on the record dump whether or not a warning was ever printed. The
# first version of the exit-action assertion below was green for exactly that
# reason, against code that prints no warning at all.
#
# STDERR is also where the warning belongs. An agent parses stdout, and -o json
# has to stay a document; the browser move path already prints its
# entry-population failures to STDERR (CLI.pm:1068), so this follows a route
# that exists rather than inventing one.
my $warned = $create->{err};
like( $warned, qr/ENTRY: say what you will run/,
    'the create warns about the entry action it just recorded' );
like( $warned, qr/EXIT: prove the thing/,
    'and about the exit actions too, which have been seeded silently since TKT-439' );
like( $warned, qr/entry/i,
    'and says which are which, since one kind is owed now and the other on the way out' );

# ACTIONABLE FROM THE MESSAGE ALONE, which is test_steps' fourth line and the
# thing a warning is for. Listing texts and then saying "--id REQ-NNN" would
# send its reader to ticket.show to map one to the other - the cross-reference
# that has already put proofs against the wrong ids on this board. The move
# refusal prints "REQ-001  the text"; so does this.
my %id_for = map { ( $_->{item} // '' ) => $_->{id} } @{ items_on($born) };
for my $text ( 'ENTRY: say what you will run', 'EXIT: prove the thing' ) {
    like( $warned, qr/\Q$id_for{$text} $text\E/,
        "the warning names $id_for{$text} beside its text, so acting on it is copying rather than cross-referencing" );
}
unlike( $warned, qr/REQ-NNN/,
    'and the command it ends with carries a real id, not a placeholder to look up' );

# --- one item, one mention --------------------------------------------------
#
# A column may carry the same text in BOTH templates - "Verify all details in
# the card" is a plausible thing to owe on the way in and again before leaving,
# and t/411 uses exactly that wording for an entry action. required_item_add
# stores it once, so a message that counted it under both headings announced
# two obligations on a card carrying one REQ id, and sent its reader looking
# for an item that does not exist.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done',
    required_action       => [ 'Say the same thing', 'Say something else' ],
    entry_required_action => ['Say the same thing'],
);
my $both = run_cli( 'record.create', '--title', 'a card owed one thing twice',
    '--column', 'done', '--author', 'ada' );
my ($twice) = ( $both->{out} // '' ) =~ /(BTK-\d+)/;

is( scalar @{ items_on($twice) }, 2,
    'text in both templates is stored once - two templates, three entries, two items' );

my $mentions = () = ( $both->{err} // '' ) =~ /Say the same thing/g;
is( $mentions, 1,
    'and the warning mentions it once, not once per template it appeared in' );
like( $both->{err}, qr/owed now: REQ-\d+ Say the same thing/,
    'under entry rather than exit, because owed now is the stricter of the two - and with its id, like every other item named here' );

# And the same text repeated INSIDE one template, which column_update stores
# without complaint. Found by a code review of the fix above: deduping across
# the two lists and not within them left the message contradicting the card in
# a second way - a count of two for one stored item, with the same REQ id
# printed twice beside it, reading as two items that happen to share an id.

# On a column of its own rather than on backlog. The first version put these
# templates on backlog, which is where the no-templates control below creates
# its card - so the control failed, correctly, against a fixture that had
# quietly given it something to find.
$tira->column_add( project => $root, type => 'ticket', name => 'gated', after => 'implement' );
$tira->column_update(
    project => $root, type => 'ticket', name => 'gated',
    entry_required_action => [ 'Twice in one list', 'Twice in one list' ],
    required_action       => [ 'Also twice',        'Also twice' ],
);
my $within = run_cli( 'record.create', '--title', 'a card owed one thing listed twice',
    '--column', 'gated', '--author', 'ada' );
my ($dup) = ( $within->{out} // '' ) =~ /(BTK-\d+)/;

# An anchor, not a test of this fix: required_item_add dedupes STORAGE on its
# own, so this passes with or without the change. It is here so the three below
# read as "the message disagreed with the card" rather than "the card is
# wrong". Checked by reverting: 20, 21 and 22 fail against the un-deduped
# message; this one does not.
is( scalar @{ items_on($dup) }, 2,
    'a text repeated inside one template is stored once - four template entries, two items' );
like( $within->{err}, qr/1 entry required action\(s\)/,
    'and the warning counts it once, not once per template entry' );
like( $within->{err}, qr/1 exit required action\(s\)/,
    'the same on the exit side, which repeats the fault if only one list is deduped' );
my $repeats = () = ( $within->{err} // '' ) =~ /Twice in one list/g;
is( $repeats, 1, 'and names it once, rather than printing one id twice as though it were two items' );

# --- an entry action that cannot be placed ----------------------------------
#
# _populate_entry_required_actions returns [text, why] pairs for what it could
# NOT add rather than swallowing the failure, and the move path reports them.
# Creation must do the same and still succeed - and, critically, must not then
# claim to have recorded an item that is not on the card.
#
# An empty entry action is the reachable trigger: column_update stores the
# template as given and required_item_add refuses an empty item. The move
# path's own refusal already has wording for it, "(an empty entry action)".

$tira->column_add( project => $root, type => 'ticket', name => 'unplaceable', after => 'gated' );
$tira->column_update(
    project => $root, type => 'ticket', name => 'unplaceable',
    entry_required_action => [''],
    required_action       => ['A real exit thing'],
);
my $broken = run_cli( 'record.create', '--title', 'a card whose entry action will not attach',
    '--column', 'unplaceable', '--author', 'ada' );
my ($limped) = ( $broken->{out} // '' ) =~ /(BTK-\d+)/;

ok( !$broken->{died}, 'an entry action that cannot be placed does not stop the card being created' );
like( $broken->{err}, qr/could not be put on the card/,
    'and it is reported rather than swallowed, with the reason' );
like( $broken->{err}, qr/\(an empty entry action\)/,
    'named the way the move path names the same failure' );
unlike( $broken->{err}, qr/0 entry required action\(s\)/,
    'the warning does not claim to have recorded an entry action it could not place' );
like( $broken->{err}, qr/1 exit required action\(s\)/,
    'while the exit item that DID attach is still named - one failure does not silence the rest' );

# --- a column with neither template is untouched -----------------------------
#
# The control. A change that printed a warning on every create, or seeded
# something onto every card, would pass everything above.

my $plain = run_cli( 'record.create', '--title', 'a card in an ordinary column', '--author', 'ada' );
my ($quiet) = ( $plain->{out} // '' ) =~ /(BTK-\d+)/;
is( scalar @{ items_on($quiet) }, 0,
    'a card created into a column with no templates carries no required items' );
# empty is what passes: the whole claim is that nothing was printed, so an
# empty stderr is not this denial slipping through - it IS the finding. The
# assertion above pins the other half, that the card carries no items either,
# so a change that stopped seeding AND stopped printing cannot satisfy one of
# these while quietly breaking the case the file is about.
unlike( $plain->{err}, qr/required action/i,
    'and is warned about nothing, because there is nothing to tell it' );

done_testing();

__END__

=head1 NAME

t/421-a-card-born-past-a-gate.t - a card created straight into a column must
receive that column's entry required actions, and be told about them

=head1 DESCRIPTION

Every column carries two templates: C<required_actions>, which a card must
satisfy to leave, and C<entry_required_actions>, which it must have satisfied
to be moved in. The move path places both. The create path places only the
first, under a comment saying it mirrors the move-in logic exactly - it
mirrored the function that does half the job.

So a card created straight into such a column is born past a gate it can never
be asked to pass: no items are recorded, nothing checks it, and the gate is not
failed but skipped in silence. That is the failure the whole required-action
mechanism exists to prevent.

Creation is not blocked, and cannot be. A required action's proof is a command
and its output, and before the card exists there is nothing to run a command
against - the owner's own reasoning on TSK-250. The items are recorded as
pending and printed instead.

The warning covers the exit template as well, which has been seeded on create
since TKT-439 and printed by nothing. Fixing only the newer silence would leave
the older one exactly as it is.

The first two assertions are anchors: they cover the move path, which already
works, so the failures beneath them read as creation not doing what moving does
rather than entry actions being broken.

=cut
