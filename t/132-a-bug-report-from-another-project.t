#!/usr/bin/env perl
# An agent working on something else can report a fault in Tira.
#
# His words: "This command is for other projects core agent to report bugs or
# improvement about tira. When other projects core agent run it, it will raise a
# ticket on your board at the backlog. Not their board. They report and done
# their part. Simple."
#
# Every project on this machine uses Tira and none of them could report a fault
# in it. Their agent works on their own board; Tira's board is somewhere else,
# and reaching it means knowing which board to reach and how to point at it -
# which is exactly what this skill's instructions do not say, deliberately. So a
# fault found by the agent best placed to describe it either went through a
# human or went nowhere.
#
# The wrapper carries the destination. The caller says what it found and which
# project it is, and nothing else.
#
# Raised as the owner, because an agent in another project is not a member of
# this board and inventing one member per caller would fill the roster with
# names nobody here works with. The origin is carried as a label instead - so
# the report can be found again, and answered on the card.

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
my $tira = Tira->new( clock => sub {'2026-08-13T15:00:00Z'} );

# Tira's own board, wherever it is. The command finds it by a name rather than
# by a path, so the test hands it the same kind of answer the dashboard would.
my $home = File::Spec->catdir( $tmp, 'tira-itself' );
$tira->project_new(
    name => 'Tira', dir => $home, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TRS', epic_prefix => 'TRE', ticket_prefix => 'TKT',
);

# Somebody else's board, which must not be touched. Same ticket prefix on
# purpose: if the report landed here it would look plausible.
my $theirs = File::Spec->catdir( $tmp, 'their-project' );
$tira->project_new(
    name => 'Their project', dir => $theirs, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'THS', epic_prefix => 'THE', ticket_prefix => 'TKT',
);
$tira->create_record( project => $theirs, type => 'ticket', title => 'Their own work' );

sub report {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        no warnings 'redefine';

        # Standing in their project, as their agent would be, and the dashboard
        # resolving the name Tira ships with.
        local *Tira::CLI::_tira_home = sub { $home };
        Tira::CLI->run( command => 'dev.found.bug_or_improvement', tira => $tira, argv => \@argv );
    };
    return ( $status, $out, $err );
}

# --- the origin is required ---------------------------------------------------
#
# A report nobody can go back to is one nobody can answer, and he said he
# answers these himself.

my ( $status, $out, $err ) = report( '--title', 'Something is wrong' );
isnt( $status, 0, 'a report with no origin is refused' );
like( $err, qr/--from/, 'and says how to give one' );

# --- and so is something to report --------------------------------------------

( $status, $out, $err ) = report( '--from', 'telegram-codex' );
isnt( $status, 0, 'a report with no title is refused' );

# --- a report lands on Tira's board -------------------------------------------

( $status, $out ) = report(
    '--from', 'telegram-codex',
    '--title', 'police.log looks like part of police',
    '--text', 'Told that police was the owner\'s, my agent gave up the log too.',
    '-o', 'json',
);
is( $status, 0, 'an agent in another project can report a fault in Tira' );
my $raised = decode_json($out);
like( $raised->{ref}, qr/\ATKT-/, 'and gets back the card it raised' );

my $card = $tira->record_show( project => $home, ref => $raised->{ref} );
is( $card->{title}, 'police.log looks like part of police', 'the report is on Tira\'s board' );
is( $card->{column}, 'backlog', 'in the backlog, because where it goes is this board\'s decision' );
is( $card->{reporter}, 'michael',
    'reported as the owner, because an agent elsewhere is not a member here' );
is_deeply( $card->{labels}, ['telegram-codex'],
    'and labelled with where it came from, so it can be found and answered' );
like( $card->{description}, qr/gave up the log too/, 'carrying what was actually found' );
like( $card->{source}, qr/telegram-codex/i, 'and saying it came from outside' );

# --- and their board is untouched ----------------------------------------------
#
# The whole point. Their agent reported a Tira fault and their own board did not
# change - not one card, on a board using the same ticket prefix.

my $their_cards = $tira->record_list( project => $theirs, type => 'ticket' );
is( scalar @{$their_cards}, 1, 'their board still holds exactly what it held' );
is( $their_cards->[0]{title}, 'Their own work', 'and it is their own work' );

# --- a second report is a second card ------------------------------------------

( $status, $out ) = report( '--from', 'mt5-ai', '--title', 'Another thing', '-o', 'json' );
is( $status, 0, 'another project can report too' );
my $second = decode_json($out);
isnt( $second->{ref}, $raised->{ref}, 'and gets its own card' );
is_deeply( $tira->record_show( project => $home, ref => $second->{ref} )->{labels},
    ['mt5-ai'], 'labelled with its own origin' );

# --- the caller is never told where the board is --------------------------------
#
# The standing rule for this skill's instructions, applied to what the command
# says back. A report that answered with a path would teach the caller the one
# thing it must not know.

unlike( $out, qr{\Q$home\E}, 'the answer does not say where the board is' );
unlike( $err, qr{\Q$home\E}, 'and neither does anything it printed on the way' );

# --- finding the board it reports to -------------------------------------------
#
# The seam every test above stands on, tested rather than assumed. It asks the
# dashboard for a name, not a path - so on somebody else's machine it resolves
# to their Tira, which is right: a bug report belongs to whoever owns the copy
# that has the bug.

{
    no warnings 'redefine';
    local *Tira::CLI::_dd_path_resolver = sub { sub { '/somewhere/tira' } };
    is( Tira::CLI::_tira_home(), '/somewhere/tira',
        'the board is found by asking for a name' );
}

# And when it cannot be found, it says something a person can act on rather than
# failing where the resolver failed. An agent in another project cannot fix a
# path registry it has never heard of.

for my $unhelpful ( sub { die "no such name\n" }, sub {undef}, sub {''} ) {
    no warnings 'redefine';
    local *Tira::CLI::_dd_path_resolver = sub {$unhelpful};
    my $refused = !eval { Tira::CLI::_tira_home(); 1 };
    ok( $refused, 'a board that cannot be found is a refusal' );
    like( $@, qr/maintains Tira/,
        'saying what to do instead, rather than where the lookup failed' );
}

done_testing;

__END__

=head1 NAME

132-a-bug-report-from-another-project.t - reporting a Tira fault from elsewhere

=head1 DESCRIPTION

Every project on this machine uses Tira and none of them could report a fault in
it, because reaching Tira's board means knowing which board to reach - which
this skill's instructions deliberately do not say.

C<tira.dev.found.bug_or_improvement> carries the destination itself. The caller
gives what it found and C<--from>, its own project name; the card is raised in
Tira's backlog as the owner, labelled with the origin so it can be answered, and
the caller's own board is untouched. An origin is required, because a report
nobody can go back to is one nobody can answer.

=cut
