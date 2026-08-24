#!/usr/bin/env perl
# TKT-303. "Both halves are correct about the DECLARED repo and wrong about
# the work" - card-sandbox-missing (and every other rule) had no way to say
# "yes, and it is somewhere else" for one specific card. The only options
# were declining the whole rule board-wide (losing the check for every other
# card) or leaving a permanent unclearable violation - and this project's own
# standing instruction is that every outstanding violation is followed up
# until cleared, so a finding that cannot be cleared honestly is worse than
# one that is merely wrong.
#
# Q-071 answered: "A) New generic per-card decline mechanism (works for any
# rule, not just card-sandbox-missing), requires a reason like project-level
# decline does."

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T13:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Elsewhere', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'ELS', epic_prefix => 'ELE', ticket_prefix => 'ELT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

# card-sandbox-missing refuses to be declared where no repository can be
# resolved; a fake .git is the ordinary case for a real board. TKT-178.
mkdir File::Spec->catdir( $root, '.git' );

$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/work', action => 'bridge-reminder' );

my $mine  = $tira->create_record( project => $root, type => 'ticket', title => 'Worked in another repo' );
$tira->record_move( author => 'claude', project => $root, ref => $mine->{ref}, column => 'implement' );

my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Also unmatched, unrelated' );
$tira->record_move( author => 'claude', project => $root, ref => $other->{ref}, column => 'implement' );

my $world = { branches => [], worktrees => [], processes => [], containers => [] };

sub sandbox_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => $world );
    return [ grep { $_->{rule} eq 'card-sandbox-missing' } @{ $pass->{violations} } ];
}

# --- both cards are reported before any decline -----------------------------
my @before = @{ sandbox_findings() };
is( scalar @before, 2, 'both cards are reported before any decline' );

# --- declining board-wide is refused without a reason -----------------------
my $error = eval { $tira->policy_decline( project => $root, rule => 'card-sandbox-missing',
    ref => $mine->{ref} ); 1; } ? '' : $@;
like( $error, qr/needs a reason/, 'declining for one card still requires a reason' );

# --- declining FOR ONE CARD leaves the rule declared board-wide -------------
my $declined = $tira->policy_decline( project => $root, rule => 'card-sandbox-missing',
    ref => $mine->{ref}, reason => 'work lives in the dd-tg repo, not the declared one',
    author => 'claude' );
is( $declined->{ref}, $mine->{ref}, 'the decline records which card it is about' );
ok( ( grep { $_->{rule} eq 'card-sandbox-missing' } @{ $tira->policy_list( project => $root ) } ),
    'and the rule is still declared board-wide - a per-card decline is not a project-wide one' );

# --- and it suppresses the finding for THAT card only ------------------------
my @after = @{ sandbox_findings() };
is( scalar @after, 1, 'only one card is reported now' );
is( $after[0]{ref}, $other->{ref}, 'the card that was NOT declined - the decline is genuinely scoped, not board-wide' );

# --- the decline is readable back, per card ----------------------------------
my $mine_declines = $tira->policy_declined( project => $root, ref => $mine->{ref} );
is( scalar @{$mine_declines}, 1, 'the declined card shows one recorded decline' );
is( $mine_declines->[0]{reason}, 'work lives in the dd-tg repo, not the declared one',
    'carrying the reason it was given' );
is_deeply( $tira->policy_declined( project => $root, ref => $other->{ref} ), [],
    'the other card shows none - it was never declined' );

# --- reusable by a different rule, not scoped to card-sandbox-missing --------
$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );
my $declined_other_rule = $tira->policy_decline( project => $root, rule => 'card-unassigned',
    ref => $other->{ref}, reason => 'reserved for someone joining next week', author => 'claude' );
is( $declined_other_rule->{rule}, 'card-unassigned', 'the same mechanism works for an unrelated rule' );

# --- the real CLI command, through --ref --------------------------------------
sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'policy.decline', argv => \@argv );
    return ( $status, $out, $err );
}

my $third = $tira->create_record( project => $root, type => 'ticket', title => 'Declined from the CLI' );
$tira->record_move( author => 'claude', project => $root, ref => $third->{ref}, column => 'implement' );
my ( $status, $out ) = cli(
    '--rule', 'card-sandbox-missing', '--ref', $third->{ref},
    '--reason', 'legitimately elsewhere too', '-o', 'json',
);
is( $status, 0, 'tira.policy.decline --ref succeeds through the real CLI' ) or diag($out);
is_deeply( [ map { $_->{ref} } @{ sandbox_findings() } ], [ $other->{ref} ],
    'and the CLI-declined card no longer reports either' );

done_testing;

__END__

=head1 NAME

382-a-decision-a-later-reader-can-see.t - a rule can be declined for one card without declining it board-wide

=head1 DESCRIPTION

TKT-303: card-sandbox-missing (and every rule) could only be declined
board-wide or left as a permanent unclearable violation on a card whose
work legitimately lives outside the declared repository. policy_decline
and policy_declined now accept an optional --ref, scoping the decision to
one card - requiring a reason exactly like the existing board-wide
decline, leaving the rule declared for every other card, and readable
back per card. Reusable by any rule, not scoped to card-sandbox-missing.
