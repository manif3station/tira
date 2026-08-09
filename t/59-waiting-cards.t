#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Waiting', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT' );

my $asked = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question' );
my $settled = $tira->create_record( project => $root, type => 'ticket', title => 'All settled' );
my $set_aside = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside' );
my $silent = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing asked' );

my $open = $tira->question_add( project => $root, ref => $asked->{ref}, text => 'Which one?' );
my $done = $tira->question_add( project => $root, ref => $settled->{ref}, text => 'And this?' );
my $dropped = $tira->question_add( project => $root, ref => $set_aside->{ref}, text => 'Never mind' );

sub waiting_for {
    my ($ref) = @_;
    my $board = $tira->dashboard( project => $root, type => 'ticket' );
    for my $column ( values %{ $board->{ticket} } ) {
        for my $card ( @{$column} ) {
            return $card->{waiting} if $card->{ref} eq $ref;
        }
    }
    return undef;
}

# Waiting on the owner.
ok( waiting_for( $asked->{ref} ), 'a card with an unanswered question is waiting' );
ok( !waiting_for( $silent->{ref} ), 'a card with no questions is not' );

# Answered, but the agent has not looked: still waiting, on the agent now.
$tira->question_answer( project => $root, id => $done->{id}, text => 'That one.' );
ok( waiting_for( $settled->{ref} ), 'an answer nobody has read leaves the card waiting' );

# Read, but not marked: still waiting, because reading is not agreeing.
$tira->question_list( project => $root, ref => $settled->{ref} );
ok( waiting_for( $settled->{ref} ),
    'reading an answer is not the same as saying whether it settles anything' );

# Read and marked: settled.
$tira->question_mark( project => $root, id => $done->{id}, mark => 'ok' );
ok( !waiting_for( $settled->{ref} ), 'once the answer is read and marked the card is settled' );

# A cross is still a mark: it settles this question, and the new one that must
# follow is what keeps the card waiting.
$tira->question_mark( project => $root, id => $done->{id}, mark => 'not-ok' );
ok( !waiting_for( $settled->{ref} ), 'a cross settles this question too' );
$tira->question_add( project => $root, ref => $settled->{ref}, text => 'Then what about this?' );
ok( waiting_for( $settled->{ref} ), 'and the new question it obliges puts the card back to waiting' );

# Discarded settles nothing further: it was set aside on purpose.
$tira->question_discard( project => $root, id => $dropped->{id} );
ok( !waiting_for( $set_aside->{ref} ), 'a discarded question leaves the card settled' );

# A board somebody is looking at shows this without being asked for titles:
# that is the whole point of the colour.
{
    my $board = $tira->dashboard(
        project => $root, type => 'ticket', summary => 1, with_questions => 1 );
    my %waiting;
    for my $column ( values %{ $board->{ticket} } ) {
        $waiting{ $_->{ref} } = $_->{waiting} for @{$column};
    }
    ok( $waiting{ $set_aside->{ref} } == 0, 'the settled card is not waiting' );
    ok( !exists $board->{ticket}{backlog}[0]{title},
        'and no titles were fetched, because none were asked for' );
}

# SOW's accent must not be the colour that means somebody is waiting.
{
    my $style = $tira->format_output(
        $tira->dashboard( project => $root ), output => 'table', project => $root );
    my ($sow) = $style =~ /\.board--sow\{--accent:(#[0-9a-f]{6})\}/;
    unlike( $sow, qr/\A#f/i, 'the sow board is not amber, which read as the waiting yellow' );
}

# The board draws it.
my $html = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket' ),
    output => 'table', project => $root, with_title => 1 );
like( $html, qr/class="card card--waiting"/, 'a waiting card is drawn differently' );
like( $html, qr/class="card"/, 'and an ordinary card exactly as before' );
like( $html, qr/\.card--waiting\{/, 'the stylesheet says what that looks like' );

# The ref-only fast path must stay cheap: it opens no card at all.
{
    my $opened = 0;
    my $counting = Tira->new( clock => sub {$tick} );
    no warnings 'redefine';
    my $original = \&Tira::_read_json;
    local *Tira::_read_json = sub { $opened++; return $original->(@_) };
    $counting->dashboard( project => $root, type => 'ticket' );
    my $with_titles = $opened;
    $opened = 0;
    $counting->dashboard( project => $root, type => 'ticket', summary => 1 );
    is( $opened, 0, 'the ref-only dashboard opens no card files, as it always has' );
    ok( $with_titles > 0, 'while the full one reads them, which is how it knows' );
}

# And the titles path reads each card once, not twice.
{
    my %opened;
    my $counting = Tira->new( clock => sub {$tick} );
    no warnings 'redefine';
    my $original = \&Tira::_read_json;
    local *Tira::_read_json = sub { $opened{ $_[1] }++; return $original->(@_) };
    $counting->dashboard( project => $root, type => 'ticket', summary => 1, with_title => 1 );
    is_deeply( [ grep { $opened{$_} > 1 } keys %opened ], [],
        'no card is read twice to fetch its title and its state' );
}

done_testing;

__END__

=head1 NAME

59-waiting-cards.t - DD-473 a card waiting on somebody looks like it

=head1 DESCRIPTION

Yellow means somebody is waiting, in either direction: a question
nobody has answered waits on the owner, and an answer nobody has read
and marked waits on the agent. Proves reading an answer is not the same
as agreeing with it, that a cross settles the question it is on while
the new question it obliges puts the card back to waiting, and that a
discarded question settles nothing further because it was set aside on
purpose. Also proves the cost: knowing this means reading the card, so
the ref-only dashboard still opens nothing and stays as cheap as it has
always been.

=cut
