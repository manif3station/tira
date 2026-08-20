#!/usr/bin/env perl
# required_items is new (TKT-445, 3.03). Every record written before that
# release has no such key in its stored JSON at all - create_record only ever
# set it going forward, and nothing backfilled it onto what already existed.
# required_item_add dereferences record.required_items directly with no
# defined-or-empty guard ('my $number = @{ $record->{required_items} } + 1'),
# which dies outright on such a record - and because record.move's own
# move-in population (_apply_column_required_actions) calls required_item_add
# internally whenever a card enters a column with required_actions
# configured, the crash is not confined to the add command: an ordinary
# tira.ticket.move throws for any pre-3.03 card moving into such a column,
# in either direction. Owner, TKT-447 + TKT-448 (2026-08-20), reproduced live
# on a real board (ZSD-234, ZSD-235) - this is not hypothetical, it currently
# blocks real work.

use strict;
use warnings;

use File::Find;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Cpanel::JSON::XS qw(decode_json encode_json);

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Legacy', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc' ],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- simulate a record written before required_items existed --------------
sub strip_required_items {
    my ($ref) = @_;
    my $path;
    find( { no_chdir => 1, wanted => sub {
        $path = $File::Find::name if -f $File::Find::name && $File::Find::name =~ /\Q$ref\E\.json\z/;
    } }, File::Spec->catdir( $root, '.tira', 'ticket' ) );
    die "Fixture card '$ref' not found on disk\n" if !$path;
    open my $fh, '<:raw', $path or die $!;
    local $/;
    my $record = decode_json(<$fh>);
    close $fh;
    delete $record->{required_items};
    ok( !exists $record->{required_items}, "$ref now has no required_items key at all, like a real pre-3.03 record" );
    open my $out, '>:raw', $path or die $!;
    print {$out} encode_json($record);
    close $out;
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy card' );
strip_required_items( $card->{ref} );

# --- required_item_add must not crash on a record with no required_items --
my $added = eval { $tira->required_item_add( project => $root, ref => $card->{ref}, item => 'x', status => 'pending' ) };
ok( $added, 'required_item_add succeeds on a record missing the key entirely' ) or diag($@);
is( $added->{id}, 'REQ-001', 'starts numbering from one, as if the list had always been empty' );

# --- required_item_update must not crash either, on a fresh legacy record -
my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy card two' );
strip_required_items( $card2->{ref} );
my $updated = eval {
    $tira->required_item_add( project => $root, ref => $card2->{ref}, item => 'y', status => 'pending', source => 'required-action' );
};
ok( $updated, 'required_item_add (as move-in population itself calls it) succeeds' ) or diag($@);
my $again = eval {
    $tira->required_item_update( project => $root, ref => $card2->{ref}, id => $updated->{id}, status => 'done' );
};
ok( $again, 'required_item_update succeeds against a record that started with no required_items key' ) or diag($@);

# --- the actual reported symptom: an ordinary move crashes on a legacy card
my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy card three' );
strip_required_items( $card3->{ref} );
my ( $status, $out, $err ) = cli( 'record.move', '--ref', $card3->{ref}, '--column', 'planning' );
is( $status, 0, 'tira.ticket.move into a column with required_actions succeeds on a legacy card, not a crash' )
  or diag($err);
my $shown = $tira->record_show( project => $root, ref => $card3->{ref} );
is( scalar @{ $shown->{required_items} }, 1, "planning's template landed on the card despite it starting with no key at all" );

done_testing;

__END__

=head1 NAME

310-a-record-from-before-the-list-existed.t - required_item_add/update and move-in population survive a record with no required_items key

=head1 DESCRIPTION

Covers TKT-447/TKT-448: every record written before TKT-445 (3.03) shipped
has no required_items key in its stored JSON at all. required_item_add and
required_item_update must both defensively treat a missing key the same as
an empty list, matching required_item_list's own existing behaviour, rather
than dying on an unguarded array dereference. Because record.move's own
move-in population calls required_item_add internally, this is not confined
to the explicit CLI command - an ordinary move into a column with required
actions configured must also survive a legacy record untouched.

=cut
