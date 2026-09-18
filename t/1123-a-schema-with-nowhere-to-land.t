#!/usr/bin/env perl
# TKT-1123, TG msg #8571/#8572. Michael's request: capture a board's shape -
# policies, columns (which is also the column chain, since 'next' lives
# inside each column entry), entry point, column prefix, required actions -
# and lay that shape onto a fresh board, "everything but except the cards...
# except jobs and tasks". Q-172, answered live: a new flag on the EXISTING
# onboard command, not a standalone command.
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
require Tira::CLI::Wizard;

sub run_cli {
    my ( $tira, $root, $command, @argv ) = @_;
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
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# The wizard is the only path to 'onboard' (Tira::CLI::run always reads it
# through Tira::CLI::Wizard::_project_wizard), so exercising --from-schema
# means answering it, same as t/41-project-wizard.t. Forcing _agent_available
# off skips the reminder-job questions this schema has nothing to do with.
sub answers {
    my ($script) = @_;
    open my $fh, '<', \$script or die $!;
    return $fh;
}

sub run_onboard {
    my ( $script, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    no warnings 'redefine';
    local *Tira::CLI::_agent_available = sub { 0 };
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'onboard', argv => \@argv, input => answers($script) );
    };
    return ( $status, $out . $err );
}

my $tmp = tempdir( CLEANUP => 1 );

# Source board: custom columns/prefix, one declared and one declined policy.
my $source = File::Spec->catdir( $tmp, 'source' );
my $tira   = Tira->new( clock => sub {'2026-09-18T00:00:00Z'} );
$tira->project_new(
    name => 'Schema Source', dir => $source, members => ['claude'],
    columns       => ['backlog, tests-red, done'],
    sow_prefix    => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);
$tira->policy_add( project => $source, rule => 'orphan-card', action => 'log-only' );
$tira->policy_decline(
    project => $source, rule => 'card-duration',
    reason  => 'not wanted on this schema', author => 'claude',
);

my $schema_file = File::Spec->catfile( $tmp, 'schema.json' );
my ( $status, $out ) = run_cli( $tira, $source, 'schema.export', '--file', $schema_file, '-o', 'json' );
is( $status, 0, 'schema.export exits clean' ) or diag($out);
ok( -e $schema_file, 'schema.export wrote the file it was told to' );

# Fresh board, onboarded FROM that schema. Typed answers here deliberately
# name DIFFERENT columns/prefixes than the schema, to prove --from-schema
# really overrides whatever the wizard itself just wrote rather than merely
# filling gaps.
my $target = File::Spec->catdir( $tmp, 'target' );
( $status, $out ) = run_onboard( <<"ANSWERS", '--from-schema', $schema_file, '-o', 'json' );
$target
Schema Target
claude
ZZS
ZZE
ZZT
y
Backlog, Working, Done

single
y
ANSWERS
is( $status, 0, 'onboard --from-schema exits clean' ) or diag($out);

# Found by hand in this ticket's own test-steps walkthrough, not by Codex or
# the automated suite: onboard's own printed result kept showing the WIZARD'S
# TYPED prefixes (ZZS/ZZE/ZZT) even after schema_import had silently
# overridden them on disk - a command reporting something other than what it
# actually did, which is exactly the fault SOW-004 exists to find.
my ($json_line) = $out =~ /(\{.*\})\s*\z/s;
my $printed = eval { decode_json($json_line // '') };
ok( $printed, 'onboard --from-schema printed valid JSON' ) or diag($out);
is_deeply(
    [ sort map { $_->{prefix} } @{ $printed->{boards} } ],
    [ sort qw(SCS SCE SCT) ],
    "onboard's own printed result names the schema's real prefixes, not the wizard's typed ZZS/ZZE/ZZT"
);

my $source_columns = $tira->column_list( project => $source, type => 'ticket' );
my $target_columns = $tira->column_list( project => $target, type => 'ticket' );
is_deeply( $target_columns, $source_columns,
    'the ticket column chain (including entry point and required actions) landed on the target board unchanged' );

my $source_refs = $tira->board_refs( project => $source, type => 'ticket' );
my $target_refs = $tira->board_refs( project => $target, type => 'ticket' );
is( $target_refs->{prefix}, $source_refs->{prefix}, 'the source prefix overrode the typed one' );
is( $target_refs->{digits}, $source_refs->{digits}, 'the source digits landed on the target board' );

my $source_policies = $tira->policy_list( project => $source );
my $target_policies = $tira->policy_list( project => $target );
is_deeply(
    [ sort map { $_->{rule} } @{$target_policies} ],
    [ sort map { $_->{rule} } @{$source_policies} ],
    'the declared policy landed on the target board',
);

# CODEX REVIEW: the first draft never checked declined_policies at all,
# and never checked any type but ticket.
is_deeply(
    [ sort map { $_->{rule} } @{ $tira->policy_declined( project => $target ) } ],
    [ sort map { $_->{rule} } @{ $tira->policy_declined( project => $source ) } ],
    'the declined policy landed on the target board too, not just the declared one',
);
for my $type (qw(sow epic)) {
    is_deeply(
        $tira->column_list( project => $target, type => $type ),
        $tira->column_list( project => $source, type => $type ),
        "the $type column chain landed on the target board too, not just ticket's"
    );
}

my $target_ticket = $tira->create_record( project => $target, type => 'ticket', title => 'First on the new board' );
is( $target_ticket->{ref}, 'SCT-001',
    'the target board really uses the imported prefix (not the typed ZZT one), proven by creating a card on it' );

# CODEX REVIEW: the first draft never proved policy_counter survived the
# import - a fresh target's own counter starts at 0, so a declared POL-001
# imported from the source without also importing the counter would let the
# NEXT tira.policy.add on the target reissue that same id.
my $new_policy = $tira->policy_add( project => $target, rule => 'card-full-details', enter => 'implement', action => 'log-only' );
isnt( $new_policy->{id}, ( $tira->policy_list( project => $target ) )->[0]{id},
    'a policy declared on the target AFTER the import gets a fresh id, not a reissued one' );

# CODEX REVIEW: --from-schema on a board that already has real work on it
# used to overwrite that board's columns/prefix unconditionally, which can
# orphan cards sitting in a column the new layout no longer has, or split
# a reference series against a changed prefix. It now refuses per type.
{
    my $lived_in = File::Spec->catdir( $tmp, 'lived-in' );
    $tira->project_new(
        name => 'Already Working', dir => $lived_in, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'LIS', epic_prefix => 'LIE', ticket_prefix => 'LIT',
    );
    $tira->create_record( project => $lived_in, type => 'ticket', title => 'Real work already here' );
    eval { $tira->schema_import( project => $lived_in, file => $schema_file ) };
    like( $@, qr/already has 1 ticket record/,
        'schema_import refuses to overwrite a board that already has real records on it' );
    is( $tira->board_refs( project => $lived_in, type => 'ticket' )->{prefix}, 'LIT',
        'the refused board keeps its own prefix - the refusal happens before anything is written' );
}

# CODEX REVIEW: a malformed schema (no types, or a type with no columns)
# used to be accepted at face value.
{
    my $malformed = File::Spec->catfile( $tmp, 'malformed.json' );
    open my $fh, '>', $malformed or die $!;
    print {$fh} '{"schema_version":1,"types":{}}';
    close $fh;
    my $empty_target = File::Spec->catdir( $tmp, 'empty-target' );
    $tira->project_new(
        name => 'Empty Target', dir => $empty_target, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'EMS', epic_prefix => 'EME', ticket_prefix => 'EMT',
    );
    eval { $tira->schema_import( project => $empty_target, file => $malformed ) };
    like( $@, qr/no 'types' section|no recognised board type/,
        'schema_import refuses a schema naming no board type' );
}

# CODEX REVIEW, second pass: a recognised type with no columns, a
# non-object column, and a column name that is not a valid slug all used
# to be accepted at face value too.
for my $case (
    [ 'empty columns array',    { ticket => { prefix => 'ZZT', digits => 3, columns => [] } }, qr/has no columns to import/ ],
    [ 'a non-object column',    { ticket => { prefix => 'ZZT', digits => 3, columns => ['not-an-object'] } }, qr/malformed column/ ],
    [ 'an invalid column name', { ticket => { prefix => 'ZZT', digits => 3, columns => [ { name => 'Not Valid!' } ] } }, qr/invalid column 'Not Valid!'/ ],
    [ 'an invalid prefix',      { ticket => { prefix => 'not-a-prefix', digits => 3, columns => [ { name => 'backlog' } ] } }, qr/invalid prefix/ ],
    [ 'invalid digits',         { ticket => { prefix => 'ZZT', digits => 99, columns => [ { name => 'backlog' } ] } }, qr/invalid digits/ ],
) {
    my ( $label, $types, $expect ) = @{$case};
    my $bad = File::Spec->catfile( $tmp, "bad-$label.json" );
    $bad =~ s/ /-/g;
    open my $fh, '>', $bad or die $!;
    require Cpanel::JSON::XS;
    print {$fh} Cpanel::JSON::XS->new->encode( { schema_version => 1, types => $types } );
    close $fh;
    my $victim = File::Spec->catdir( $tmp, "victim-$label" );
    $victim =~ s/ /-/g;
    $tira->project_new(
        name => "Victim $label", dir => $victim, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'VCS', epic_prefix => 'VCE', ticket_prefix => 'VCT',
    );
    eval { $tira->schema_import( project => $victim, file => $bad ) };
    like( $@, $expect, "schema_import refuses a schema with $label" );
}

# CODEX REVIEW, third pass: policy_counter itself was never validated - a
# hand-edited schema naming a negative or non-numeric one would have been
# stored verbatim, and the next policy_add could mint an invalid id.
{
    require Cpanel::JSON::XS;
    my $bad = File::Spec->catfile( $tmp, 'bad-policy-counter.json' );
    open my $fh, '>', $bad or die $!;
    print {$fh} Cpanel::JSON::XS->new->encode( {
        schema_version => 1,
        types          => { ticket => { prefix => 'ZZT', digits => 3, columns => [ { name => 'backlog' } ] } },
        policy_counter => -1,
    } );
    close $fh;
    my $victim = File::Spec->catdir( $tmp, 'victim-policy-counter' );
    $tira->project_new(
        name => 'Victim Policy Counter', dir => $victim, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'VPS', epic_prefix => 'VPE', ticket_prefix => 'VPT',
    );
    eval { $tira->schema_import( project => $victim, file => $bad ) };
    like( $@, qr/invalid policy_counter/, 'schema_import refuses a schema with a negative policy_counter' );
}

# CODEX REVIEW, third pass: the "counter present, ledgers empty" case, and
# the "a ledger id already exceeds the schema's own counter" case - both
# already handled by the normal-path code, neither directly exercised.
{
    require Cpanel::JSON::XS;
    my $counter_only = File::Spec->catfile( $tmp, 'counter-only.json' );
    open my $fh, '>', $counter_only or die $!;
    print {$fh} Cpanel::JSON::XS->new->encode( {
        schema_version => 1,
        types          => { ticket => { prefix => 'ZZT', digits => 3, columns => [ { name => 'backlog' } ] } },
        policy_counter => 7,
    } );
    close $fh;
    my $target_a = File::Spec->catdir( $tmp, 'counter-only-target' );
    $tira->project_new(
        name => 'Counter Only Target', dir => $target_a, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'COS', epic_prefix => 'COE', ticket_prefix => 'COT',
    );
    $tira->schema_import( project => $target_a, file => $counter_only );
    my ( undef, $project_data ) = $tira->_project_data($target_a);
    is( $project_data->{policy_counter}, 7,
        'policy_counter alone (no policies/declined_policies keys at all) still lands on the target' );

    my $stale_counter = File::Spec->catfile( $tmp, 'stale-counter.json' );
    open my $fh2, '>', $stale_counter or die $!;
    print {$fh2} Cpanel::JSON::XS->new->encode( {
        schema_version => 1,
        types          => { ticket => { prefix => 'ZZT', digits => 3, columns => [ { name => 'backlog' } ] } },
        policy_counter => 1,
        policies       => [ { id => 'POL-005', rule => 'orphan-card', action => 'log-only', declared_at => '2026-01-01T00:00:00Z' } ],
    } );
    close $fh2;
    my $target_b = File::Spec->catdir( $tmp, 'stale-counter-target' );
    $tira->project_new(
        name => 'Stale Counter Target', dir => $target_b, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'SCOS', epic_prefix => 'SCOE', ticket_prefix => 'SCOT',
    );
    $tira->schema_import( project => $target_b, file => $stale_counter );
    ( undef, $project_data ) = $tira->_project_data($target_b);
    is( 0 + $project_data->{policy_counter}, 5,
        'a ledger id (POL-005) higher than the schema\'s own stale counter (1) wins, so the next policy_add cannot collide' );
}

done_testing;

__END__

=head1 NAME

1123-a-schema-with-nowhere-to-land.t - a board's shape, exported and re-onboarded

=head1 DESCRIPTION

C<tira.schema.export --file FILE> and C<tira.onboard --from-schema FILE> did
not exist before TKT-1123. This proves the round trip: a source board's
per-type columns (the column chain lives inside each column's own C<next>),
prefix, digits and declared/declined policies all land unchanged on a fresh
board onboarded from the exported file, overriding whatever the wizard's own
questions were just answered with - explicitly excluding cards, jobs and
tasks, which is Michael's own stated scope for what a schema is.

=cut
