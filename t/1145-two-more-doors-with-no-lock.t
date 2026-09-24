#!/usr/bin/env perl
# TKT-1145. record_move already refuses a departure with an unmet required
# item for every caller (TKT-1144's own t/1158) - but _column_chain_violation
# (refuses skipping a column) and _unjudged_answer_violation (refuses a move
# while a card carries an answer nobody has judged) both still live only in
# the CLI dispatch layer (Tira::CLI.pm's run(), called before
# $tira->record_move). A caller reaching record_move a different way (the
# same class of gap TKT-1144 closed for the required-action check) can skip
# a column entirely, or move a card with an unjudged answer, with no
# exemption and no reason recorded.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );

sub recording {
    my $path = File::Spec->catfile( $tmp, 'question.ogg' );
    open my $fh, '>:raw', $path or die $!;
    print {$fh} 'OggS-pretend-audio';
    close $fh;
    return $path;
}

# The real, sanctioned bypass - a move made from inside Tira::CLI::Browser's
# own source, not a caller-supplied flag.
sub browser_moved {
    my ( $ref, $column ) = @_;
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    return $providers{move}->( { ref => $ref, column => $column, type => 'ticket', _signed_in => 'claude' } );
}

$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'implement', 'verify', 'done' ],
    sow_prefix => 'DLS', epic_prefix => 'DLE', ticket_prefix => 'DLT',
);

# --- THE BUG: a direct engine call skips the column-chain gate -------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Skips a column', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );
    };
    my $error = $@;
    ok( !$result, 'a direct record_move call refuses to skip a column (implement -> done, missing verify)' )
      or diag('record_move silently succeeded - the exact gap this card exists to close');
    like( $error, qr/the next column should be verify/, 'and the refusal names the column that should come next, same as the CLI\'s own refusal' );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{column}, 'implement', 'and the card genuinely did not move' );
}

# --- a caller-supplied flag must not be the bypass, same as TKT-1144 -------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Skips a column, flagged', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude', _dashboard_move => 1 );
    };
    ok( !$result, 'passing _dashboard_move => 1 from outside Tira::CLI::Browser does not bypass the column-chain gate' )
      or diag('record_move trusted a caller-supplied flag - the exact hole TKT-1144 already closed once for the other gate');

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{column}, 'implement', 'and the card still genuinely did not move' );
}

# --- the CLI dispatch path gives the identical refusal, unchanged ----------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Skips a column, via CLI', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => 'record.move', tira => $tira,
            argv => [ '--type', 'ticket', '--ref', $card->{ref}, '--column', 'done', '-o', 'json' ] );
    };
    isnt( $status, 0, 'the CLI dispatch path still refuses the identical skip' );
    like( $err, qr/the next column should be verify/, 'with the same next-column named' );
}

# --- a backward move is unaffected - it still bypasses, same as chain ------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Goes back over a gap', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'verify', author => 'claude' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'backlog', author => 'claude' );
    };
    ok( $result, 'a backward move spanning several columns is not blocked by the column-chain gate' ) or diag($@);
    is( $result->{column}, 'backlog', 'and this card actually moved back' );
}

# --- THE BUG: a direct engine call skips the unjudged-answer gate ----------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Carries an unjudged answer', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    my $question = $tira->question_add(
        project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which way?', reason => 'need a decision', options => [ 'A', 'B' ], voice => recording(),
    );
    $tira->question_answer( project => $root, ref => $card->{ref}, author => 'claude', id => $question->{id}, text => 'A' );

    my $before = $tira->record_show( project => $root, ref => $card->{ref} );
    my ($q) = grep { $_->{id} eq $question->{id} } @{ $before->{questions} };
    ok( $q->{answer} && !( $q->{answer}{mark} // '' ), 'the card carries an answered-but-unjudged question' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'verify', author => 'claude' );
    };
    my $error = $@;
    ok( !$result, 'a direct record_move call refuses to leave a column while an answer is unjudged' )
      or diag('record_move silently succeeded - the exact gap this card exists to close');
    like( $error, qr/nobody has judged/, 'and the refusal names the unjudged answer, same as the CLI\'s own refusal' );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{column}, 'implement', 'and the card genuinely did not move' );
}

# --- judging the answer is still the sanctioned way through ----------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Judged before moving', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    my $question = $tira->question_add(
        project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which way, judged?', reason => 'need a decision', options => [ 'A', 'B' ], voice => recording(),
    );
    $tira->question_answer( project => $root, ref => $card->{ref}, author => 'claude', id => $question->{id}, text => 'A' );
    $tira->question_mark( project => $root, ref => $card->{ref}, author => 'claude', id => $question->{id}, mark => 'ok' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'verify', author => 'claude' );
    };
    ok( $result, 'a judged answer lets a direct record_move call through' ) or diag($@);
    is( $result->{column}, 'verify', 'and the card actually moved' );
}

# --- P1 regression coverage: a backward move with an unjudged answer -------
#
# Codex review caught this: the original fix ran the unjudged-answer check
# for every non-discard, non-no-op move without confirming it was forward -
# so a card retreating with an unjudged answer (TKT-455's own design: the
# unjudged answer may be exactly what it is retreating to reconsider) was
# wrongly refused. Missing this case is what let that bug through.

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Retreats with an unjudged answer', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'verify', author => 'claude' );
    my $question = $tira->question_add(
        project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which way, retreating?', reason => 'need a decision', options => [ 'A', 'B' ], voice => recording(),
    );
    $tira->question_answer( project => $root, ref => $card->{ref}, author => 'claude', id => $question->{id}, text => 'A' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    };
    ok( $result, 'a direct record_move call sends a card carrying an unjudged answer BACKWARD without refusal' ) or diag($@);
    is( $result->{column}, 'implement', 'and the card actually moved back' );
}

# --- the real dashboard exemption, not only a fake flag ---------------------
#
# Codex review: testing that a caller-supplied _dashboard_move flag does NOT
# work is not the same as proving the real exemption DOES - both gates need
# a genuine Tira::CLI::Browser::providers call to go through.

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Skips a column, via the dashboard', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $result = eval { browser_moved( $card->{ref}, 'done' ); 1 };
    ok( $result, 'a genuine Tira::CLI::Browser move is not restricted by the column-chain gate' ) or diag($@);
    is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'done',
        'and the card actually reached the skipped-ahead column' );
}

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Unjudged answer, via the dashboard', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    my $question = $tira->question_add(
        project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which way, dashboard?', reason => 'need a decision', options => [ 'A', 'B' ], voice => recording(),
    );
    $tira->question_answer( project => $root, ref => $card->{ref}, author => 'claude', id => $question->{id}, text => 'A' );

    my $result = eval { browser_moved( $card->{ref}, 'verify' ); 1 };
    ok( $result, 'a genuine Tira::CLI::Browser move is not restricted by the unjudged-answer gate' ) or diag($@);
    is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'verify',
        'and the card actually moved' );
}

# --- a forked column names the branches, not a single "next" ----------------

{
    # Its own board, so the fork declared on 'implement' here does not leak
    # into the shared board's own plain sequential chain used elsewhere in
    # this file.
    my $fork_tmp  = tempdir( CLEANUP => 1 );
    my $fork_tira = Tira->new;
    my $fork_root = File::Spec->catdir( $fork_tmp, 'proj' );
    $fork_tira->project_new(
        name => 'Forked', dir => $fork_root, members => ['claude'],
        columns => [ 'backlog', 'implement', 'verify', 'shortcut', 'done' ],
        sow_prefix => 'FKS', epic_prefix => 'FKE', ticket_prefix => 'FKT',
    );
    $fork_tira->column_update( project => $fork_root, type => 'ticket', name => 'implement', next => [ 'verify', 'shortcut' ], author => 'claude' );

    my $card = $fork_tira->create_record( project => $fork_root, type => 'ticket', title => 'At a fork', author => 'claude' );
    $fork_tira->record_move( project => $fork_root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $result = eval {
        $fork_tira->record_move( project => $fork_root, ref => $card->{ref}, column => 'shortcut', author => 'claude' );
    };
    ok( $result, 'a direct record_move call to a column named in the fork is allowed' ) or diag($@);
    is( $result->{column}, 'shortcut', 'and the card moved to the forked destination' );

    my $card2 = $fork_tira->create_record( project => $fork_root, type => 'ticket', title => 'At a fork, wrong branch', author => 'claude' );
    $fork_tira->record_move( project => $fork_root, ref => $card2->{ref}, column => 'implement', author => 'claude' );
    my $wrong = eval {
        $fork_tira->record_move( project => $fork_root, ref => $card2->{ref}, column => 'done', author => 'claude' );
    };
    ok( !$wrong, 'a direct record_move call refuses a column not named in the fork' )
      or diag('record_move silently succeeded - the fork was not consulted');
    like( $@, qr/the next column should be verify or shortcut/, 'and the refusal names both branches the fork actually allows' );
}

# --- a gate already recorded for a skipped column lets the move through ----

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Already gated', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $tira->gate_add( project => $root, ref => $card->{ref}, gate => 'verify',
        result => 'pass', details => 'verified out of band', author => 'claude' );

    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );
    };
    ok( $result, 'a direct record_move call skipping a column already recorded as gate-passed is allowed' ) or diag($@);
    is( $result->{column}, 'done', 'and the card moved past the already-gated column' );
}

done_testing;

__END__

=head1 NAME

1145-two-more-doors-with-no-lock.t - record_move refuses a column skip and
an unjudged answer for every caller, not only the CLI

=head1 DESCRIPTION

TKT-1145. C<Tira::CLI.pm>'s C<run()> checks C<_column_chain_violation> and
C<_unjudged_answer_violation> before calling C<record_move>, but the engine
method itself has neither check built in - so any caller reaching it a
different way (the same class of gap TKT-1144 already closed for the
required-action check) can skip a column entirely, or move a card carrying
an answer nobody has judged, with no exemption and no reason recorded.
C<record_move> now refuses both by default, the same way the CLI's own
pre-checks already do. The browser dashboard's own TKT-426 exemption (a
human on the dashboard is not an agent skipping a gate) is preserved
separately, at its own call sites, not tested here.

=cut
