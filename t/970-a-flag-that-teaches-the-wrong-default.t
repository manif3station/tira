#!/usr/bin/env perl
# record_list accepts include_discard and reads it nowhere - eight callers
# pass a no-op that teaches the opposite of what the default does.
#
# TKT-970, EPC-007. record_list never filters by column - discard included -
# with or without include_discard=>1. Eight call sites across lib/ (seven in
# lib/Tira.pm, one in lib/Tira/Attachment.pm that a first draft of this fix
# missed - Codex review: the caller scan was scoped to lib/Tira.pm alone)
# passed it anyway - which reads as "record_list normally hides discarded
# cards, and I am opting back in", the opposite of the truth. Two callers
# that call record_list WITHOUT the flag (person_remove, link_type_remove)
# already see discarded cards today, which is the proof the flag changes
# nothing anywhere: removing it from the eight that pass it is a
# documentation fix, not a behaviour change.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite qw(engine_source);

# engine_source() walks lib/ (Tira.pm and every lifted concern, CLI excluded)
# rather than naming a file - the guard t/486 exists for: nine tests used to
# open lib/Tira.pm by name and broke on every lift that moved code out of it
# without changing what any of them actually claimed.
my $source = engine_source();

# --- the flag is genuinely a no-op, WITHIN record_list's own body ----------
#
# dashboard() and column_list read $args{include_discard} on their OWN args
# for their own, real filtering - a different flag on a different method,
# despite the identical name. Scoped to record_list's own sub block, or this
# assertion would fail on those legitimate readers instead of proving
# anything about the method this card is about.

my ($record_list_body) = $source =~ /^sub record_list \{(.*?)^\}/ms;

ok( $record_list_body, "record_list itself was found in the engine, and has a real, non-empty body" );

unlike( $record_list_body, qr/\$args\{include_discard\}/,
    "record_list's own body never reads \$args{include_discard} - the flag "
      . 'is accepted and does nothing, which is the fault this card is about' );

# --- no call site anywhere in the engine passes an argument the method never
# reads

my @noop_callers = $source =~ /record_list\([^)]*include_discard\s*=>\s*1[^)]*\)/g;

is( scalar @noop_callers, 0,
    'no call site anywhere in the engine passes include_discard - '
      . scalar(@noop_callers)
      . ' still do today, teaching a filter that does not exist' )
  or diag( join "\n", @noop_callers );

# --- record_list's own POD says what the default really is -----------------
#
# lib/Tira.pod is documentation, not the code this file's own claim is about
# finding by walking rather than naming - t/486's rule is scoped to source,
# and reading the POD by name here is the exemption t/430/t/402 already
# establish: this test's claim IS about this specific file's own words.

open my $pod_fh, '<', 'lib/Tira.pod' or die "lib/Tira.pod: $!";
local $/;
my $pod_text = <$pod_fh>;
close $pod_fh;

my ($record_list_pod) = $pod_text =~ /\Q=head2 record_list\E(.*?)(?=\n=head2 |\z)/s;

ok( defined $record_list_pod && $record_list_pod =~ /discard/i,
    "record_list's own POD section says something about discard - the "
      . 'plain statement of the true default this card asks for' );

done_testing();

__END__

=head1 NAME

970-a-flag-that-teaches-the-wrong-default.t - record_list's include_discard
argument is removed everywhere it was a no-op, and the true default is
written down instead

=head1 WHY

TKT-970. C<record_list> never filters discarded cards out, so
C<include_discard =E<gt> 1> does nothing - not for the eight callers who
pass it, and not for C<person_remove>/C<link_type_remove>, who see discarded
cards today without passing it at all. Passing it anyway teaches every
reader of those eight call sites a filter that has never existed.

=head1 WHAT IS ASSERTED

That the flag is genuinely unread (the fault), that no call site anywhere in
the engine passes it any more (the fix, found by walking rather than naming
a file - t/486), and that C<record_list>'s own POD states the true default
in its place, so a reader loses nothing that the misleading argument used to
seem to promise.

=cut
