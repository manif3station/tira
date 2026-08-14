#!/usr/bin/env perl
# Nothing typed into a record command is silently discarded.
#
# tira.evidence.add took --details, exited zero, and stored nothing. The entry
# it writes carries summary, uri, author and attachment; details is not one of
# its fields. The command prints the entry it made and the entry looks complete,
# because the summary is there - so nothing in the output suggests that half of
# what was typed went nowhere.
#
# This test exists because of its own damage. Every card worked through the
# night recorded its evidence with --details, and all of that reasoning is gone;
# only the summaries survived. It is not recoverable from the board, and
# reconstructing it from memory would be worse than the gap.
#
# It is the assign.set --assignee shape exactly: an option the parser knows for
# another command, accepted here and dropped. That one took two attempts and a
# screenshot from the owner before anybody believed it, and the refusal built
# for it is the right home for this.
#
# Refused rather than stored. Storing it would add a field to evidence under
# cover of a bug fix - the same trade rejected for the base policy field and for
# --token. Whether evidence should carry a body as well as a summary is a
# question about what evidence is, and belongs on its own card.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Substance', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'SBS', epic_prefix => 'SBE', ticket_prefix => 'SBT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Proved how?' );

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => $command, tira => $tira,
            argv => [ '--project', $root, @argv ] );
    };
    return ( $status, $out, $err );
}

# --- the reasoning that used to disappear ---------------------------------------

my ( $status, undef, $err ) = run( 'evidence.add', '--ref', $card->{ref}, '--author', 'michael',
    '--summary', 'the coverage figure', '--details', 'taken on an idle tree, twice' );
isnt( $status, 0, 'evidence.add refuses details rather than dropping them' );
like( $err, qr/--summary/, 'and names the option that carries what was written' );
is( scalar @{ $tira->evidence_list( project => $root, ref => $card->{ref} ) }, 0,
    'with nothing recorded, where the old behaviour recorded half of it and said nothing' );

# --- while evidence itself still works ------------------------------------------

is( ( run( 'evidence.add', '--ref', $card->{ref}, '--author', 'michael',
        '--summary', 'the coverage figure, taken on an idle tree, twice',
        '--uri', 'https://example.invalid/run/1' ) )[0], 0,
    'evidence with a summary and a link is recorded' );
my ($recorded) = @{ $tira->evidence_list( project => $root, ref => $card->{ref} ) };
is( $recorded->{summary}, 'the coverage figure, taken on an idle tree, twice',
    'and the summary is what was written' );
is( $recorded->{uri}, 'https://example.invalid/run/1', 'with its link' );

# --- and the command that details really belongs to -------------------------------
#
# The reason this is a refusal and not a new field. gate.add has always stored
# details, which is why the option exists at all, and refusing it there would
# take away the thing evidence was accidentally borrowing.

is( ( run( 'gate.add', '--ref', $card->{ref}, '--author', 'michael', '--gate', 'the suite',
        '--result', 'pass', '--details', 'four thousand tests, on an idle tree' ) )[0], 0,
    'a gate still takes details' );
my ($gate) = @{ $tira->gate_list( project => $root, ref => $card->{ref} ) };
is( $gate->{details}, 'four thousand tests, on an idle tree',
    'and stores them, which is where details belongs' );

# --- an option nobody declared is still simply unknown -----------------------------
#
# This adds a refusal for an option the parser knows. It must not turn an
# unknown option into a different kind of error.

( $status, undef, $err ) = run( 'evidence.add', '--ref', $card->{ref}, '--author', 'michael',
    '--summary', 's', '--nonsense', 'x' );
isnt( $status, 0, 'an option that does not exist is still refused' );
like( $err, qr/Unknown option|Invalid command-line/i, 'as an unknown option, not as a misused one' );

done_testing;

__END__

=head1 NAME

153-evidence-that-lost-its-substance.t - nothing typed into a record command is discarded

=head1 DESCRIPTION

C<tira.evidence.add> took C<--details>, exited zero and stored nothing: the entry
carries a summary, a link, an author and an attachment, and the details were
dropped without a word. The printed entry looked complete because the summary
was there.

It is now refused, naming C<--summary>, alongside the assign commands that refuse
C<--assignee>. C<gate.add> still stores details, which is where the option
belongs and why it exists.

=cut
