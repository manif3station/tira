#!/usr/bin/env perl
# A clean board and a stopped detector return the same bytes, and nothing a
# caller can run tells them apart.
#
#     tira.police.outstanding -o json   ->  []      board is clean
#     tira.police.outstanding -o json   ->  []      bridge died eleven hours ago
#
# Measured on the live board, 2026-08-29: the payload is a bare list whose
# elements carry action, assignee, first_seen, id, last_seen, policy, ref, rule,
# seen and tone. No pass timestamp anywhere, and an empty list has nowhere to put
# one. The consumer this hurts is named in the code's own comment at
# lib/Tira/CLI/Police.pm:457 - the clear-violations loop, which is automated and
# is exactly the reader that would keep reporting a clean board while nothing was
# watching.
#
# THE PAYLOAD IS NOT CHANGING, and that is a decision rather than an oversight.
# Q-096, answered by the owner and marked ok: "Keep the bare list and add a
# separate command for freshness, e.g. tira.police.freshness. Nothing breaks
# anywhere; the cost is a second command to remember and a question answered
# somewhere other than where it is asked." Two other projects pipe and index that
# list, and docs/commands.md promises it stays one. TKT-354 chose the opposite for
# tira.next in 3.48 - one shape always - and the precedent does not transfer,
# because that command had no documented consumers outside this board.
#
# So this file tests the NEW command, and asserts the old payload is untouched.
# The human-output half is t/434, written before the shape was settled because it
# never depended on it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-29T03:38:41+0100';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Fresh', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'FS', epic_prefix => 'FE', ticket_prefix => 'FT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => $tira,
            argv => [ '--store', $store, @argv ] );
    };
    return ( $status, $out . $err );
}

# --- a board nobody has policed -----------------------------------------------
#
# Asserted first because it is the case the whole card turns on: "nothing has
# been checked" and "nothing is wrong" must not be the same answer. A freshness
# command that reported a never-policed board as fresh would be worse than no
# command, since it would put a confident number on an absence.

{
    my ( $status, $said ) = run('police.freshness');
    is( $status, 0, 'asking a board nobody has policed is not an error' );
    like( $said, qr/never|no pass|not been/i,
        'and it says no pass has ever run, rather than reporting freshness it '
          . 'cannot have measured' );
    # Asserted against the JSON rather than the prose. The human sentence is
    # "This board has never been policed, so nothing has been checked", which
    # correctly does not call the board fresh - it simply does not use the word
    # "stale", and the first version of this demanded it did. The machine-
    # readable judgement is where the requirement actually lives.
    my ( undef, $json ) = run( 'police.freshness', '-o', 'json' );
    my $never = eval { Cpanel::JSON::XS::decode_json($json) };
    ok( ref $never eq 'HASH' && $never->{stale} && !defined $never->{taken_at},
        'and reports it as stale with no pass time - an absence of evidence is '
          . 'not evidence of a recent pass, and a caller must not read it as one' );
}

$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
$tira->police_pass( project => $root, store => $store, world => {} );

# --- ten seconds after a pass -------------------------------------------------

$now = '2026-08-29T03:38:51+0100';

{
    my ( $status, $said ) = run( 'police.freshness', '-o', 'json' );
    is( $status, 0, 'freshness on a live board is not an error' );

    my $answer = eval { Cpanel::JSON::XS::decode_json($said) };
    # Guarded on the KEYS, not on being a hash. An unsupported command answers
    # with { error: ... } under -o json, which is also an object - so the bare
    # ref test passes against a command that does not exist, which is a green
    # that means nothing.
    ok( ref $answer eq 'HASH' && exists $answer->{taken_at},
        'the JSON answer is an object carrying the pass time - which is what '
          . 'the bare list cannot do when it is empty' );

    is( $answer->{taken_at}, '2026-08-29T03:38:41+0100',
        'it names the pass it is reporting on' );
    cmp_ok( $answer->{age_seconds}, '==', 10,
        'and how old that pass is, in seconds, so a caller does no arithmetic' );
    # exists, then false. Without the exists, an error object with no stale key
    # satisfies this by not having the field at all.
    ok( exists $answer->{stale} && !$answer->{stale},
        'and judges it: ten seconds after a pass, the board is not stale' );
}

# --- eleven hours after a pass ------------------------------------------------
#
# The zenandi reading, exactly: a pass at 03:38:41 and a look at 14:41:50, with
# nothing in between. Its outstanding said "No violations outstanding" all day.

$now = '2026-08-29T14:41:50+0100';

{
    my ( undef, $said ) = run( 'police.freshness', '-o', 'json' );
    my $answer = eval { Cpanel::JSON::XS::decode_json($said) };

    is( $answer->{taken_at}, '2026-08-29T03:38:41+0100',
        'the pass time has not moved, because no pass has run' );
    cmp_ok( $answer->{age_seconds}, '>', 39_000,
        'the age has, and is reported as a number rather than left to be '
          . 'computed - ' . ( $answer->{age_seconds} // 'undef' ) . ' seconds' );
    ok( $answer->{stale},
        'and the judgement is the point: eleven hours with no pass is stale, '
          . 'said by the command rather than worked out by the reader' );
}

# --- a stamp that is present but unreadable is stale, not fresh ---------------
#
# FOUND BY REVIEW, not by writing the test first, and it was this card's own
# fault turned inward. Both timestamp conversions are guarded, so a corrupt
# last_pass left the age undefined - and the first version of the condition only
# asked whether a DEFINED age exceeded the threshold, so it answered stale => 0.
# A broken instrument reporting health, which is the exact thing being removed.
#
# Three ways to be stale and they are one idea: the pass time is missing,
# unreadable, or old. In none of them can the board's silence be trusted.

{
    my $ledger = File::Spec->catfile( $store, 'violations.json' );
    open my $in, '<', $ledger or die "$ledger: $!";
    my $held = do { local $/; <$in> };
    close $in;

    my $corrupt = $held;
    $corrupt =~ s/"last_pass"\s*:\s*"[^"]*"/"last_pass":"not-a-timestamp"/;
    isnt( $corrupt, $held, 'the ledger has a last_pass to corrupt' );

    open my $out2, '>', $ledger or die "$ledger: $!";
    print {$out2} $corrupt;
    close $out2;

    my ( undef, $said ) = run( 'police.freshness', '-o', 'json' );
    my $answer = eval { Cpanel::JSON::XS::decode_json($said) };
    ok( ref $answer eq 'HASH' && $answer->{stale},
        'a pass time that cannot be read is reported stale - an unreadable '
          . 'instrument is not a healthy one' );
    ok( !defined $answer->{age_seconds},
        'and no age is invented for it' );

    my ( undef, $human ) = run('police.freshness');
    like( $human, qr/unreadable/i,
        'and the human output says it cannot be read, rather than printing the '
          . 'value as though it were usable' );

    open my $back, '>', $ledger or die "$ledger: $!";
    print {$back} $held;
    close $back;
}

# --- and the payload it was added to protect is untouched ---------------------
#
# THE OTHER HALF OF THE DECISION. The whole reason for a second command is that
# -o json keeps its shape, so this asserts that shape rather than trusting it -
# a change here breaks two other projects' clear-violations loops silently, in
# the one command they use to decide whether work is finished.

{
    my ( undef, $said ) = run( 'police.outstanding', '-o', 'json' );
    my $payload = eval { Cpanel::JSON::XS::decode_json($said) };
    is( ref $payload, 'ARRAY',
        'tira.police.outstanding -o json is still a bare list, which is what '
          . 'the clear-violations loop pipes and indexes' );
}

# --- the command is reachable the way every other one is ----------------------

{
    my ( $status, $said ) = run('police.freshness');
    isnt( $status, 2, 'police.freshness is a command this tool knows - ' .
        ( $said =~ /Unsupported|not found/i ? 'it does not: ' . ( $said =~ s/\s+/ /gr ) : 'it does' ) );
}

done_testing();

__END__

=head1 NAME

t/436-a-command-that-answers-when-the-pass-was.t - C<tira.police.freshness> must
say when the last pass ran and whether that is recent enough to trust

=head1 DESCRIPTION

C<tira.police.outstanding -o json> returns a bare list. On a clean board that is
C<[]>, and on a board whose policy bridge died eleven hours ago it is also
C<[]> - the same bytes, with no field to compare and no arithmetic a caller
could do. Measured on zenandi on 2026-08-29: a pass at 03:38:41, read at
14:41:50, unchanged, while the board reported itself clean all day.

=head2 Why a new command rather than a richer payload

Q-096, answered by the owner and marked ok: keep the bare list, add a separate
command. Two other projects pipe and index that payload, and C<docs/commands.md>
promises it stays a list. C<TKT-354> chose one-shape-always for C<tira.next> in
3.48, and that precedent does not transfer - that command had no documented
consumers outside this board.

=head2 What is asserted

That a never-policed board is not reported as fresh, which is the case the card
turns on: "nothing has been checked" and "nothing is wrong" must not be the same
answer. That a live board reports its pass time, the age in seconds, and a
judgement, so a caller acts on one field instead of doing arithmetic. That
eleven hours with no pass is called stale. And that
C<tira.police.outstanding -o json> is still a bare list, because the entire
reason for a second command is that the first one's shape does not move.

=cut
