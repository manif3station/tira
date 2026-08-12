#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

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

sub reviewing {
    my ($ref) = @_;
    my $board = $tira->dashboard( project => $root, type => 'ticket' );
    for my $column ( values %{ $board->{ticket} } ) {
        for my $card ( @{$column} ) {
            return $card->{to_review} if $card->{ref} eq $ref;
        }
    }
    return undef;
}

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

# Answered: the card stops waiting on the owner, because it is no longer his
# move. It becomes the agent's, which is a different colour rather than the same
# one - the board should say whose turn it is, not merely that somebody is
# waiting.
$tira->question_answer( project => $root, id => $done->{id}, text => 'That one.' );
ok( !waiting_for( $settled->{ref} ),
    'once answered the card is no longer waiting on the owner' );
ok( reviewing( $settled->{ref} ),
    'it is waiting on the agent instead, which the board draws differently' );

# Reading is not agreeing, so it is still the agent's move.
$tira->question_list( project => $root, ref => $settled->{ref} );
ok( reviewing( $settled->{ref} ),
    'reading an answer is not the same as saying whether it settles anything' );

# Marked: settled, and no colour at all.
$tira->question_mark( project => $root, id => $done->{id}, mark => 'ok' );
ok( !waiting_for( $settled->{ref} ), 'once marked the card is settled' );
ok( !reviewing( $settled->{ref} ), 'and there is nothing left to review' );

# A cross is a judgement too.
$tira->question_mark( project => $root, id => $done->{id}, mark => 'not-ok' );
ok( !reviewing( $settled->{ref} ), 'a cross settles this question too' );

# A card can never be both colours at once: that would be the board saying two
# different people owe the next move.
{
    my $mixed = $tira->create_record( project => $root, type => 'ticket', title => 'Both at once?' );
    my $first = $tira->question_add( project => $root, ref => $mixed->{ref}, text => 'One' );
    $tira->question_answer( project => $root, id => $first->{id}, text => 'Answered' );
    $tira->question_add( project => $root, ref => $mixed->{ref}, text => 'Two, unanswered' );
    ok( waiting_for( $mixed->{ref} ), 'an unanswered question keeps the card the owner\'s' );
    ok( !reviewing( $mixed->{ref} ),
        'and it is not the agent\'s until every question has been answered' );
}
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
like( $html, qr/class="card card--waiting"/, 'a card waiting on the owner is drawn differently' );
like( $html, qr/\.card--to-review\{opacity:\.55/,
    'and a card handed to the agent is greyed out, not a second bright colour' );
like( $html, qr/\.card--to-review\{[^}]*saturate/,
    'faded rather than merely dimmed, so it reads as off the owner\'s plate' );
unlike( $html, qr/\.card--to-review\{[^}]*rgba\(251,146,60/,
    'nothing left of the orange that competed with the yellow for attention' );
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

# The owner opens a board without asking for titles, the page paints
# yellow from the server-rendered HTML, and a second later the refresh rebuilds
# every card from /data. If that payload omits the flag the colour vanishes -
# which is exactly what he saw.
{
    my $captured;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '--project', $root, '-o', 'browser' ],
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
        );
    }
    ok( $captured, 'the board was served without titles being asked for' );
    my $payload = decode_json( $captured->{data}->() );
    my ($card) = grep { $_->{ref} eq $asked->{ref} }
      map { @{$_} } values %{ $payload->{ticket} };
    ok( $card, 'the refresh payload carries the waiting card' );
    ok( $card->{waiting},
        'and still says it is waiting, so the refresh does not wipe the colour' );
    ok( !exists $card->{title}, 'without having fetched titles nobody asked for' );
}

done_testing;

__END__

=head1 NAME

59-waiting-cards.t - a card waiting on somebody looks like it

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
