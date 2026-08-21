#!/usr/bin/env perl
# A card whose branch and work tree exist can be watched passing the rule.
#
# developer-dashboard's report, and the sentence in it that matters most is not
# the complaint: "four other cards drew this rule this morning and all four
# appear to have settled - but none of them settled by satisfying it... So I
# have no observation of this rule ever passing on a well-formed card."
#
# DD-532 made it five. It went WARNING at 08:45:11, URGENT at 09:15:44 and
# SETTLED at 09:30:44, and it settled because the card left in-progress, which
# the --enter scope makes the rule stop applying to. The branch, the work tree
# and the sandbox field existed and agreed throughout.
#
# A rule that has only ever been observed to stop applying is one nobody can
# trust, whatever the verdict on any single card. That is what this file is for:
# the passing case, watched.
#
# And the verdict on DD-532 itself, decided here rather than by another round
# trip. Their own evidence has it: `git branch --list dd-532` answers `dd-532`
# and the card is `DD-532`. A reference is upper case by construction and git
# branches are conventionally lower case, so on any project following that
# convention the check can never match - which is what TKT-161 fixed the message
# for in 1.73 and what nobody has read out loud since.

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Sandboxed', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, done'],
    sow_prefix => 'SBS', epic_prefix => 'SBE', ticket_prefix => 'DD',
);

# card-sandbox-missing refuses to be declared where no repository can be
# resolved - TKT-178's own refusal, doing its job inside this test. The board
# gets one, which is what a real board declaring this rule has to have.
mkdir File::Spec->catdir( $root, '.git' );

my $sandbox_root = File::Spec->catdir( $tmp, 'worktrees' );
$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'in-progress', sandbox => $sandbox_root, action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Work with a real tree behind it' )->{ref};
$tira->record_move(author => 'claude',  project => $root, ref => $card, column => 'in-progress' );

my $tree = File::Spec->catdir( $sandbox_root, lc $card );
$tira->record_update( project => $root, ref => $card, sandbox => $tree );

sub reported {
    my (%world) = @_;
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police-' . ( $world{label} // 'x' ) ),
        world => { processes => [], containers => [],
            branches => $world{branches} // [], worktrees => $world{worktrees} // [] } );
    return [ grep { $_->{rule} eq 'card-sandbox-missing' } @{ $pass->{violations} } ];
}

# --- the passing case, which nobody has ever watched --------------------------------

is_deeply(
    reported( label => 'good', branches => [$card], worktrees => [$tree] ),
    [],
    'a card whose branch and work tree both exist passes the rule, in the column it applies to' );

# --- the case they actually have ------------------------------------------------------
#
# The branch is there, spelled the way git users spell branches, and the card is
# spelled the way references are spelled. Those are different strings.

{
    my $found = reported( label => 'case', branches => [ lc $card ], worktrees => [$tree] );
    is( scalar @{$found}, 1, 'a branch differing only in case does not satisfy it' );
    like( $found->[0]{detail}, qr/\Q@{[ lc $card ]}\E/,
        'and the violation names the branch that is there' );
    like( $found->[0]{detail}, qr/only in case/i,
        'saying it differs only in case, which turns an hour of hypothesising into a rename' );
}

# --- and the two failures it must still report ------------------------------------------

{
    my $missing = reported( label => 'nobranch', branches => [], worktrees => [$tree] );
    is( scalar @{$missing}, 1, 'no branch at all is still reported' );

    # What it says, before what it does not say. t/147 insists on this and is
    # right to: "no case difference in the detail" passes just as happily when
    # the detail is empty, and an empty detail is a worse fault than the one
    # being denied.
    like( $missing->[0]{detail}, qr/\Q$card\E/,
        'naming the branch it wanted' );
    unlike( $missing->[0]{detail}, qr/only in case/i,
        'without claiming a case difference that is not there' );

    my $treeless = reported( label => 'notree', branches => [$card], worktrees => [] );
    is( scalar @{$treeless}, 1, 'and a missing work tree is still reported' );
}

# --- while a card outside the column it watches is not asked ------------------------------
#
# This is how every one of their five cards cleared: not by passing, by leaving.
# It is correct, and it is why the passing case above had to be written down.

{
    $tira->record_move(author => 'claude',  project => $root, ref => $card, column => 'done' );
    is_deeply( reported( label => 'left', branches => [], worktrees => [] ), [],
        'a card that has left the column stops being asked, which is not the same as passing' );
}

done_testing;

__END__

=head1 NAME

195-a-sandbox-that-can-be-seen-passing.t - the rule can be watched succeeding

=head1 DESCRIPTION

C<card-sandbox-missing> had been observed failing five times on one board and
passing never: every card that cleared it did so by leaving the column the
policy watches, which the C<--enter> scope makes it stop applying to. This file
watches the passing case, so that "it works" is something the suite says rather
than something nobody has seen.

It also settles the reported card. A branch named C<dd-532> does not satisfy a
check that wants one named after C<DD-532>, and the violation says so in those
words - which is a rename rather than a bug.

=cut
