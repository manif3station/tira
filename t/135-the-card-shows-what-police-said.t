#!/usr/bin/env perl
# The card shows what police has said about it.
#
# Every card carries a per-card enforcement log, written by police and by
# nobody else. That was settled and shipped. The dialog on the browser board
# shows the card's sections, its work log and its questions - and not that log.
# So the one place a person opens to see everything about a card was missing
# what police had said about it.
#
# His words on raising it: he reads the board instead of asking for progress,
# and the dialog is what he opens. A record kept and never surfaced is the same
# as no record from his side - and worse here than usually, because the
# enforcement log exists precisely so that what police said survives the bridge
# scrolling past. Keeping it and not showing it means the surviving copy is
# readable only by an agent running a command.
#
# Two things it must not do. It must offer nothing to change, because police
# writes this and nobody else may - the same reason there is no command to write
# an entry. And it must be quiet on a card police has never mentioned, rather
# than putting an empty heading on every card on the board.

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
my $now = '2026-08-13T18:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Watched', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WCS', epic_prefix => 'WCE', ticket_prefix => 'WCT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

my $chased = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move( project => $root, ref => $chased->{ref}, column => 'implement' );
my $quiet = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing to say about this one' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
$tira->police_pass( project => $root, store => $store, world => {} );

# --- the log exists and is about one card --------------------------------------

my $entries = $tira->enforcement_log( project => $root, store => $store, ref => $chased->{ref} );
ok( scalar @{$entries}, 'police recorded something against the card it chased' );
is( scalar @{ $tira->enforcement_log( project => $root, store => $store, ref => $quiet->{ref} ) }, 0,
    'and nothing against the card it never mentioned' );

# --- the board serves it, per card ----------------------------------------------
#
# Through the same shape as everything else the dialog reads: a provider the
# server is handed, so what the page shows and what a command shows come from
# one place.

my $served;
{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    Tira::CLI->run(
        command => 'dashboard', type => 'ticket',
        argv => [ '--project', $root, '-o', 'browser', '--store', $store ],
        tira => $tira,
        browser_server => sub { my %given = @_; $served = \%given; return 1 },
        restarter => sub {1},
    );
}
ok( $served, 'the board is served' );
is( ref $served->{police_log}, 'CODE', 'and is handed a police log provider, like every other section' );

my $shown = decode_json( $served->{police_log}->( { ref => $chased->{ref} } ) );
is( scalar @{$shown}, scalar @{$entries}, 'which serves what the command serves' );
like( $shown->[0]{detail}, qr/\S/, 'saying what police said' );
like( $shown->[0]{at}, qr/\A\d{4}-\d{2}-\d{2}/, 'and when it said it' );
is( $shown->[0]{kind}, 'violation', 'and what kind of thing it was' );

is_deeply( decode_json( $served->{police_log}->( { ref => $quiet->{ref} } ) ), [],
    'a card police never mentioned has an empty log rather than an error' );

my $refused = !eval { $served->{police_log}->( {} ); 1 };
ok( $refused, 'and asking without naming a card is refused rather than answered with everything' );

# --- the page has somewhere to show it ------------------------------------------

my $data = $tira->dashboard( project => $root, with_title => 1 );
my $page = $tira->format_output( $data, output => 'table', project => $root,
    live => 1, with_title => 1 );

like( $page, qr/card-section--policelog/, 'the dialog has a section for it' );
like( $page, qr/renderPoliceLog/, 'and the code that fills it' );
like( $page, qr{/policelog\?ref=}, 'reading it for the card the dialog is open on' );

# --- it offers nothing to change -------------------------------------------------
#
# Police writes this and nobody else does, which is why there is no command to
# add an entry. A page that offered a button would be the one way around that.

unlike( $page, qr/policelog[^"]*__edit|data-policelog-(?:add|save|remove)/,
    'and nothing anywhere to edit it, because only police may write it' );

# --- and it is quiet when there is nothing ---------------------------------------
#
# An empty heading on every card on the board is how a section teaches people to
# skip past it. Read when the card opens rather than when a section is expanded,
# because there is at most one line per thing police has said - unlike the work
# log, which is why that one is lazy.

like( $page, qr/\Qif(!entries||!entries.length){box.hidden=true\E/,
    'the section hides itself when the card has nothing recorded against it' );
like( $page, qr/\Qbox.hidden=false\E/, 'and appears when it has' );
like( $page, qr/What police has said \(/,
    'saying how many things police has recorded, which is what the log counts' );

# --- and it is rendered wherever the dialog is filled ----------------------------
#
# The dialog is populated in three places - opening a card, the detail fetch,
# and the refresh - and the first attempt added the section to one of them. The
# browser test caught it; nothing in the markup would have, because the section
# was present and simply never asked to fill itself.

my $calls = () = $page =~ /renderPoliceLog\(record\)/g;
is( $calls, 3, 'every place the dialog is filled renders it, not just the one I edited first' );

done_testing;

__END__

=head1 NAME

135-the-card-shows-what-police-said.t - the card dialog shows its enforcement log

=head1 DESCRIPTION

Every card carries a per-card enforcement log written by police and by nobody
else, and the dialog - the one place a person opens to see everything about a
card - did not show it. The record survived the bridge scrolling past and was
readable only by an agent running a command.

The dialog now reads it per card through a provider, the same shape as every
other section, shows when and what and what kind, offers nothing to change
because only police may write it, and stays hidden on a card police has never
mentioned.

=cut
