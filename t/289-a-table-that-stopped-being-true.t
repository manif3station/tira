#!/usr/bin/env perl
# %NEEDS_TYPE's own list is run, not read - so a command a later change frees
# from needing --type cannot stay declared as needing it without failing the
# suite the way it just did.
#
# TKT-409 (2.80) changed column_list so omitting --type no longer refuses: it
# answers with a hash keyed by sow, epic and ticket instead. lib/Tira/CLI.pm's
# %NEEDS_TYPE table - "the commands that cannot work without a type" - still
# named column.list, and nothing ran it to check. Confirmed live on the
# installed 2.83: 'd2 tira.column.list -o json' with no --type succeeds.
#
# It never showed up as a visible defect because %NEEDS_TYPE has exactly one
# other reader, _usage()'s --help fallback, and that fallback is itself
# masked every time by SKILLS.md's own correct usage line for column.list
# winning first. A wrong fact nothing ever reads is still a wrong fact - one
# SKILLS.md edit away from surfacing as a --help line that tells column.list
# callers --type is required when it has not been since 2.80. TKT-417.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-19T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Needed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NDS', epic_prefix => 'NDE', ticket_prefix => 'NDT',
);

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# The declared list, taken from the source rather than retyped here - a
# hand-copied list is a second copy of the same decision this test exists to
# stop drifting, which is exactly how the first copy went stale.
open my $cli_fh, '<', File::Spec->catfile(qw(lib Tira CLI.pm)) or die $!;
my $source = do { local $/; <$cli_fh> };
close $cli_fh;
my ($table) = $source =~ /my %NEEDS_TYPE = map \{ \$_ => 1 \}\n\s*qw\(([^)]+)\);/;
ok( $table, 'the %NEEDS_TYPE table is where this test expects it' );
my @declared = split ' ', $table;
cmp_ok( scalar @declared, '>=', 3, 'and it names more than a couple of commands' );

for my $command (@declared) {
    my ( $status, $said ) = run($command);
    isnt( $status, 0, "$command, run with no --type, is genuinely refused" );
    like( $said, qr/--type/, "and the refusal names --type" );
}

done_testing;

__END__

=head1 NAME

289-a-table-that-stopped-being-true.t - a declared table is run, not read

=head1 DESCRIPTION

lib/Tira/CLI.pm's %NEEDS_TYPE table claims a fixed set of commands cannot
work without --type. TKT-409 made that false for column.list and nothing
noticed, because the table's only reader is a --help fallback masked by
SKILLS.md's own correct line. This runs every command the table names, with
no --type, and requires each one to genuinely refuse - so a table entry that
stops being true fails the suite instead of sitting there unread.

=cut
