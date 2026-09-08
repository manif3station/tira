#!/usr/bin/env perl
# TKT-711. --proof-file lets evidence come from a file instead of a shell
# argument (TKT-674); --command had no equivalent, so an agent whose real
# captured command line was long or hazardous to quote had no way in but
# pasting a summary - the exact behaviour the evidence rule exists to stop.
# --command-file gives --command the same file/stdin path --proof-file
# already has, on both checklist.update and required-action.update.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-08T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Commandly', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CFS', epic_prefix => 'CFE', ticket_prefix => 'CFT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

sub write_file {
    my ($content) = @_;
    my ( $fh, $filename ) = tempfile( DIR => $tmp, UNLINK => 1 );
    binmode $fh, ':raw';
    print {$fh} $content;
    close $fh;
    return $filename;
}

sub run {
    my ( $command, @argv ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $status = eval { Tira::CLI->run( command => $command, tira => $tira, argv => \@argv ) };
    select $old;
    return ( $status, $stdout, $said // '' );
}

sub add_item {
    my ($item) = @_;
    return $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        item => $item, status => 'pending' )->{id};
}

# --- required-action.update: a command read from a file, byte for byte ----

{
    my $id = add_item('File command');
    my $content = "prove -lv t/example.t\n";
    my $file = write_file($content);
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude', '--command-file', $file, '--proof', 'ok' );
    is( $status, 0, "marking $id done with --command-file succeeds" ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{command}, $content, 'the stored command matches the file byte for byte' );
}

# --- a single dash reads stdin ---------------------------------------------

{
    my $id = add_item('Stdin command');
    my $content = "From standard input.\n";
    open my $in, '<', \$content or die $!;
    local *STDIN = $in;
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude', '--command-file', '-', '--proof', 'ok' );
    is( $status, 0, "marking $id done with --command-file - succeeds" ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{command}, $content, 'stdin content lands as the command' );
}

# --- both a literal and a file for one pair is refused ---------------------

{
    my $id = add_item('Ambiguous pair');
    my $file = write_file("irrelevant\n");
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude',
        '--command', 'literal command', '--command-file', $file, '--proof', 'ok' );
    is( $status, 2, 'a single pair with both --command and --command-file is refused' );
    like( $said, qr/--command/, 'the refusal names --command' );
    like( $said, qr/--command-file/, 'and --command-file' );
}

# --- checklist.update gets the identical --command-file -------------------

{
    $tira->checklist_add( project => $root, type => 'ticket', ref => $card->{ref},
        item => 'Do the thing', status => 'pending', author => 'claude' );
    my $content = "docker compose run perl-test prove -lr t\n";
    my $file = write_file($content);
    my ( $status, undef, $said ) = run( 'checklist.update', '--ref', $card->{ref}, '--id', 'CHK-001',
        '--status', 'done', '--author', 'claude', '--command-file', $file, '--proof', 'ok' );
    is( $status, 0, 'checklist.update accepts --command-file the same way' ) or diag($said);
    my $card_now = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq 'CHK-001' } @{ $card_now->{checklist} };
    is( $entry->{proof}[0]{command}, $content, 'and the stored command matches the file byte for byte' );
}

# --- an empty file is refused the way an empty --command already is -------

{
    my $id = add_item('Empty command file');
    my $file = write_file("   \n");
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude', '--command-file', $file, '--proof', 'ok' );
    isnt( $status, 0, 'a whitespace-only --command-file is refused' );
    like( $said, qr/--command/, 'naming --command, the same as an empty literal would' );
}

# --- non-ASCII content survives the file path unchanged --------------------

{
    my $id = add_item('Non-ASCII command');
    # The file holds UTF-8 BYTES (as any real captured output would); what
    # comes back through the engine is the DECODED character string, since
    # _text_input(..., utf8 => 1) decodes it on the way in, the same as
    # --proof-file already does.
    my $bytes = "prove -lv t/caf\xc3\xa9.t \xe2\x80\x94 the accented file\n";
    my $decoded = "prove -lv t/caf\x{e9}.t \x{2014} the accented file\n";
    my $file = write_file($bytes);
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude', '--command-file', $file, '--proof', 'ok' );
    is( $status, 0, 'a --command-file full of non-ASCII bytes succeeds' ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{command}, $decoded, 'and the non-ASCII content decodes correctly and round-trips' );
}

# --- existing literal-only calls are unaffected -----------------------------

{
    my $id = add_item('Plain literal');
    my ( $status, undef, $said ) = run( 'required-action.update', '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude', '--command', 'a plain literal command', '--proof', 'ok' );
    is( $status, 0, 'a literal-only call still succeeds' ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{command}, 'a plain literal command', 'and its command is stored exactly as given' );
}

done_testing();

__END__

=head1 NAME

711-a-command-pasted-through-a-shell.t - --command-file reads a captured
command from a file or stdin instead of a shell argument

=head1 DESCRIPTION

TKT-711. C<--command-file>, paired positionally with C<--proof> the same
way a literal C<--command> is, reuses C<_text_input> so a single dash
means stdin - the same shape C<--proof-file> already has (TKT-674).
Supplying both a literal C<--command> and a C<--command-file> for what
would be the same pair is refused. C<checklist.update> gets the identical
option, since both commands already share the same pair-validation
engine code. Every existing literal-only call is unaffected.

=cut
