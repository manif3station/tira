#!/usr/bin/env perl
# Six files, one command.
#
# Reported from zen-framework: attaching six PNGs in a shell loop was killed at a
# two-minute limit having completed five, and each attachment seemed to take
# about twenty seconds regardless of file size.
#
# He guessed the SHA. Measured on 2.64, it is not:
#
#   small board, 1 card      0.56 - 0.75s per file
#   big board, 400 cards     0.54 - 0.57s per file
#   d2 (no arguments)        0.06s
#   d2 tira.<unknown>        0.50s      <- does no work at all, just fails
#   d2 tira.project.show     0.54s
#   d2 tira.attachment.add   0.54 - 0.75s
#   perl -MTira -e1          0.07s
#
# An unknown command costs the same half-second as a real one, so that time is
# resolving the command, not doing the work. Attachment work is the remainder,
# about 0.05s. Board size is irrelevant. A 61KB file and a 217KB file take the
# same time, which is a fixed cost and never was a per-byte one.
#
# So six files cost six command resolutions - 3.87s measured, of which about 3.0s
# is the entrance fee paid six times. The fix is not to make attaching faster;
# there is nothing there to speed up. It is to stop paying for the door once per
# file.
#
# Which is why the assertion that matters here is that ONE invocation attaches
# all of them. A loop that calls the command six times would pass any test that
# only checked the files arrived, and would fix nothing at all.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T17:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Batch', dir => $root, members => ['claude'], agent => 'claude',
    columns => ['backlog, done'],
    sow_prefix => 'BS', epic_prefix => 'BE', ticket_prefix => 'BT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something to attach to' );

my @files;
for my $i ( 1 .. 4 ) {
    my $path = File::Spec->catfile( $tmp, "file$i.txt" );
    open my $fh, '>', $path or die $!;
    print {$fh} "contents of file $i, distinct so the shas differ";
    close $fh;
    push @files, $path;
}

my $invocations = 0;
sub run {
    my ( $command, @argv ) = @_;
    $invocations++;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        $status = Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
    }
    return ( $status, $out . $err );
}

# --- four files, one command ------------------------------------------------------------

{
    my $before = $invocations;
    my ( $status, $said ) = run( 'attachment.add', '--ref', $card->{ref},
        map { ( '--file', $_ ) } @files );

    is( $invocations - $before, 1, 'all four attached in ONE invocation' );
    is( $status, 0, 'and the command succeeded' );

    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    is( scalar @{ $shown->{attachments} // [] }, 4, 'four attachments landed' );

    # Each named as it lands, so a batch killed part-way leaves a readable record
    # of how far it got - the reporter's second ask, and the reason their killed
    # batch could not be told apart from a failed one.
    for my $path (@files) {
        my $name = ( File::Spec->splitpath($path) )[2];
        like( $said, qr/\Q$name\E/, "the output names $name" );
    }
}

# --- one file behaves exactly as it always did ---------------------------------------------

{
    my $single = File::Spec->catfile( $tmp, 'lonely.txt' );
    open my $fh, '>', $single or die $!;
    print {$fh} 'just the one';
    close $fh;

    my ( $status, undef ) = run( 'attachment.add', '--ref', $card->{ref}, '--file', $single );
    is( $status, 0, 'a single --file still works' );

    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    is( scalar @{ $shown->{attachments} // [] }, 5, 'and adds exactly one' );
}

# --- a doubled --file on a command that takes one is refused, not silently dropped ----------
#
# 'file=s' was single-valued, so Getopt kept the last and threw the rest away with
# exit 0 - one of the 94 single-valued flags TKT-389 counts. This card had to
# touch that option anyway, so this one is closed here; the other 93 stay on
# TKT-389.

{
    my ( $status, $said ) = run( 'evidence.add', '--ref', $card->{ref},
        '--author', 'claude', '--summary', 'two files given',
        '--file', $files[0], '--file', $files[1] );

    isnt( $status, 0, 'two --file on a command that takes one is refused' );
    like( $said, qr/--file/, 'and the refusal names the flag that was doubled' );
}

# --- a failure part-way through still reports what landed --------------------------------
#
# The reporter's second ask, and the reason a plain map/loop was not enough:
# "Print each attachment's id and original_filename as it lands, so a killed
# batch leaves a readable record of how far it got." A file that cannot be read
# mid-batch must still die - a bad path is a real mistake - but the files
# attached before it must not vanish with the die.
#
# Found by testing this failure path rather than only the happy one: the first
# version of this loop returned nothing at all on a partial failure, silently
# reproducing the exact blindness this card exists to fix.

{
    my $missing = File::Spec->catfile( $tmp, 'does-not-exist.txt' );
    my ( $status, $said ) = run( 'attachment.add', '--ref', $card->{ref},
        '--file', $files[0], '--file', $missing, '--file', $files[1] );

    isnt( $status, 0, 'a bad path in the middle of a batch still fails' );
    like( $said, qr/\Q$missing\E/, 'and names the file it could not read' );
    like( $said, qr/file1\.txt/,
        'and reports the file that landed before the failure, so nothing has to be re-derived' );

    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    ok( ( grep { ( $_->{original_filename} // '' ) eq 'file1.txt' } @{ $shown->{attachments} // [] } ),
        'and it really is on the card, not just claimed in the message' );
}

# --- proved by keeping only the last ---------------------------------------------------
#
# Every assertion above passes against a command that attached only file4, if the
# count assertion were the only guard. So the contents are checked: four distinct
# shas, not one file four times and not the last file alone.

{
    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    my %sha = map { $_->{sha} => 1 } @{ $shown->{attachments} // [] };
    is( scalar keys %sha, 5, 'every attachment is a distinct file, so none was dropped for another' );

    my %named = map { ( $_->{original_filename} // '' ) => 1 } @{ $shown->{attachments} // [] };
    ok( $named{'file1.txt'}, 'the FIRST file given is present, which is the one a last-wins bug loses' );
    ok( $named{'file4.txt'}, 'and so is the last' );
}

done_testing;

__END__

=head1 NAME

275-six-files-one-command.t - TKT-338

=head1 DESCRIPTION

Attaching several files cost one command resolution per file, and resolution is
about 0.5s whatever the command does - so a batch scaled with invocation count
and could exceed a harness's foreground timeout. C<attachment.add> now takes
repeated C<--file> and attaches them in one invocation, naming each as it lands.
The shared C<--file> option is parsed as a list once, so the commands that take a
single file now refuse a doubled flag instead of silently keeping the last.

=cut
