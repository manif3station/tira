#!/usr/bin/env perl
# TKT-1118. Flagged by Codex review of TKT-1114's own fix (2026-09-16),
# scoped out of that ticket deliberately rather than folded in. TKT-1114
# fixed the exact same race for _announce_upgrade, moving its
# read-decide-write into _with_project_lock - but a grep for the same
# read-then-write-enforcement.json shape elsewhere in lib/Tira.pm found
# five more unlocked callers of the same store, each free to clobber
# another's write mid-flight: bridge_write, bridge_touch,
# _enforcement_record, rule_suspend, police_suspend.
#
# A second Codex pass, run against THIS ticket's own fix while documenting
# it, caught that _announce_upgrade's _with_project_lock is a different
# mutex (keyed on the project root) than _with_enforcement_lock (keyed on
# the store path) - so even after the five above were fixed,
# _announce_upgrade still didn't share a lock with any of them and could
# still race them. _announce_upgrade now ALSO takes _with_enforcement_lock,
# nested inside its existing project lock; t/1119 checks that nesting and
# its ordering directly. This file's own scope stays the five callers
# named above, all of which take only _with_enforcement_lock with no
# project lock involved.
#
# Same technique t/1119 already established for TKT-1114's own fix, and
# for the identical reason stated there: a monkeypatched "concurrent" call
# racing one of several call sites in a large method proved fragile to
# write and no more convincing than reading the fix straight from its own
# source.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use lib 't/lib';
use Suite ();

my $engine = Suite::engine_source();
# non-empty is the whole claim - every check below would pass on an
# unreadable file's own emptiness otherwise.
like( $engine, qr/\S/, 'the engine source is there to be read' );

for my $name (qw(bridge_write bridge_touch _enforcement_record rule_suspend police_suspend)) {
    my ($body) = $engine =~ /(sub \s+ \Q$name\E \s* \{ .*? \n \})/xs;
    ok( defined $body, "$name was found to read" )
      or next;
    like( $body, qr/_with_enforcement_lock/,
        "$name wraps its enforcement.json read-modify-write in _with_enforcement_lock, "
          . "so two writers racing the same store cannot both decide before either writes" );
}

# rule_suspend calls _enforcement_record internally (to log the suspension
# as an entry, right after writing the rule itself) - if BOTH are wrapped
# in _with_enforcement_lock independently, that inner call re-enters the
# SAME lock from inside the SAME process. flock() blocks a second open
# file description on the same path even from the process already
# holding it, so an unguarded second acquisition here is a genuine
# deadlock, not merely a slow path - proved by actually calling it, not
# only by reading the source, since a lock primitive that LOOKS reentrant
# in prose but isn't in flock() semantics is exactly the kind of bug that
# passes review and hangs in production.

use File::Spec;
use File::Temp qw(tempdir);
use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );
my $tira  = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );
$tira->project_new( name => 'Locks', dir => $root, members => ['claude'] );

my $result = eval {
    local $SIG{ALRM} = sub { die "TKT-1118: rule_suspend deadlocked re-entering its own enforcement lock\n" };
    alarm(5);
    my $r = $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-duration', seconds => 60, reason => 'proving the lock is reentrant' );
    alarm(0);
    $r;
};
my $error = $@;
alarm(0);
ok( !$error, 'rule_suspend, which itself calls _enforcement_record under the same lock, does not deadlock' )
  or diag("died: $error");
is( $result->{rule}, 'card-duration', 'and it actually completed its own work, not merely avoided hanging' );

done_testing();

__END__

=head1 NAME

1144-five-writers-no-doorman.t - five more enforcement.json read-modify-write
callers are locked, and the lock is reentrant

=head1 DESCRIPTION

TKT-1118. Five callers of C<lib/Tira.pm>'s C<_enforcement_read>/
C<_enforcement_write> pair - C<bridge_write>, C<bridge_touch>,
C<_enforcement_record>, C<rule_suspend>, C<police_suspend> - ran with no
exclusion across the read-decide-write span, the identical race TKT-1114
already fixed for C<_announce_upgrade>. Checked the same way t/1119 checks
TKT-1114's own fix: read the source directly rather than trying to force
a real race deterministically.

A sixth caller, C<_announce_upgrade> itself, is checked separately by
t/1119 rather than here: its read-modify-write is nested inside
C<_with_project_lock> rather than standing alone, so the source-matching
shape this file uses for the other five (a bare function body containing
C<_with_enforcement_lock>) does not distinguish it from an unlocked
caller - t/1119 checks its specific nesting and ordering instead. Together
the two files cover every C<_enforcement_read>/C<_enforcement_write> pair
in C<lib/Tira.pm>.

C<rule_suspend> calls C<_enforcement_record> internally, so wrapping both
independently in C<_with_enforcement_lock> makes the inner call re-enter a
lock the outer call already holds - proved not to deadlock by actually
calling it under a bounded C<alarm()>, since a lock primitive that reads as
reentrant in prose is only actually reentrant if its code says so.

=cut
