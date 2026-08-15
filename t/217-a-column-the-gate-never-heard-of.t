#!/usr/bin/env perl
# The push gate enforces for the columns it was told about, and for no others.
#
# tools/card-holes carries its own list of the seven columns it knows, and every
# check past the first begins by asking where the card is in that list. A column
# the list has never heard of is not in it, so the answer is "not applicable"
# and the card passes - silently, which is the only way this could have survived.
#
# A board declares its own columns and can declare more. So a board that adds a
# working column loses the gate, the evidence and the fix-version checks for
# every card in it, and the push still succeeds. The engine had already learned
# this: it asks the board rather than carrying a copy.
#
# Run rather than read. The tool had no test that executed it - the fault was
# demonstrated by reading its source, and a check nobody runs is exactly the
# thing this codebase keeps finding. This one runs it, against a real board,
# through the environment, which is how the gate reaches a board in earnest.

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

my $tira = Tira->new( clock => sub {'2026-08-15T22:00:00Z'} );
$tira->project_new(
    name => 'Extra', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, review, done'],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);

# A card with nothing missing except what the column-dependent checks look for.
# Every required field is filled, so anything reported about it is about where
# it sits rather than about what it says.
my $card = $tira->create_record(
    project => $root, type => 'ticket',
    title   => 'A card in a column the gate was not told about',
    problem_or_feature  => 'Something was wrong.',
    solution_needed     => 'It was fixed.',
    key_details         => ['One detail.'],
    deliverables        => ['One deliverable.'],
    acceptance_criteria => ['One criterion.'],
    test_steps          => ['One step.'],
    bdd                 => ['Given, When, Then.'],
    atdd                => ['One acceptance.'],
    description         => 'A description.',
    scope_in            => ['In.'],
    scope_out           => ['Out.'],
);
$tira->checklist_add( project => $root, ref => $card->{ref},
    item => 'The one thing to do', status => 'done' );

# Run from outside any project, which is the only place the board can be
# chosen. The dashboard sets TIRA_HOME itself from the working directory when
# that directory belongs to a project - a value passed in is replaced, not
# preferred - so a test that ran the tool from the skill's own folder would
# silently measure the skill's own board. It did, on the first attempt: two
# passes over 235 cards instead of one, and the run timed out rather than
# failing, which is the least useful way to be wrong.
my $tool = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );
my $skill = File::Spec->rel2abs('.');

# A dispatcher of its own, because the real one is not here.
#
# The tool reaches a board the way every gate tool does: through tira-call,
# which runs d2. d2 is the dashboard, and the dashboard is not installed in the
# container the suite runs in - so the first version of this test passed on my
# machine and failed the gate, which is the worst way round. It maps a command
# to an entrypoint exactly as the shipped ones do, and it does not rewrite
# TIRA_HOME, which the real dashboard does when the working directory belongs
# to a project.
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

sub holes_says {
    my ($column) = @_;
    $tira->record_move( project => $root, ref => $card->{ref}, column => $column )
      if defined $column;

    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $root;
    local $ENV{PATH} = $stub . ( $^O eq 'MSWin32' ? ';' : ':' ) . $ENV{PATH};
    my ( undef, $output ) = run_capturing( 'python3', $tool );
    chdir $here or die "chdir back: $!";
    return $output;
}

# --- the column it was told about ------------------------------------------
#
# Asserted first, so what follows is a difference between two columns rather
# than a check that never had anything to say about this card at all.

# Asserted on the reason, not on the reference appearing somewhere in the
# output. The first version of this asked only whether the card was named, and
# it was named in both columns - by a different check, about missing fields,
# which has nothing to do with where the card sits. It passed, and proved
# nothing. What is being measured is one sentence: the one about a gate.
my $known = holes_says('verify');
like( $known, qr/\Q$card->{ref}\E[^\n]*no gate/,
    'a card past verify with no gate and no evidence is told so' );

# --- and one it was not ----------------------------------------------------
#
# After verify, which is where the fault lives. A column before it is not past
# the point where a card claims to be proven, and the check is right to say
# nothing about it - the first version of this test put the new column there
# and measured the tool being correct.

my $unknown = holes_says('review');
like( $unknown, qr/\Q$card->{ref}\E[^\n]*no gate/,
    'and so is the same card in a column the board added, which the gate had never heard of' );

# --- while discard stays out of it -----------------------------------------
#
# Deliberately exempt and staying that way. A discarded card is not work in
# progress, and reporting it as missing a gate would be the gate arguing with a
# decision somebody already made.

$tira->record_discard( project => $root, ref => $card->{ref} );
my $discarded = holes_says(undef);

# The subject is established before it is denied. A tool that printed nothing -
# because it died, because it found no board, because a stub was wrong - would
# satisfy the denial below without the exemption existing at all. t/147 caught
# exactly this in the first version of this file.
# non-empty is the whole claim: a precondition for the denial that follows.
like( $discarded, qr/\S/, 'the tool still ran and still had something to say' );
unlike( $discarded, qr/\Q$card->{ref}\E[^\n]*gate/,
    'and a discarded card is not asked for a gate it was never going to have' );

done_testing;

__END__

=head1 NAME

217-a-column-the-gate-never-heard-of.t - the gate enforces for columns it knows

=head1 DESCRIPTION

C<tools/card-holes> carried its own list of columns, and every column-dependent
check began by locating the card in that list. A column the list did not have
was not in it, so the check did not apply and the card passed silently. A board
that declares a working column therefore lost the gate, evidence and
fix-version checks for everything in it.

Proved by running the tool rather than reading it, against a board with a
column its list never had. C<discard> stays exempt, which is deliberate.

=cut
