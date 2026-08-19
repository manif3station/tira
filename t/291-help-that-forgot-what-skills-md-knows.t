#!/usr/bin/env perl
# --help for a typed record verb answers from %RECORD_USAGE alone, and never
# checks SKILLS.md's own catalogue line for the same command - unlike every
# command in %NEEDS_TYPE, which tries SKILLS.md first and falls back only
# when it has nothing to say.
#
# tira.<type>.list is documented on its own catalogue line in SKILLS.md:
#
#   tira.<type>.list [--full] [--column SLUG] [--assignee ID] [--parent REF]
#     [--text QUERY] [-o FORMAT]
#
# %RECORD_USAGE{list} in lib/Tira/CLI.pm answers differently:
#
#   list => '[--column SLUG] [--assignee ID] [--fields LIST] [--count]',
#
# Two independent descriptions of the same command, and they disagree.
# Confirmed live on the installed 2.85: --full, --parent and --text all work
# on ticket.list - each returns real, correctly filtered results - and none
# of them appears in --help. A caller who checks --help before using the
# command, the exact failure class TKT-215 and TKT-240 exist to stop, is
# told three real flags do not exist. TKT-418.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-19T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Helped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'HPS', epic_prefix => 'HPE', ticket_prefix => 'HPT',
);

sub run {
    my ( $type, @argv ) = @_;
    my $command = 'record.' . shift(@argv);
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, type => $type, argv => [@argv], tira => $tira );
        };
    };
    return ( $status, $out . $err );
}

# --full, --parent and --text are real, working flags on list - proved by
# running them, not assumed from what --help says.
{
    my ( $status, $said ) = run( 'ticket', 'list', '--full', '-o', 'json' );
    is( $status, 0, 'ticket.list --full runs' );
}
{
    my ( $status, $said ) = run( 'ticket', 'list', '--text', 'nothing-matches', '-o', 'json' );
    is( $status, 0, 'ticket.list --text runs' );
}
{
    my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A parent',
        labels => ['standalone'] );
    my ( $status, $said ) = run( 'ticket', 'list', '--parent', $epic->{ref}, '-o', 'json' );
    is( $status, 0, 'ticket.list --parent runs' );
}

# SKILLS.md's own catalogue line for tira.<type>.list is the flags a caller
# should be told about - read from the document rather than retyped, so a
# line added there is required here without anybody remembering to.
open my $skills_fh, '<', 'SKILLS.md' or die $!;
my $skills_text = do { local $/; <$skills_fh> };
close $skills_fh;
my ($catalogue_line) = $skills_text =~ /^tira\.<type>\.list (.+)$/m;
ok( $catalogue_line, 'SKILLS.md documents tira.<type>.list' );
my @documented_flags = $catalogue_line =~ /--([a-z][a-z-]*)/g;
cmp_ok( scalar @documented_flags, '>=', 4, 'and names more than a couple of flags' );

for my $type (qw(sow epic ticket)) {
    my ( undef, $help ) = run( $type, 'list', '--help' );
    for my $flag (@documented_flags) {
        like( $help, qr/--\Q$flag\E\b/, "$type.list --help names --$flag, which SKILLS.md documents" );
    }
}

# --- the same drift, on create's --column ------------------------------------
#
# Not only list. SKILLS.md documents tira.<type>.create on its own concrete
# line per type (tira.sow.create, tira.epic.create, tira.ticket.create - all
# three identical), each naming --column, and --column is a real, working
# flag on create - confirmed by running it, below - while %RECORD_USAGE{create}
# never mentions it. The same root cause as list: _usage()'s typed-verb branch
# never consults SKILLS.md at all, for any verb.
{
    my ( $status, $said ) = run( 'ticket', 'create', '--title', 'Placed on arrival',
        '--column', 'implement', '-o', 'json' );
    is( $status, 0, 'ticket.create --column runs' );
}

for my $type (qw(sow epic ticket)) {
    my ($create_line) = $skills_text =~ /^tira\.\Q$type\E\.create (.+)$/m;
    ok( $create_line, "SKILLS.md documents tira.$type.create" );
    my ( undef, $help ) = run( $type, 'create', '--help' );
    like( $help, qr/--column\b/, "$type.create --help names --column, which SKILLS.md documents" );
}

done_testing;

__END__

=head1 NAME

291-help-that-forgot-what-skills-md-knows.t - --help says what SKILLS.md says

=head1 DESCRIPTION

_usage()'s typed-verb branch answers a command like tira.ticket.list from
%RECORD_USAGE alone and never consults SKILLS.md's own catalogue line for
the same command, unlike every command in %NEEDS_TYPE. This proved --full,
--parent and --text are real, working flags on list, then required every
flag SKILLS.md documents for tira.<type>.list to appear in --help for all
three record types.

=cut
