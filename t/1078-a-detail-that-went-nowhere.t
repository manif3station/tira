#!/usr/bin/env perl
# TKT-1077. record.update accepts --details (the shared parser knows it,
# since gate.add/evidence.add both take it), but a ticket/epic/sow has no
# 'details' field at all - the narrative field is key_details. Reproduced
# live: 'd2 tira.ticket.update --ref REF --author claude --details TEXT'
# exits 0, prints the card unchanged, and --details is written nowhere.
# %OPTION_READ_BY in lib/Tira/CLI/Options.pm already covers this exact
# anti-pattern for --sdlc-gate, --comment, --uri and others, but had no
# entry for 'details' - it is genuinely read only by gate_add and
# evidence_add (lib/Tira.pm:4432, 4471).
#
# release.record is a genuine reader too - it requires --details itself and
# forwards it into its own internal gate_add call per ref. Missed in this
# fix's first draft (which named only gate.add/evidence.add) and caught by
# Codex review before it shipped: t/293-a-release-recorded-once.t's whole
# suite (32 assertions) broke live the moment the first draft's guard
# landed, since release.record's own command name never matched
# qr/\Agate\.add\z/.
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
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Detailless', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'DLS', epic_prefix => 'DLE', ticket_prefix => 'DLT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing reads this yet' );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, type => 'ticket', tira => Tira->new, argv => [@argv] );
    };
    return ( $status, $out, $err );
}

# --- the silent swallow --------------------------------------------------

my ( $status, $out, $err ) = run( 'record.update', '--ref', $card->{ref},
    '--author', 'claude', '--details', 'this should refuse, not vanish' );
isnt( $status, 0, 'record.update --details is refused, not silently accepted' );
like( $err, qr/details/, 'and the refusal names --details' );
like( $err, qr/gate\.add/, "and it points at gate.add - the command that actually reads it" );

# --- and the same value still works where it belongs ----------------------
#
# evidence.add is NOT a reader, despite this ticket's own first draft
# claiming otherwise - it already has its own %MISLEADING_OPTIONS refusal
# for --details (pointing at --summary), confirmed live against
# evidence_add's own source before trusting the ticket's premise.

( $status ) = run( 'gate.add', '--ref', $card->{ref}, '--author', 'claude',
    '--gate', 'verify', '--result', 'pass', '--details', 'still accepted here' );
is( $status, 0, '--details still works on gate.add' );

# release.record dispatches to its own type-less command form.
( $status ) = run( 'release.record', '--ref', $card->{ref}, '--author', 'claude',
    '--gate', 'ship', '--result', 'pass', '--details', 'release note',
    '--evidence', 'suite green', '--fix-version', '9.9' );
is( $status, 0, '--details still works on release.record, which forwards it into its own gate_add call' );

( $status, undef, $err ) = run( 'evidence.add', '--ref', $card->{ref}, '--author', 'claude',
    '--summary', 'proof', '--details', 'not a real evidence.add field' );
isnt( $status, 0, 'evidence.add --details is STILL refused - it was never a real reader' );
like( $err, qr/--summary/,
    "and its own pre-existing, more specific refusal (t/153) still wins, naming --summary - "
  . 'not this guard\'s generic message' );

done_testing;

__END__

=head1 NAME

1078-a-detail-that-went-nowhere.t - --details on record.update refuses rather than vanishing

=head1 DESCRIPTION

TKT-1077. A ticket/epic/sow has no C<details> field - the narrative field
is C<key_details> - so C<record.update --details TEXT> used to exit 0,
print the card unchanged, and write nothing. C<%OPTION_READ_BY> already
guards this exact shape for C<--sdlc-gate>/C<--comment>/C<--uri>; this adds
the same guard for C<--details>, naming C<gate.add>/C<evidence.add> as the
commands that genuinely read it.

=cut
