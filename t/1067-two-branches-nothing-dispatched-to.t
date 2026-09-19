#!/usr/bin/env perl
# TKT-1067: a full-suite Devel::Cover run against lib/Tira/CLI.pm showed two
# genuinely uncovered dispatch branches - the 'rule.suspend' and
# 'column.endings' command names in Tira::CLI's own run() (lines ~1860 and
# ~1868). Every existing test calling rule_suspend/column_endings does so on
# the engine directly ($tira->rule_suspend(...), $tira->column_endings(...)),
# never through Tira::CLI->run() with the command name itself - so the
# dispatch branches that route those command names to the engine were never
# exercised, even though the engine calls they route to were.
#
# (_item_is_done/_first_line, the other two uncovered call sites this card
# originally named, were already closed by t/1097 - confirmed by reading it
# before writing anything new here, rather than re-covering the same ground.)
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new( name => 'Proj', dir => $root, members => ['claude'] );

# Tira::CLI->run() never returns the command's raw result - it always routes
# through format_output and prints, returning only an exit status - so the
# CLI-level claim has to be read back from what it printed, the same way a
# real invocation would be.
sub run_cli {
    my (%args) = @_;
    my $out = '';
    open my $so, '>', \$out or die $!;
    local *STDOUT = $so;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( tira => $tira, %args );
    return ( $status, $out );
}

# --- the 'rule.suspend' dispatch branch -------------------------------------

my ( $suspend_status, $suspend_out ) = run_cli(
    command => 'rule.suspend',
    argv    => [ '--rule', 'card-full-details', '--seconds', '60',
        '--reason', 'testing the dispatch branch itself', '-o', 'json' ],
);
is( $suspend_status, 0, 'the rule.suspend command name reaches the engine through Tira::CLI->run and succeeds, not just $tira->rule_suspend directly' );
my $suspended = decode_json($suspend_out);
is( $suspended->{rule}, 'card-full-details', 'and the rule it actually suspended is the one asked for' );

# --- the 'column.endings' dispatch branch -----------------------------------

my ( $endings_status, $endings_out ) = run_cli( command => 'column.endings', argv => [ '-o', 'json' ] );
is( $endings_status, 0, 'the column.endings command name reaches the engine through Tira::CLI->run too' );
my $endings = decode_json($endings_out);
is( ref $endings, 'HASH', 'answering for all three types when no --type is given, the same as calling the engine directly' );
ok( exists $endings->{ticket}, 'including the ticket type' );

done_testing();

__END__

=head1 NAME

1067-two-branches-nothing-dispatched-to.t - the rule.suspend and
column.endings CLI dispatch branches are exercised, not just the engine
methods they route to

=head1 DESCRIPTION

TKT-1067: a coverage run against C<lib/Tira/CLI.pm> found two genuinely
uncovered dispatch branches, C<$command eq 'rule.suspend'> and
C<$command eq 'column.endings'> in C<Tira::CLI>'s own C<run()>. Every
existing test called C<$tira-E<gt>rule_suspend>/C<$tira-E<gt>column_endings>
directly on the engine, never through C<Tira::CLI-E<gt>run()> with the
command name itself, so the dispatch code routing those names to the engine
was never exercised even though the engine methods themselves were. This
test calls both through C<Tira::CLI-E<gt>run()> the way a real invocation
does.

The other two call sites this card originally named, C<_item_is_done> and
C<_first_line>'s own forwarders in C<lib/Tira/CLI.pm>, were already covered
by C<t/1097> before this card was picked up - confirmed by reading that file
rather than re-covering the same ground with a new test.

=cut
