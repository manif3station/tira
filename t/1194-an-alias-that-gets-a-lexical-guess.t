#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# TKT-1194. The "Did you mean" list for an unknown option is computed by edit
# distance alone (TKT-298), so a caller who reaches for a common alias of a real
# flag gets the nearest LETTERS, not the nearest MEANING. On comment.add the
# content flag is --text; --body is what most other tools call it. body is two
# edits from bdd and from mode, and four from text, so the answer offered was
# --bdd, --mode and --atdd - three flags that have nothing to do with a comment,
# printed as if they were guidance - and the flag that was meant never appeared.
#
# What is held here: the alias is answered with the flag it stands for, the
# nonsense neighbours are not offered next to it, and an ordinary one-letter
# typo is still answered the way TKT-298 answered it.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-29T22:40:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Aliased', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ALS', epic_prefix => 'ALE', ticket_prefix => 'ALT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that must not be touched by a refused call', priority => 3 );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'comment.add', tira => $tira, argv => [ '--author', 'claude', @argv ] );
    };
    return ( $status, $out . $err );
}

# --- the exact case reported: --body where --text was meant -----------------

{
    my ( $status, $said ) = run( '--ref', $card->{ref}, '--body', 'hello' );
    isnt( $status, 0, '--body is still refused, it is not an option of this command' );
    like( $said, qr/Unknown option:\s*body/, 'and named the way it always was' );
    like( $said, qr/--text\b/, 'but the flag that was meant, --text, is now offered' );
    unlike( $said, qr/--(?:bdd|mode|atdd)\b/, 'and the three unrelated near-letters are not offered beside it' );
}

# --- the refusal wrote nothing ----------------------------------------------

{
    my $after = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is_deeply( $after->{comments} || [], [], 'the refused call added no comment' );
}

# --- a second alias of the same flag -----------------------------------------

for my $alias (qw(content)) {
    my ( undef, $said ) = run( '--ref', $card->{ref}, "--$alias", 'hello' );
    like( $said, qr/--text\b/, "--$alias is answered with --text as well" );
}

# --- an alias is only used where the command has the flag it points at ------

{
    # Every command shares one parsed option list, so no real command can lack --text;
    # the guard is held by calling the message builder with a list that does.
    require Tira::CLI::Usage;
    my $said = Tira::CLI::Usage::_unknown_option_message( ['body'], [ 'ref=s' => \my $ref, 'title=s' => \my $title ] );
    like( $said, qr/Unknown option: body/, 'an alias is still named as unknown where its flag is not declared' );
    unlike( $said, qr/--text\b/, 'and --text is not invented for a list that does not declare it' );
}

# --- controls: an ordinary typo keeps the answer it always had --------------

{
    my ( undef, $said ) = run( '--ref', $card->{ref}, '--txet', 'hello' );
    like( $said, qr/Unknown option:\s*txet/, 'a transposed-letters typo is still named' );
    like( $said, qr/--text\b/, 'and still answered with the flag it was typed from' );
}

# --- and a token far from everything still gets no false guess --------------

{
    my ( undef, $said ) = run( '--ref', $card->{ref}, '--zzzzzzzz', 'hello' );
    like( $said, qr/Unknown option:\s*zzzzzzzz/, 'a nonsense name is still refused by name' );
    unlike( $said, qr/Did you mean/, 'and offered no guess at all' );
}

done_testing;

__END__

=head1 NAME

1194-an-alias-that-gets-a-lexical-guess.t - a common alias is answered with the flag it stands for

=head1 DESCRIPTION

TKT-1194. The unknown-option suggestion list is edit distance only, so
C<comment.add --body> was answered with C<--bdd>, C<--mode> and C<--atdd> and
never with C<--text>, the flag that carries a comment's content. This file holds
that C<--body> and C<--content> are answered with C<--text>, that
the unrelated near-letter flags are not offered beside it, that the refused call
wrote nothing, and, as controls, that a transposed-letters typo still gets the
suggestion TKT-298 built and a nonsense name still gets none.

=cut
