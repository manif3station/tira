#!/usr/bin/env perl
# A card is not shown as empty when it is full.
#
# mt5-ai asked for one field of a card in the readable format:
#
#   d2 tira.ticket.show --ref REF --fields column -o human
#
# and got a card with an empty title, "_No description._", an empty type,
# "_Unassigned_", "_None_" for the reporter and "_None_" for the priority - on a
# card where every one of those is filled in. The column they asked for did not
# appear anywhere.
#
# The flag is accepted and honoured: the record really is narrowed to what was
# asked for, and an unknown field name still exits 2. What follows is a renderer
# that draws a fixed card template against whatever it is handed, so every key
# the narrowing removed prints as its empty placeholder.
#
# Their words for why this is worse than ignoring the flag: ignoring it would
# show the whole card, which is merely unhelpful; this shows a filled card as an
# empty one AND omits what was asked for, so the output is wrong in both
# directions at once. And it is worst on a board following the rules Tira ships
# with, which require every field populated before a card leaves planning - a
# reviewer reading this sees exactly the hollow card those rules exist to catch.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T11:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Readable', dir => $root, members => [ 'michael', 'ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RDS', epic_prefix => 'RDE', ticket_prefix => 'RDT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Throughput under load', description => 'it collapses on a burst',
    assignee => 'ada', reporter => 'michael', priority => 4 );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

sub show {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'record.show', type => 'ticket', tira => $tira,
            argv => [ '--ref', $card->{ref}, @argv ] ) };
    };
    return ( $status, $out, $err );
}

# --- the whole card, which was never the problem ------------------------------------

my ( $status, $whole ) = show( '-o', 'human' );
is( $status, 0, 'the whole card is readable' );
like( $whole, qr/Throughput under load/, 'with its title' );
like( $whole, qr/it collapses on a burst/, 'and its description' );
like( $whole, qr/Assignee: ada/, 'and who holds it' );
like( $whole, qr/Priority: High/, 'and how urgent it is' );

# --- one field of it ----------------------------------------------------------------
#
# What they asked for, and what they got instead.

my ( $narrow_status, $narrow ) = show( '--fields', 'column', '-o', 'human' );
is( $narrow_status, 0, 'asking for one field succeeds' );
like( $narrow, qr/implement/, 'and the field asked for is in the answer, which is the whole point' );

unlike( $narrow, qr/_No description\._/,
    'a card with a description is not told it has none' );
unlike( $narrow, qr/_Unassigned_/,
    'nor is a card somebody holds reported as held by nobody' );
unlike( $narrow, qr/Priority: _None_/,
    'nor a card with a priority reported as having none' );

# --- and asking for a field the card really lacks still says so -----------------------
#
# The renderer must not go silent about absence in general. A field that is
# genuinely empty is worth seeing as empty; what was wrong was reporting absence
# for fields nobody asked about.

my ( undef, $lacking ) = show( '--fields', 'sandbox', '--include-empty', '-o', 'human' );
like( $lacking, qr/sandbox/i, 'a field that is genuinely empty is still named when asked for' );

# --- several fields ---------------------------------------------------------------------

my ( undef, $several ) = show( '--fields', 'title', '--fields', 'assignee', '-o', 'human' );
like( $several, qr/Throughput under load/, 'two fields asked for: the title is there' );
like( $several, qr/ada/,                   'and the assignee' );
unlike( $several, qr/_No description\._/,  'and nothing is invented about the rest' );

# --- a field that holds a list, and one that holds a shape ---------------------------------
#
# Most of a card's substance is in lists - the key details, the acceptance
# criteria, the labels - and the scope is a pair of them. Printing a reference
# to an array where a reader expected text would be its own kind of empty.

$tira->record_update( project => $root, ref => $card->{ref},
    labels => [ 'throughput', 'urgent' ],
    scope_in => ['the drain'], scope_out => ['the producer'] );

my ( undef, $listed ) = show( '--fields', 'labels', '-o', 'human' );
like( $listed, qr/throughput, urgent/, 'a field holding a list reads as a list' );

my ( undef, $shaped ) = show( '--fields', 'scope', '-o', 'human' );
like( $shaped, qr/the drain/,    'a field holding a shape shows what is in it' );
like( $shaped, qr/the producer/, 'including the other half of it' );

my ( undef, $emptied ) = show( '--fields', 'deliverables', '--include-empty', '-o', 'human' );
like( $emptied, qr/deliverables/, 'and an empty list is named' );

# --- and a list of cards, narrowed the same way ---------------------------------------------
#
# The same flag on a listing. One card shown wrongly is a card; a whole board
# shown wrongly is a board that looks abandoned.

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'record.list', type => 'ticket', tira => $tira,
            argv => [ '--fields', 'column', '-o', 'human' ] ) };
    };
    is( $status, 0, 'a listing narrowed to one field succeeds' );
    like( $out, qr/implement/, 'and says the field for the card it has' );
    unlike( $out, qr/_No description\._/, 'without inventing anything about the rest' );
}

# --- while the other formats are untouched ------------------------------------------------
#
# json and toon were correct throughout - they carry what the record carries -
# and this must not change what they say.

my ( undef, $json ) = show( '--fields', 'column', '-o', 'json' );
like( $json, qr/"column"\s*:\s*"implement"/, 'json still answers with the field asked for' );
unlike( $json, qr/"title"/, 'and nothing that was not asked for' );

done_testing;

__END__

=head1 NAME

157-a-filled-card-shown-as-empty.t - a card is not shown as empty when it is full

=head1 DESCRIPTION

C<--fields> with C<-o human> narrowed the record correctly and then drew a fixed
card template against it, so every key the narrowing had removed printed as its
empty placeholder: no description, unassigned, no priority - on a card where all
of them were filled. The field actually requested appeared nowhere.

The readable format now shows what it was given. C<json> and C<toon> were
correct throughout and are unchanged.

=cut
