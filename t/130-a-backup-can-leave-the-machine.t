#!/usr/bin/env perl
# A backup can leave the machine, and come back somewhere else.
#
# The repository tira.backup keeps lives inside the board's own storage. That
# protects against a bad edit and against nothing else: whatever destroys the
# board destroys the backup with it. Losing the disk loses both.
#
# His design: a git bundle. One file, the whole history, kept wherever he keeps
# things - and import reads one back and makes the folder be what was restored.
#
# The bundle carries attachments, because he said it plainly: a bundle is
# everything or it is not a backup.
#
# On migration he said import migrates the way an upgrade would, rather than
# refusing an older bundle. That is smaller than it sounds and worth writing
# down before somebody builds a migration subsystem: Tira has no migrations.
# schema_version is written into the project file and never read, and the
# codebase's stated approach is to apply defaults on READ so every board made
# before a release behaves correctly without one. An older bundle is therefore
# already handled by the readers. What is not handled, and cannot be, is the
# opposite - a bundle made by a NEWER Tira restored into an older one. Refusing
# that is honest where migrating it is impossible.

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
my $tira = Tira->new( clock => sub {'2026-08-13T14:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Portable', dir => $root, members => ['michael'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'PBS', epic_prefix => 'PBE', ticket_prefix => 'PBT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Must survive the journey' );
$tira->record_update( project => $root, ref => $card->{ref},
    description => 'and arrive saying this' );

my $note = File::Spec->catfile( $tmp, 'evidence.txt' );
open my $fh, '>', $note or die $!;
print {$fh} "bytes that must travel\n";
close $fh;
$tira->attachment_add( project => $root, ref => $card->{ref}, file => $note );

sub run {
    my ( $project, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $project; Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ @argv ] ) };
    };
    return ( $status, $out, $err );
}

my $bundle = File::Spec->catfile( $tmp, 'board.bundle' );

# --- nothing to export yet ----------------------------------------------------

my ( $status, $out, $err ) = run( $root, 'backup.export', '--file', $bundle );
isnt( $status, 0, 'a board that has never been backed up cannot be exported' );
ok( !-e $bundle, 'and no file is left behind by the attempt' );

# --- back it up, then export --------------------------------------------------

is( ( run( $root, 'backup' ) )[0], 0, 'the board is backed up' );
( $status, $out ) = run( $root, 'backup.export', '--file', $bundle, '-o', 'json' );
is( $status, 0, 'and exported' );
my $exported = decode_json($out);
ok( -s $bundle, 'the bundle is a file with something in it' );
is( $exported->{file}, $bundle, 'and it says where it put it' );

# --- it really is a bundle, readable on its own -------------------------------
#
# A file that only this machine can read is not a backup that left the machine.

# Read from a repository, because git refuses to read a bundle outside one -
# which is the first thing importing had to learn.
my $verified = Tira::CLI::_running( 'git', '-C',
    File::Spec->catdir( $root, '.tira' ), 'bundle', 'verify', $bundle );
ok( $verified, 'git reads it back as a bundle, so another machine could too' );

# --- import it somewhere else -------------------------------------------------

my $elsewhere = File::Spec->catdir( $tmp, 'elsewhere' );
( $status, $out ) = run( $elsewhere, 'backup.import', '--file', $bundle, '-o', 'json' );
is( $status, 0, 'a bundle imports into a folder that was not a board' );

# --- and the board is there ---------------------------------------------------
#
# Read out through the engine, because a directory of correct bytes that Tira
# will not open is not a restored board.

my $arrived = $tira->record_show( project => $elsewhere, ref => $card->{ref} );
is( $arrived->{ref}, $card->{ref}, 'the card arrived' );
is( $arrived->{description}, 'and arrive saying this', 'saying what it said' );
is( $tira->project_show( project => $elsewhere )->{name}, 'Portable',
    'and the project came with it' );

my ($attachment) = @{ $arrived->{attachments} };
ok( $attachment, 'the card still has its attachment' );
my $bytes = $tira->attachment_get( project => $elsewhere, ref => $card->{ref},
    sha => $attachment->{sha} );
like( $bytes->{content}, qr/bytes that must travel/,
    'and the bytes travelled with it, because a bundle is everything or it is not a backup' );

# --- the board works where it landed ------------------------------------------

my $next = $tira->create_record( project => $elsewhere, type => 'ticket', title => 'Life goes on' );
like( $next->{ref}, qr/\APBT-/, 'the imported board issues its own references' );
is( ( run( $elsewhere, 'backup' ) )[0], 0, 'and can be backed up again where it landed' );

# --- importing over a board that is not empty ---------------------------------
#
# The same rule as a restore: this can lose work, so it says what it would
# discard and does nothing until that is agreed to.

( $status, $out, $err ) = run( $root, 'backup.import', '--file', $bundle );
isnt( $status, 0, 'importing over an existing board is refused without agreement' );
like( $err, qr/--yes/, 'and says how to agree to it' );
like( $err, qr/every card in this board would be replaced/,
    'and says so even when nothing here is unsaved, because replacing a board is the loss' );

# And when there IS unsaved work here, it is named rather than counted. "3
# files" tells nobody whether it matters.
my $unsaved = $tira->create_record( project => $root, type => 'ticket',
    title => 'Not in any backup' );
( $status, $out, $err ) = run( $root, 'backup.import', '--file', $bundle );
isnt( $status, 0, 'still refused' );
like( $err, qr/\Q$unsaved->{ref}\E/, 'naming the work that is not in any backup' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{ref}, $card->{ref},
    'and the board it would have replaced is untouched' );

# --- a bundle from a newer Tira ------------------------------------------------
#
# Tira has no migrations. Reading an older board works because defaults are
# applied on read; reading a newer one cannot be made to work by any amount of
# care here, so it is refused rather than half-restored.

my $future = File::Spec->catdir( $tmp, 'future' );
( $status, $out, $err ) = run( $future, 'backup.import', '--file', $bundle,
    '--claiming-schema', 99 );
isnt( $status, 0, 'a bundle from a newer Tira is refused' );
like( $err, qr/newer/i, 'saying that is what it is' );
ok( !-d File::Spec->catdir( $future, '.tira' ),
    'and nothing is written, so a refusal never half-restores' );

done_testing;

__END__

=head1 NAME

130-a-backup-can-leave-the-machine.t - a backup can leave the machine and come back

=head1 DESCRIPTION

The repository C<tira.backup> keeps lives inside the board's own storage, so it
protects against a bad edit and not against losing the disk.
C<tira.backup.export> writes a git bundle - one file holding the history and the
attachments - and C<tira.backup.import> reads one back into a folder that was
not a board.

Importing over an existing board can lose work, so it names what it would
discard and does nothing without C<--yes>. A bundle claiming a newer schema than
this Tira understands is refused rather than half-restored: Tira has no
migrations, and reading an older board already works because defaults are
applied on read.

=cut
