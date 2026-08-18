#!/usr/bin/env perl
# A card field given to a command that will not write it is refused, not dropped.
#
# Three cards, one cause. TKT-281: tira.<type>.move given --sdlc-gate accepted
# it, dropped it, exited 0 and printed the whole card - which reads as
# confirmation because the card is right there. TKT-302: the same for --comment
# on discard, twice in ten minutes on this project's own board, losing the one
# thing discard-unexplained exists to require. TKT-306 and TKT-360 are the rest
# of that surface, measured: 24 of the 25 fields record_update writes are
# dropped by move, and all eight --set- replacements are dropped by create.
#
# Each of the first two was fixed by adding one name to a table. That table now
# holds three entries against 162 declared options, and a denylist extended one
# incident at a time cannot cover the option nobody has been bitten by yet -
# which is precisely how TKT-306 and TKT-360 came to exist after TKT-281 was
# fixed.
#
# So this asserts the surface rather than the incidents. The list of fields is
# taken from the engine, so a field added to record_update is covered on the day
# it is added rather than on the day somebody is bitten.
#
# What is deliberately NOT swept in, both measured today:
#   - record.create reads all eighteen append fields. The obvious rule "only
#     update writes fields" is wrong, and only the replacements are update-only.
#   - --title on clone is genuinely read. My first probe of clone reported it
#     refused, which was a refusal for a MISSING --title read as a refusal OF
#     the option.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T11:40:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Refused', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RFS', epic_prefix => 'RFE', ticket_prefix => 'RFT',
);

sub run {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the engine says which fields it writes ---------------------------------------
#
# Read from the engine rather than listed here, which is the whole point: a
# field added to record_update joins this test without anybody remembering to
# add it.

my @fields = @{ Tira::card_fields() };
my @replacements = @{ Tira::card_field_replacements() };

{
    ok( scalar @fields, 'the engine says which fields a card update writes' );
    ok( scalar @replacements, 'and which of them can be replaced wholesale' );

    my %field = map { $_ => 1 } @fields;
    ok( $field{priority}, 'priority is one of them' );
    ok( $field{assignee}, 'and assignee' );
    ok( $field{key_details}, 'and a list field' );
    ok( !$field{column}, 'and a column is not a field, because a move is not an edit' );
}

# --- a value given where it cannot land is refused ---------------------------------
#
# The measured case that named TKT-360: 'move --assignee claude --priority 5
# --label urgent --due-date ...' exited successfully and printed the card back
# with all four unchanged.

my %flag = (
    title => 'title', description => 'description',
    problem_or_feature => 'problem', solution_needed => 'solution-needed',
    source => 'source', sdlc_gate => 'sdlc-gate', lifecycle => 'lifecycle',
    fix_version => 'fix-version', sandbox => 'sandbox',
    agent_session => 'agent-session', assignee => 'assignee',
    reporter => 'reporter', priority => 'priority', due_date => 'due-date',
    start_date => 'start-date', labels => 'label',
    affects_versions => 'affects-version', key_details => 'key-detail',
    deliverables => 'deliverable', acceptance => 'acceptance',
    test_steps => 'test-step', bdd => 'bdd', atdd => 'atdd',
    scope_in => 'scope-in', scope_out => 'scope-out',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something to move about', priority => 3 );

{
    my @accepted;
    for my $field (@fields) {
        my $flag = $flag{$field} or next;
        my $value = $field eq 'priority' ? '5'
          : $field =~ /_date\z/ ? '2027-01-01T09:00:00Z'
          : 'a value that has nowhere to land';
        my ( $status, $said ) =
          run( 'ticket.move', '--ref', $card->{ref}, '--column', 'implement',
            "--$flag", $value );
        push @accepted, $flag if $status == 0;
    }
    is_deeply( \@accepted, [],
        'no card field is accepted by a move, which writes none of them' );
}

# --- and the refusal says where the value does belong -------------------------------

{
    my ( $status, $said ) = run( 'ticket.move', '--ref', $card->{ref},
        '--column', 'implement', '--assignee', 'claude' );
    isnt( $status, 0, 'a move given an assignee is refused' );
    like( $said, qr/--assignee/, 'naming the option' );
    like( $said, qr/update/, 'and the command that does write it' );
}

# --- discard and restore too, which drop six of six ---------------------------------

{
    for my $command (qw(ticket.discard ticket.restore)) {
        my ( $status, $said ) =
          run( $command, '--ref', $card->{ref}, '--priority', '5' );
        isnt( $status, 0, "$command given a card field is refused" );
    }
}

# --- create reads the fields, and refuses only the replacements ----------------------
#
# Measured before this was written: create reads all eighteen append fields and
# loses none. The naive rule - only update writes fields - is wrong, and a fix
# built on it would have broken every card this project raises.

{
    my $made = $tira->create_record( project => $root, type => 'ticket',
        title => 'Created with its fields', priority => 4,
        key_details => ['One'], assignee => 'claude' );
    is( $made->{priority}, 4, 'create writes a plain field' );
    is_deeply( $made->{key_details}, ['One'], 'and a list field' );

    my $file = File::Spec->catfile( $tmp, 'replacement.json' );
    open my $fh, '>', $file or die $!;
    print {$fh} '["From a set option"]';
    close $fh;

    my ( $status, $said ) = run( 'ticket.create', '--title', 'Set on create',
        '--set-key-details', $file );
    isnt( $status, 0, 'but a replacement given to create is refused' );
    like( $said, qr/--set-key-details/, 'naming the option' );
}

# --- clone keeps the one option it genuinely reads ------------------------------------
#
# The trap that nearly went in as a finding: my first probe of clone reported
# --assignee refused, and it was a refusal for a MISSING --title.

{
    my ( $status, $said ) =
      run( 'ticket.clone', '--ref', $card->{ref}, '--title', 'A clone by name' );
    is( $status, 0, 'clone still reads the title it has always read' )
      or diag($said);

    my ( $refused ) =
      run( 'ticket.clone', '--ref', $card->{ref}, '--title', 'A clone', '--priority', '5' );
    isnt( $refused, 0, 'and refuses a field it does not write' );
}

# --- proved by dropping the derivation ------------------------------------------------
#
# Without it the move accepts the lot again, exits 0, and prints the card back
# unchanged - which is the state all three cards were raised about.

{
    no warnings 'redefine';
    local *Tira::card_fields = sub { return [] };

    my ( $status, $said ) = run( 'ticket.move', '--ref', $card->{ref},
        '--column', 'done', '--assignee', 'claude' );
    is( $status, 0, 'with nothing derived, the move accepts the option again' );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{assignee}, undef,
        'and drops it, which is what made this worth refusing' );
}

done_testing;

__END__

=head1 NAME

267-an-option-a-command-will-not-act-on.t - the surface behind TKT-281, TKT-302,
TKT-306 and TKT-360

=head1 DESCRIPTION

An option a command will not act on is refused rather than accepted and dropped.
The list of card fields is taken from the engine, so a field added to
C<record_update> is covered on the day it is added rather than on the day
somebody is bitten - which is what a table extended one incident at a time
cannot do.

=cut
