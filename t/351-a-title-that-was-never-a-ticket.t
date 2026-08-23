#!/usr/bin/env perl
# tools/card-holes already answers "which cards are missing required fields"
# but only runs from the pre-push hook, against the cards a push is about -
# so a card with a title and nothing else can sit in the backlog
# indefinitely, moving between columns as though it were real work, and
# nobody can ask the question until a push happens to be about it. Measured
# live: 26 of 300 cards missing both problem_or_feature and solution_needed,
# 24 of them still open in backlog with no push ever having named them.
# TKT-374.
#
# card_holes exposes exactly the check card_missing already makes -
# _card_missing_from, the same definition the push gate depends on - swept
# across every live card, so the two can never disagree about what
# complete means.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Holes', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'HLS', epic_prefix => 'HLE', ticket_prefix => 'HLT',
);

# --- a card with a title and nothing else - the whole reason this exists ---

my $zombie = $tira->create_record( project => $root, type => 'ticket', title => 'Just a title' );

my $report = $tira->card_holes( project => $root );
my ($found) = grep { $_->{ref} eq $zombie->{ref} } @{$report};
ok( $found, 'a card with only a title is reported' );
ok( ( grep { $_ eq 'problem_or_feature' } @{ $found->{missing} } ),
    'naming the missing field, the same way card_missing would' );

# --- and the same, hand-verified, is what card_missing itself says ---------

is_deeply( $found->{missing}, $tira->card_missing( project => $root, ref => $zombie->{ref} ),
    'the exact same list card_missing returns for the one card - reusing the definition, not a second copy' );

# --- a complete card is not reported ----------------------------------------

{
    my $whole = $tira->create_record( project => $root, type => 'ticket', title => 'A real ticket',
        description => 'x', problem_or_feature => 'x', solution_needed => 'x',
        key_details => ['x'], deliverables => ['x'], acceptance => ['x'], test_steps => ['x'],
        bdd => ['x'], atdd => ['x'], reporter => 'claude', priority => 3,
        scope_in => ['x'], scope_out => ['x'], labels => ['standalone'] );
    $tira->checklist_add( project => $root, ref => $whole->{ref}, author => 'claude',
        item => 'done already', status => 'done' );

    my $report = $tira->card_holes( project => $root );
    ok( !( grep { $_->{ref} eq $whole->{ref} } @{$report} ), 'a complete card is not reported' );
}

# --- a discarded card, however hollow, is not live work ---------------------

{
    my $gone = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside' );
    $tira->record_move( project => $root, ref => $gone->{ref}, author => 'claude', column => 'discard' );

    my $report = $tira->card_holes( project => $root );
    ok( !( grep { $_->{ref} eq $gone->{ref} } @{$report} ), 'a discarded card is not reported, discard is not live work' );
}

# --- an untriaged report, filed the way TKT-104 made easy, is not reported --

{
    my $reported = $tira->create_record( project => $root, type => 'ticket', title => 'Found elsewhere',
        source => 'Reported from zen-framework through tira.dev.found.bug_or_improvement' );

    my $report = $tira->card_holes( project => $root );
    ok( !( grep { $_->{ref} eq $reported->{ref} } @{$report} ),
        'an untriaged tira.dev.found report, still in backlog, is not reported - filing stays easy' );

    $tira->record_move( project => $root, ref => $reported->{ref}, author => 'claude', column => 'implement' );
    $report = $tira->card_holes( project => $root );
    ok( ( grep { $_->{ref} eq $reported->{ref} } @{$report} ),
        'but once triaged - moved out of backlog - it is held to the same standard as everything else' );
}

# --- proved by breaking it: the answer follows the same definition ----------
#
# card_holes calls _card_missing_from directly - the exact private helper
# card_missing itself calls - rather than keeping a second list of required
# fields. Redefining that one shared function proves both commands would
# move together if the definition ever changed, rather than drifting the
# way police and the push gate once did (TKT-241).

{
    no warnings 'redefine';
    local *Tira::_card_missing_from = sub { return ['description'] };

    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Anything at all' );
    my $report = $tira->card_holes( project => $root );
    my ($found) = grep { $_->{ref} eq $card->{ref} } @{$report};
    is_deeply( $found->{missing}, ['description'],
        'with the shared definition narrowed to just one field, card_holes reports exactly that field - '
          . 'the answer changed because the definition did, through the one function both commands share' );
}

# --- and the command a caller actually types ---------------------------------

{
    use Tira::CLI;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'card.holes', tira => $tira, argv => [ '-o', 'json' ] );
        };
    };
    is( $status, 0, 'tira.card.holes answers' );
    like( $out, qr/\Q$zombie->{ref}\E/, 'and names the same zombie card the engine method does' );
}

done_testing;

__END__

=head1 NAME

351-a-title-that-was-never-a-ticket.t - the board answers which cards are missing required fields

=head1 DESCRIPTION

C<tools/card-holes> already answered "which cards are missing required
fields," but only from the pre-push hook, against the cards a push
happened to be about - a card with a title and nothing else could sit in
the backlog indefinitely, unblocked, until a push named it. C<card_holes>
exposes the same check C<card_missing> already makes, swept across every
live card and exempting an untriaged C<tira.dev.found> report exactly as
the push gate does, so filing a quick report stays as easy as TKT-104 made
it.

=cut
