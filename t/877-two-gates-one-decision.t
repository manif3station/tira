#!/usr/bin/env perl
# The commit gate exists twice with nothing checking the two copies agree.
#
# This project's own tools/hooks/commit-msg is a hand-maintained shell
# script. Tira's own engine (lib/Tira.pm, $COMMIT_GATE) carries a SECOND,
# independent copy of the identical logic - installable on any project via
# tira.gates.install, so a board that has never seen this repository still
# gets the same gate. Both decide the same two questions: which columns
# mean the work has not started or is over (idle - a code commit is
# refused), and which columns mean the work is legitimately in progress
# (writing - a code commit is allowed). They agree today. Nothing checks
# that they keep agreeing.
#
# Compared as RULES, not as text - the two are written to different
# purposes (one lives in this repo's own .git/hooks, one is a template
# string in the engine) and a byte comparison would fail on formatting
# alone, the same reasoning t/433 gives for matching a claim's SHAPE
# rather than one exact sentence.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# --- extract the rule set from a commit-msg script's own text --------------
#
# The shape both scripts share: an idle set (columns where a code commit is
# refused outright) and a writing set (columns where one is allowed) - but
# not the same SYNTAX. tools/hooks/commit-msg names them in variables,
# idle='backlog|discard|done' and writing='tests-red|implement|verify',
# read later with a regex test against $column. The engine's own copy
# never assigns a variable - the identical pipe-joined lists sit directly
# in two `case "$column" in PATTERN)` arms. Both forms are tried; whichever
# one a given script actually uses answers.

sub _rules_in {
    my ($text) = @_;
    my %rules;

    if ( $text =~ /^idle='([a-z|]+)'/m ) {
        $rules{idle} = [ sort split /\|/, $1 ];
    }
    elsif ( $text =~ /case\s+"\$column"\s+in\s*\n\s*([a-z|]+)\)/ ) {
        $rules{idle} = [ sort split /\|/, $1 ];
    }

    if ( $text =~ /^writing='([a-z-]+(?:\|[a-z-]+)*)'/m ) {
        $rules{writing} = [ sort split /\|/, $1 ];
    }
    elsif ( $text =~ /case\s+"\$column"\s+in\s*\n\s*([a-z-]+(?:\|[a-z-]+)*)\)\s*:\s*;;/ ) {
        $rules{writing} = [ sort split /\|/, $1 ];
    }

    return \%rules;
}

# --- the repo's own hand-maintained copy ------------------------------------

open my $fh, '<', 'tools/hooks/commit-msg' or die "tools/hooks/commit-msg: $!";
my $repo_text = do { local $/; <$fh> };
close $fh;
my $repo_rules = _rules_in($repo_text);

ok( $repo_rules->{idle} && @{ $repo_rules->{idle} },
    'tools/hooks/commit-msg\'s own idle set was found - '
      . join( ',', @{ $repo_rules->{idle} // [] } ) );
ok( $repo_rules->{writing} && @{ $repo_rules->{writing} },
    'tools/hooks/commit-msg\'s own writing set was found - '
      . join( ',', @{ $repo_rules->{writing} // [] } ) );

# --- the engine's own installable copy --------------------------------------

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);
require File::Path;
File::Path::make_path( File::Spec->catdir( $root, '.git' ) );

my $result = $tira->gates_install( project => $root );
ok( ( grep { $_ eq 'commit-msg' } @{ $result->{installed} } ),
    'gates_install actually installs a commit-msg hook' );

open my $installed_fh, '<', File::Spec->catfile( $result->{into}, 'commit-msg' )
  or die "installed commit-msg: $!";
my $engine_text = do { local $/; <$installed_fh> };
close $installed_fh;
my $engine_rules = _rules_in($engine_text);

ok( $engine_rules->{idle} && @{ $engine_rules->{idle} },
    'the engine\'s own installed idle set was found - '
      . join( ',', @{ $engine_rules->{idle} // [] } ) );
ok( $engine_rules->{writing} && @{ $engine_rules->{writing} },
    'the engine\'s own installed writing set was found - '
      . join( ',', @{ $engine_rules->{writing} // [] } ) );

# --- and the two copies must agree ------------------------------------------

is_deeply( $repo_rules->{idle}, $engine_rules->{idle},
    "THE IDLE SETS AGREE - repo: " . join( ',', @{ $repo_rules->{idle} // [] } )
      . '; engine: ' . join( ',', @{ $engine_rules->{idle} // [] } ) );

is_deeply( $repo_rules->{writing}, $engine_rules->{writing},
    "THE WRITING SETS AGREE - repo: " . join( ',', @{ $repo_rules->{writing} // [] } )
      . '; engine: ' . join( ',', @{ $engine_rules->{writing} // [] } ) );

done_testing();

__END__

=head1 NAME

t/877-two-gates-one-decision.t - the commit gate's two copies agree on the same rules

=head1 WHY

TKT-877: tools/hooks/commit-msg (hand-maintained, installed via a symlink
into this repo's own .git/hooks) and lib/Tira.pm's $COMMIT_GATE (an
installable template any project can adopt via tira.gates.install)
independently encode the identical idle/writing column logic. They agree
today. Nothing checked that they keep agreeing - the exact mistake made
twice while writing TKT-875.

=head1 WHAT IS ASSERTED

Both copies' idle sets (columns where a code commit is refused outright)
and writing sets (columns where one is legitimate) are extracted and
compared as sets, not as text - the two are written in different contexts
on purpose, and a byte comparison would fail on formatting alone.

=cut
