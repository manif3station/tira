#!/usr/bin/env perl
# A finished release is not held up by the work that follows it.
#
# The push gate asks the card check about every card on the board at the moment
# the hook runs, which is a different question from whether the commit being
# pushed is fit to go. Measured rather than argued: 2.14 was committed, gated
# and ready, and its push was refused three times - once because a card was
# mid-move when the check ran, once because cards for 2.15 sat in verify with
# no gates yet, and once because a report raised minutes earlier had not been
# written up. None of those was about the commit being pushed.
#
# It happened again while this card sat in the backlog. 2.21 was committed and
# gated; the push was refused because TKT-261 - raised an hour earlier by a bug
# hunt, on a completely unrelated subject - was still a title.
#
# So the gate asks about the cards the commits name. The board-wide question is
# a good one and police asks it continuously, on a channel with somebody
# reading it; asking it again at push time only makes a release wait on it.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
$tira->project_new(
    name => 'Shipping', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'SHS', epic_prefix => 'SHE', ticket_prefix => 'SHT',
);

# A card that is finished work: everything the engine asks of a card, so the
# gate has nothing to say about it. Asked for rather than listed here, because
# a list written in a test is a second definition of a complete card and this
# project has already paid for having two.
my $parent = $tira->create_record( project => $root, type => 'epic',
    title => 'The release this commit belongs to' );

my $shipped = $tira->create_record(
    project => $root, type => 'ticket',
    title => 'The card this commit is about',
    description => 'What it does.',
    problem_or_feature => 'What was wrong.',
    solution_needed => 'What was done about it.',
    key_details => ['What was measured.'],
    deliverables => ['What came out of it.'],
    acceptance => ['How it is known to be right.'],
    test_steps => ['How it was proved.'],
    bdd => ['Given, When, Then.'],
    atdd => ['What somebody would check.'],
    priority => 3,
    scope_in => ['This'], scope_out => ['That'],
);
# Still to do, and the card sitting where work happens: a checklist finished
# while the column says otherwise is its own complaint, and this card is here to
# have nothing wrong with it.
$tira->checklist_add( author => 'claude', project => $root, ref => $shipped->{ref},
    item => 'The work itself', status => 'todo' );
$tira->record_move(author => 'claude',  project => $root, ref => $shipped->{ref}, column => 'implement' );
$tira->hierarchy_link( project => $root,
    parent => $parent->{ref}, child => $shipped->{ref} );

# And the next release, being worked: a card raised minutes ago with nothing on
# it but a title, which is what a card looks like the moment it is raised.
my $next = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something else somebody is in the middle of' );

my $tool  = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );
my $skill = File::Spec->rel2abs('.');

# A dispatcher of its own, because the real one is not here: the tool reaches a
# board through d2, and the dashboard is not installed in the container the
# suite runs in.
my $stub = File::Spec->catdir( $tmp, 'bin' );
mkdir $stub or die "$stub: $!";
{
    my $path = File::Spec->catfile( $stub, 'd2' );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} <<"PL";
#!$^X
use strict;
use warnings;
use File::Spec;
my \$command = shift \@ARGV;
\$command =~ s/\\Atira\\.//;
my \@parts = split /\\./, \$command;
my \$verb = pop \@parts;
my \$entry = \@parts
  ? File::Spec->catfile( '$skill', 'skills', \@parts, 'cli', \$verb )
  : File::Spec->catfile( '$skill', 'cli', \$verb );
exec \$^X, '-I', File::Spec->catdir('$skill','lib'), \$entry, \@ARGV;
PL
    close $fh;
    chmod 0755, $path or die "chmod: $!";
}

sub gate {
    my (@about) = @_;
    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $root;
    local $ENV{PATH} = $stub . ':' . $ENV{PATH};
    my ( $status, $said ) = run_capturing( 'python3', $tool, @about );
    chdir $here or die "chdir back: $!";
    return ( $status, $said );
}

# --- the whole board, which is what it did ----------------------------------
#
# Asserted first: the card being worked is a real hole, so what follows is the
# gate asking a different question rather than the gate having nothing to say.

{
    my ( $status, $said ) = gate();
    isnt( $status, 0, 'asked about the whole board, the gate refuses' );
    like( $said, qr/\Q$next->{ref}\E/, 'naming the card somebody is in the middle of' );
}

# --- and asked about the commit's own card ----------------------------------

{
    my ( $status, $said ) = gate( $shipped->{ref} );
    is( $status, 0,
        'a commit whose own card is finished is not held up by the next one' );
    unlike( $said, qr/\Q$next->{ref}\E/,
        'and the card it does not name is not what this push is judged on' );
}

# --- while its own card is still judged -------------------------------------
#
# The half that must not be lost: narrowing the question is not weakening it.

{
    my ( $status, $said ) = gate( $next->{ref} );
    isnt( $status, 0, 'a commit whose own card is a title is still refused' );
    like( $said, qr/\Q$next->{ref}\E/, 'and told which card, and what is missing' );
    unlike( $said, qr/\Q$shipped->{ref}\E/,
        'without the card it does not name being dragged in' );
}

# --- and it says what it looked at ------------------------------------------
#
# A check that narrows what it examines and does not say so reads as a check
# that examined everything. That is how a gate quietly stops being a gate.

{
    my ( undef, $said ) = gate( $shipped->{ref} );
    like( $said, qr/\Q$shipped->{ref}\E/,
        'a narrowed run names the cards it was asked about' );
}

done_testing;

__END__

=head1 NAME

235-the-cards-this-push-is-about.t - the commit's cards, not every card there is

=head1 DESCRIPTION

The push gate asked C<tools/card-holes> about every card on the board, so a
commit that had passed its own gate was refused for work that came after it -
three times for 2.14, and again for 2.21 by a card a bug hunt had raised an
hour earlier on an unrelated subject.

The tool now takes the cards a push is about and judges those. The board-wide
question is police's, asked continuously on a channel somebody reads, rather
than one more thing a release waits on.

=cut
