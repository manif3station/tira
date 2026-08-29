#!/usr/bin/env perl
# TKT-747. Run a create outside a project and Tira answers with a Perl error
# instead of a refusal:
#
#     record.create  exit=2
#        error: Can't use an undefined value as a HASH reference
#               at lib/Tira/CLI/Records.pm line 36.
#
# Every other command in the same condition says "No Tira project found from
# '...'". Running a create in the wrong directory is the most ordinary mistake
# there is - it is what a person does on their first day and what an agent does
# when its working directory is not where it thinks - and the answer names a
# module they have never heard of, no project, and nothing to do about it.
#
# THE CAUSE IS PRECEDENCE, at lib/Tira/CLI/Records.pm:36:
#
#     my $entry = eval { $tira->column_roles(%args) }->{entry};
#
# eval BLOCK returns undef when its block dies, so ->{entry} is applied to that
# undef OUTSIDE the protection the eval was written to give. column_roles reaches
# discover_project, which dies when there is no project - so the exact failure the
# eval exists to tolerate is the one that crashes it. The fix is to assign first
# and dereference after, which lets discover_project's own die reach the caller
# and print the refusal the other commands already print.
#
# THE EVAL MUST STAY. TKT-428 put it there so a board that declares no entry role
# is not refused, and TKT-496 made 'entry' a list. Both of those are asserted
# below as controls, because a fix that removed the eval would pass the first half
# of this file and break boards that work today.
#
# Present since 2.96 (TKT-428), still present at 4.79.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

sub cli_in {
    my ( $home, $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>',     \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $home;
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- THE CARD. A create with no project refuses the way everything else does ---
#
# The temp dir is under /tmp and holds no .tira, and discover_project walks
# upwards from where it is told to start - so /tmp and / are the only parents it
# sees and it genuinely finds no board. Nothing here can reach a real one.

my $nowhere = File::Spec->catdir( $tmp, 'nowhere' );
mkdir $nowhere or die "mkdir: $!";

my ( $status, undef, $err ) = cli_in( $nowhere, 'record.create', '--title', 'Filed from nowhere' );

isnt( $status, 0, 'a create with no project discoverable still refuses' );

# Guard for everything below: an empty stderr would satisfy every "does not
# mention" assertion in this file without the bug being fixed.
ok( length($err), 'and it puts something on stderr to refuse with' )
  or diag('stderr was empty, so the assertions below prove nothing');

like( $err, qr/No Tira project found/,
    'and the refusal is the one every other command gives - said: ' . ( $err || '(nothing)' ) );

like( $err, qr/\Q$nowhere\E/,
    'naming the directory it looked in, so the caller can see where it was' );

ok( length($err) && $err !~ m{Records\.pm},
    'the refusal does not name a source file the caller has never heard of' );

ok( length($err) && $err !~ m{\bline\s+\d+},
    'and does not name a line number in it' );

# --- the same condition, through a command that already refuses properly -------
#
# This is what "brought into line with" means, asserted rather than asserted
# about: the two messages must be the same, not merely both acceptable.

my ( undef, undef, $show_err ) = cli_in( $nowhere, 'record.show', '--ref', 'TKT-1' );

is( $err, $show_err,
    'and it is the same refusal record.show gives in the same condition, '
      . 'byte for byte - record.show said: ' . ( $show_err || '(nothing)' ) );

# comment.add too, because the documentation names both of these as the
# commands create was measured against. A doc claim that rests on a
# measurement taken once, by hand, in a container that no longer exists is a
# claim nothing re-checks; this makes the suite the thing that holds it.

my ( undef, undef, $comment_err ) = cli_in( $nowhere, 'comment.add', '--ref', 'TKT-1', '--text', 'x' );

is( $err, $comment_err,
    'and the same refusal comment.add gives - the two commands the docs name '
      . 'are both compared here rather than quoted from a card - comment.add said: '
      . ( $comment_err || '(nothing)' ) );

# --- CONTROL. A board that declares no entry role still creates ---------------
#
# The case the eval was added for (TKT-428). Green today, and a fix that deleted
# the eval rather than moving the dereference would turn this red.

{
    my $noentry = File::Spec->catdir( $tmp, 'noentry' );
    my $tira    = Tira->new;
    $tira->project_new(
        name       => 'NoEntry', dir => $noentry, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'done' ],
        sow_prefix => 'NES', epic_prefix => 'NEE', ticket_prefix => 'NET',
    );

    my ( $s, $o ) = cli_in( $noentry, 'record.create', '--title', 'No entry role here', '-o', 'json' );
    is( $s, 0, 'a board that declares no entry role still creates a card' ) or diag($o);
    like( $o, qr/"ref"\s*:\s*"NET-/, 'and the card is real, with a ref of its own' );
}

# --- CONTROL. A board that declares one still refuses the wrong column ---------
#
# The other direction: the entry-role check must keep working, so the fix cannot
# simply make column_roles unreachable.

{
    my $entry = File::Spec->catdir( $tmp, 'entry' );
    my $tira  = Tira->new;
    $tira->project_new(
        name       => 'HasEntry', dir => $entry, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'done' ],
        sow_prefix => 'HES', epic_prefix => 'HEE', ticket_prefix => 'HET',
    );
    $tira->column_roles_set( project => $entry, type => 'ticket', roles => { entry => 'backlog' } );

    my ( $s, undef, $e ) = cli_in( $entry, 'record.create', '--title', 'Straight to implement',
        '--column', 'implement' );
    isnt( $s, 0, 'a create into a column that is not the declared entry is still refused' );
    like( $e, qr/entry column/i,
        'and still says so in the entry-column vocabulary - said: ' . ( $e || '(nothing)' ) );

    my ( $s2, $o2 ) = cli_in( $entry, 'record.create', '--title', 'Into the entry', '-o', 'json' );
    is( $s2, 0, 'and a create into the declared entry column still succeeds' ) or diag($o2);
    like( $o2, qr/"column"\s*:\s*"backlog"/, 'landing there' );
}

done_testing();

__END__

=head1 NAME

t/438-the-one-create-that-answers-with-a-line-number.t - a create outside a
project must refuse, not crash

=head1 DESCRIPTION

C<lib/Tira/CLI/Records.pm:36> reads

    my $entry = eval { $tira->column_roles(%args) }->{entry};

C<eval BLOCK> returns undef when its block dies, so the C<< ->{entry} >> is
applied to undef outside the eval's protection. C<column_roles> reaches
C<discover_project>, which dies when there is no project - so the one failure the
eval was written to tolerate is the one that crashes it, and the caller gets a
file and a line number instead of C<No Tira project found from '...'>.

This is the only occurrence of the shape in F<lib/>; every other eval-guarded
read assigns to a scalar first or ends in C<< // return >>.

=head2 The controls matter as much as the card

The eval is not a mistake and must not be deleted. TKT-428 added it so a board
declaring no entry role still creates cards, and TKT-496 made C<entry> a list.
Both are asserted here, green before the fix and green after, because the
plausible wrong fix - removing the eval - passes the first half of this file and
breaks boards that work today.

=cut
