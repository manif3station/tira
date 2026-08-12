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
my $tira = Tira->new( clock => sub { '2026-08-10T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Discarded', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'DSS', epic_prefix => 'DSE', ticket_prefix => 'DST' );
my $live = $tira->create_record( project => $root, type => 'ticket', title => 'Still wanted' );
my $dropped = $tira->create_record( project => $root, type => 'ticket', title => 'Abandoned' );
$tira->record_discard( project => $root, type => 'ticket', ref => $dropped->{ref} );

sub board_html {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '--project', $root, @argv ], tira => $tira );
    }
    return $out;
}

# Every board is created with Backlog and Discard. The owner saw one and never
# the other, so discarded work vanished from the only view he looks at.
my $html = board_html( '-o', 'table' );
like( $html, qr/class="column__name">discard</, 'a board somebody is looking at shows where discarded work went' );
like( $html, qr/\Q$dropped->{ref}\E/, 'and the card that went there' );
like( $html, qr/\Q$live->{ref}\E/, 'without losing the live work' );

# Drawn as set aside rather than as live work, or the board would suggest there
# is more to do than there is.
like( $html, qr/class="column column--discard"/, 'the discard column is marked as such' );
like( $html, qr/\.column--discard\{opacity:\.6\}/, 'and drawn faded' );

# The path an agent queries is untouched: it costs nothing and returns only
# what was asked for.
my $agent_view = $tira->dashboard( project => $root, type => 'ticket', summary => 1 );
ok( !exists $agent_view->{ticket}{discard},
    'the ref-only board still leaves discarded work out, so nobody pays for cards they did not ask about' );

# And asking for it explicitly still works, either way round.
my $asked = $tira->dashboard(
    project => $root, type => 'ticket', summary => 1, include_discard => 1 );
ok( exists $asked->{ticket}{discard}, 'asking for it explicitly still returns it' );

# JSON output is a machine surface, so it keeps its old shape unless asked.
my $json = decode_json( board_html( '-o', 'json' ) );
ok( !exists $json->{ticket}{discard}, 'the machine view is unchanged' );
my $json_asked = decode_json( board_html( '-o', 'json', '--include-discard' ) );
ok( exists $json_asked->{ticket}{discard}, 'until it is asked for' );

# Showing the column brought its add-card control with it, which invites
# somebody to create work directly into the discard pile.
{
    my $board = $tira->format_output(
        $tira->dashboard( project => $root, type => 'ticket', summary => 1, include_discard => 1 ),
        output => 'table', project => $root, live => 1 );
    like( $board, qr/data-add-card="backlog"/, 'a working column offers a way to add a card' );
    unlike( $board, qr/data-add-card="discard"/,
        'the discard column does not, because nobody creates work straight into it' );
    like( $board, qr/class="column column--discard"/, 'while still being shown' );
}

done_testing;

__END__

=head1 NAME

72-discard-column.t - the Discard column nobody could see

=head1 DESCRIPTION

Every board is created with a Backlog and a Discard column, and the
owner reported seeing the first and never the second: work he had
discarded simply disappeared from the view he actually uses. The board
a person looks at now shows it, faded and marked as set aside so it
does not read as live work, while the ref-only board an agent queries
is untouched and still returns only what was asked for.

=cut
