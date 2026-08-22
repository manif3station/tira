#!/usr/bin/env perl
# A board can be put back to a backup, and the backup is proved by restoring.
#
# tira.backup ships and makes a commit. Until something has actually been taken
# back from one of those commits, the backup is a claim: a directory of files
# nobody has read out again. The dev board was destroyed on 11 August with
# nothing to restore from, and a backup that has never been restored is exactly
# the position that felt safe the day before.
#
# His answer on the shape: git reset --hard. A restore is a restore. Anything
# done since the backup is gone.
#
# Which is why it says what it is about to discard before it does it. reset
# --hard is the right behaviour and also the one that eats an afternoon's work
# in silence, and a command that destroys without warning is one people stop
# running - or worse, run without reading.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T13:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Recoverable', dir => $root, members => ['michael'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'RCS', epic_prefix => 'RCE', ticket_prefix => 'RCT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'The card that must come back' );
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref},
    description => 'as it was when the backup was made' );

my $note = File::Spec->catfile( $tmp, 'evidence.txt' );
open my $fh, '>', $note or die $!;
print {$fh} "bytes that must survive\n";
close $fh;
$tira->attachment_add( project => $root, ref => $card->{ref}, file => $note );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ @argv ] ) };
    };
    return ( $status, $out, $err );
}

# --- there is nothing to restore to yet -------------------------------------
#
# A board with no backup must say so rather than reporting success about
# nothing, which is the shape of every restore that quietly did not happen.

my ( $status, $out, $err ) = run( 'backup.restore', '--yes' );
isnt( $status, 0, 'a board that has never been backed up cannot be restored' );
like( $err, qr/never been backed up|no backup/i, 'and says that, rather than failing obscurely' );

# --- back it up ---------------------------------------------------------------

( $status, $out ) = run( 'backup', '-o', 'json' );
is( $status, 0, 'the board is backed up' );
my $backup = decode_json($out);

# --- then break it ------------------------------------------------------------
#
# Everything a restore has to undo: a card changed, a card added, and a card
# deleted outright.

$tira->record_update( author => 'michael', project => $root, ref => $card->{ref},
    description => 'changed after the backup' );
my $later = $tira->create_record( project => $root, type => 'ticket',
    title => 'Raised after the backup' );
my $gone = File::Spec->catfile( $root, '.tira', 'attachments' );
opendir my $dir, $gone or die $!;
my ($stored) = grep { !/\A\./ } readdir $dir;
closedir $dir;
unlink File::Spec->catfile( $gone, $stored ) or die "cannot remove the attachment: $!";
ok( !-f File::Spec->catfile( $gone, $stored ), 'and the attachment is deleted off the disk' );

# --- it says what it is about to discard --------------------------------------
#
# Before anything is destroyed, not after. Asked without agreeing, nothing
# happens at all: this is the only command in Tira that can lose work.

( $status, $out, $err ) = run( 'backup.restore', '-o', 'json' );
isnt( $status, 0, 'a restore that has not been agreed to does not happen' );
like( $err, qr/\Q$later->{ref}\E/, 'and names the card that would be lost' );
like( $err, qr/--yes/, 'and says how to agree to it' );

is( $tira->record_show( project => $root, ref => $later->{ref} )->{ref}, $later->{ref},
    'the card raised since the backup is still there, because nothing was done' );

# --- and then it does it ------------------------------------------------------

( $status, $out ) = run( 'backup.restore', '--yes', '-o', 'json' );
is( $status, 0, 'a restore that has been agreed to happens' );
my $restored = decode_json($out);
is( $restored->{commit}, $backup->{commit}, 'back to the backup that was made' );

# --- and the board really is the board it was ---------------------------------
#
# Read out through the engine, not by looking at files. A restore that leaves
# the right bytes in the wrong shape is not a restore.

is( $tira->record_show( project => $root, ref => $card->{ref} )->{description},
    'as it was when the backup was made', 'the card is as it was' );

my $vanished = !eval { $tira->record_show( project => $root, ref => $later->{ref} ); 1 };
ok( $vanished, 'the card raised after the backup is gone, as he asked for' );
like( $@, qr/not found/, 'gone because the board no longer has it, not for another reason' );

ok( -f File::Spec->catfile( $gone, $stored ), 'and the deleted attachment is back on the disk' );

# --- the board still works afterwards -----------------------------------------
#
# The check nobody thinks to make: a restored board has to be a board, not a
# directory of correct files that Tira will not open.

my $after = $tira->create_record( project => $root, type => 'ticket', title => 'Life goes on' );
is( $after->{ref}, $later->{ref},
    'the next card takes the reference the restore gave back, because counters came back too' );

( $status, $out ) = run( 'backup', '-o', 'json' );
is( $status, 0, 'and the restored board can be backed up again' );

done_testing;

__END__

=head1 NAME

129-a-board-can-be-restored.t - a board can be put back to a backup

=head1 DESCRIPTION

C<tira.backup> made commits and nothing had ever been taken back out of one, so
the backup was a claim. C<tira.backup.restore> puts the board back with
C<git reset --hard>: the cards, the attachments and the counters as they were,
and anything done since is gone.

Because it can lose work, it says what it is about to discard and does nothing
until that is agreed to. A board with no backup is refused rather than reported
as restored, and a restored board is still a working board - it can be added to
and backed up again.

=cut
