#!/usr/bin/env perl
# TKT-677. tira.conversation.add journals the RECORD under the speaker
# (--author, "who said it") rather than the actual acting author - so an
# agent recording the owner's own words fires card-changed-by-owner one
# line after writing them itself. Reproduced live within a minute of
# filing TKT-676: recording the owner's own message immediately made
# police report that the owner had edited the card.
#
# The fix threads the CLI's own TIRA_AUTHOR (the session's real actor,
# already the standing convention every other command relies on) through
# as a separate acting_author, used for the journal, while --author still
# names the speaker on the conversation entry itself and in
# conversation.list, exactly as documented. Calls with no acting_author
# (a direct engine call, or a CLI invocation with no TIRA_AUTHOR set) fall
# back to the speaker, unchanged from today's behaviour.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-08T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Overheard', dir => $root, members => [ 'claude', 'michael' ], agent => 'claude',
    columns => ['backlog, implement, done'],
    sow_prefix => 'OHS', epic_prefix => 'OHE', ticket_prefix => 'OHT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x', author => 'claude' );

sub changed_findings {
    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'store' ), world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'card-changed-by-owner' } @{ $pass->{violations} } ];
}

$tira->policy_add( project => $root, rule => 'card-changed-by-owner', action => 'bridge-reminder' );

# --- the CLI path: the agent records what the owner said, via --author michael

sub run {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    open my $out, '>', \my $stdout or die $!;
    my $old = select $out;
    my $status = Tira::CLI->run( command => 'conversation.add', tira => $tira, argv => \@argv );
    select $old;
    return ( $status, $stdout );
}

my ( $status, $out ) = run(
    '--ref', $card->{ref}, '--author', 'michael', '--said', 'the problem is on port 7899', '-o', 'json',
);
is( $status, 0, 'the CLI call succeeds' );

is( scalar @{ changed_findings() }, 0,
    'recording the owner\'s own words, via the CLI with TIRA_AUTHOR=claude, does not fire card-changed-by-owner' );

my $listed = $tira->conversation_list( project => $root, ref => $card->{ref} );
is( $listed->[0]{author}, 'michael', 'conversation.list still shows the owner as the speaker' );

# --- a genuine owner change still trips the rule, exactly as today ---------

$tira->record_update( project => $root, ref => $card->{ref}, author => 'michael', title => 'Retitled by the owner' );
my @found = @{ changed_findings() };
is( scalar @found, 1, 'a real owner edit still fires the rule' );
is( $found[0]{ref}, $card->{ref}, 'naming the card the owner actually changed' );

# --- unchanged: a direct engine call with no acting_author still journals
# under the speaker, exactly as it always has -------------------------------

$tira->conversation_add( project => $root, ref => $card->{ref}, author => 'michael', said => 'a second thing' );
my $journal = $tira->history_list( project => $root, ref => $card->{ref} );
is( $journal->[-1]{author}, 'michael',
    'a direct engine call with no acting_author still journals under the speaker' );

done_testing();

__END__

=head1 NAME

677-a-speaker-mistaken-for-the-owner.t - conversation_add journals under
the acting author, not the speaker

=head1 DESCRIPTION

TKT-677. C<tira.conversation.add> stores C<--author> as the speaker on
the conversation entry, exactly as documented, but no longer journals
the card's change under that name - the CLI thread its own
C<TIRA_AUTHOR> through as C<acting_author>, which C<conversation_add>
uses for C<_journal_author> when given, falling back to the speaker
otherwise. C<card-changed-by-owner> - deliberately stateless, settling
the moment any change touches the card - now correctly sees the agent's
own write as the agent's own write.

=cut
