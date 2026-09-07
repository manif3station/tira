#!/usr/bin/env perl
# TKT-641. tools/card-holes's unproven() refused six cards moved to push in
# one batch with the same sentence, and nothing in it said what to do:
#
#   TKT-000 is in push with no gate has been recorded and no evidence is
#   attached and no fix version - a claim about work that happened, with
#   nothing anybody could check
#
# "no fix version" has no verb, so joined onto the first two clauses with
# "and" it does not parse as a continuation of the sentence - and even read
# correctly, it names three things that are wrong and not the one command
# (tira.release.record) that fixes all three at once.
#
# WRITTEN RED.

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

my $tira = Tira->new( clock => sub {'2026-09-07T22:00:00Z'} );
$tira->project_new(
    name    => 'Unproven',
    dir     => $root,
    members => ['claude'],
    columns => ['backlog, implement, verify, pending-push, push, install, done'],
    sow_prefix => 'UPS', epic_prefix => 'UPE', ticket_prefix => 'UPT',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'Nothing anybody could check',
    description => 'x', problem_or_feature => 'x', solution_needed => 'x',
    key_details => ['x'], deliverables => ['x'], acceptance => ['x'],
    test_steps => ['x'], bdd => ['x'], atdd => ['x'],
    priority => 3, scope_in => ['x'], scope_out => ['x'],
);
$tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'the work', status => 'Done', command => ['did it'], proof => ['done'] );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'push' );

my $tool  = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );
my $skill = File::Spec->rel2abs('.');

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

my $here  = getcwd();
chdir $tmp or die "chdir: $!";
local $ENV{TIRA_HOME} = $root;
local $ENV{PATH} = $stub . ':' . $ENV{PATH};
my ( undef, $said ) = run_capturing( 'python3', $tool );
chdir $here or die "chdir back: $!";

like( $said, qr/\Q$card->{ref}\E is in push/, 'the refusal names the card and its column' );

# --- it parses: every listed clause reads as a sentence continuation --------

unlike( $said, qr/and no fix version -/,
    'the fix-version clause is not left bare - "no fix version" alone does '
      . 'not continue the sentence "is in push with no gate ... and"' );

like( $said, qr/no fix version set/,
    'it reads as a complete clause instead' );

# --- and it names the one command that fixes all three at once -------------

like( $said, qr/tira\.release\.record --ref \Q$card->{ref}\E/,
    'the refusal names the exact command that clears every complaint at once, '
      . 'not just what is wrong' );

done_testing();

__END__

=head1 NAME

641-a-refusal-with-no-remedy.t - card-holes's unproven() refusal parses and
names its own remedy

=head1 DESCRIPTION

TKT-641. C<tools/card-holes>'s C<unproven()> joined C<'no fix version'> onto
two full clauses with C<' and '>, so C<... and no fix version - a claim
about ...> does not parse as one sentence - the third item has no verb where
the first two do. It never named C<tira.release.record>, the one command
that clears every complaint (gate, evidence, fix version) at once, so a
reader who was refused six times in a row had to already know the remedy.
Each listed clause now reads as a complete phrase and the refusal ends by
naming the exact command, with the card's own ref filled in.

=cut
