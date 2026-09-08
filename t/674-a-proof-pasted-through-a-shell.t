#!/usr/bin/env perl
# TKT-674. Every gate step costs a --command/--proof pair, and the board's
# own standing rule is that a proof must be real captured output, not a
# hand-written summary. The only way to supply one was a shell argument, so
# real output - quotes, backslashes, newlines, the very error messages being
# proved - had to survive shell quoting to reach the card. --proof-file gives
# the proof half the file (and stdin, via a single dash) form the
# neighbouring comment.add/--file already has, reusing _text_input, and pairs
# positionally with --command exactly as a literal --proof does.
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
    name => 'Proofly', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PFS', epic_prefix => 'PFE', ticket_prefix => 'PFT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

sub write_proof_file {
    my ($content) = @_;
    my ( $fh, $filename ) = tempfile( DIR => $tmp, UNLINK => 1 );
    binmode $fh, ':raw';
    print {$fh} $content;
    close $fh;
    return $filename;
}

sub run {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $status = eval { Tira::CLI->run( command => 'required-action.update', tira => $tira, argv => \@argv ) };
    select $old;
    return ( $status, $stdout, $said // '' );
}

sub add_item {
    my ($item) = @_;
    return $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        item => $item, status => 'pending' )->{id};
}

# --- a proof read from a file, byte for byte --------------------------------

{
    my $id = add_item('File proof');
    my $content = "Captured output.\nSecond line.\n";
    my $file = write_proof_file($content);
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'ran it', '--proof-file', $file );
    is( $status, 0, "marking $id done with --proof-file succeeds" ) or diag($said);
    my $item = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$item};
    is( $entry->{proof}[0]{proof}, $content, 'the stored proof matches the file byte for byte' );
}

# --- a single dash reads stdin ----------------------------------------------

{
    my $id = add_item('Stdin proof');
    my $content = "From standard input.\n";
    open my $in, '<', \$content or die $!;
    local *STDIN = $in;
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'ran it', '--proof-file', '-' );
    is( $status, 0, "marking $id done with --proof-file - succeeds" ) or diag($said);
    my $item = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$item};
    is( $entry->{proof}[0]{proof}, $content, 'stdin content lands as the proof' );
}

# --- two pairs, one literal proof and one from a file, each keeps its own --

{
    my $id = add_item('Two pairs, one item');
    my $file_content = "second pair's captured output\n";
    my $file = write_proof_file($file_content);
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id,
        '--status', 'done', '--author', 'claude',
        '--command', 'first command', '--command', 'second command',
        '--proof', 'first literal proof', '--proof-file', $file );
    is( $status, 0, 'two pairs, one literal and one file, both succeed' ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{proof}, 'first literal proof', 'the first pair kept its literal proof' );
    is( $entry->{proof}[1]{proof}, $file_content, 'the second pair kept its file proof' );
}

# --- both a literal and a file for one pair is refused ---------------------

{
    my $id = add_item('Ambiguous pair');
    my $file = write_proof_file("irrelevant\n");
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'one command',
        '--proof', 'a literal proof', '--proof-file', $file );
    is( $status, 2, 'a single command with both --proof and --proof-file is refused' );
    like( $said, qr/--proof/, 'the refusal names --proof' );
    like( $said, qr/--proof-file/, 'and --proof-file' );
}

# --- quotes, backslashes and newlines survive the file path unchanged ------

{
    my $id = add_item('Quoting torture');
    my $content = qq{"quoted", a \\backslash\\, and\nmultiple\nlines\n};
    my $file = write_proof_file($content);
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'ran it', '--proof-file', $file );
    is( $status, 0, 'a proof full of quoting hazards still succeeds via --proof-file' ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{proof}, $content, 'the hazardous content survives byte for byte' );
}

# --- a --proof-file naming nothing readable is a clean refusal, not a crash -

{
    my $id = add_item('Unreadable file');
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'ran it', '--proof-file', '/nonexistent/path/xyz' );
    is( $status, 2, 'a --proof-file naming an unreadable path exits 2, not a raw crash' );
    like( $said, qr/Cannot read/, 'and the refusal names the read failure' );
}

# --- existing literal-only calls are unaffected -----------------------------

{
    my $id = add_item('Plain literal');
    my ( $status, undef, $said ) = run( '--ref', $card->{ref}, '--id', $id, '--status', 'done',
        '--author', 'claude', '--command', 'ran it', '--proof', 'a plain literal proof' );
    is( $status, 0, 'a literal-only call still succeeds' ) or diag($said);
    my $items = $tira->required_item_list( project => $root, ref => $card->{ref} );
    my ($entry) = grep { $_->{id} eq $id } @{$items};
    is( $entry->{proof}[0]{proof}, 'a plain literal proof', 'and its proof is stored exactly as given' );
}

done_testing();

__END__

=head1 NAME

674-a-proof-pasted-through-a-shell.t - --proof-file reads a captured proof
from a file or stdin instead of a shell argument

=head1 DESCRIPTION

TKT-674. C<--proof-file>, paired positionally with C<--command> the same
way a literal C<--proof> is, reuses C<_text_input> so a single dash means
stdin. Supplying both a literal C<--proof> and a C<--proof-file> for what
would be the same pair is refused rather than silently resolved, matching
C<comment.add>'s own "use only one of --text or --file" guard. Every
existing literal-only call is unaffected.

=cut
