#!/usr/bin/env perl
# TKT-1070. dashboard.sow/.epic/.ticket dispatch to the same shared 'dashboard'
# GetOptions spec as bare `dashboard` (aliased at lib/Tira/CLI.pm:1858), so
# they silently accept every dashboard flag - confirmed live: --show-logs and
# --ssl parse without an "unknown option" error for all three. But --help for
# these three (sourced from SKILLS.md's own usage-line catalogue, via
# Tira::CLI::Usage) only ever listed --include-discard/--title/-o, then (as
# of TKT-1068) also the police/policy-bridge/session-expire bundle - never
# --show-logs, --ssl, or --with-questions (the third omission, found by Codex
# review during this same card - also genuinely accepted, confirmed live). A
# reader asking --help is told less than the command actually does. This file
# checks the three flags found missing so far, not every flag the shared spec
# happens to define - a future flag added to that spec needs its own check.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read '$path': $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

my $skills = slurp('SKILLS.md');
ok( $skills, 'SKILLS.md was read - not empty, not truncated' );

for my $cmd (qw(sow epic ticket)) {
    my ($line) = $skills =~ /^tira\.dashboard\.\Q$cmd\E\s+(\S.*)$/m;
    ok( $line, "SKILLS.md carries a usage line for tira.dashboard.$cmd" );
    next unless $line;
    like( $line, qr/--with-questions/, "tira.dashboard.${cmd}'s usage line lists --with-questions, which it genuinely accepts" );
    like( $line, qr/--show-logs/,      "tira.dashboard.${cmd}'s usage line lists --show-logs, which it genuinely accepts" );
    like( $line, qr/--ssl/,            "tira.dashboard.${cmd}'s usage line lists --ssl, which it genuinely accepts" );
}

done_testing;

__END__

=head1 NAME

t/1071-a-usage-line-that-forgot-two-flags.t - dashboard.sow/.epic/.ticket's
usage lines name the flags found silently accepted but undocumented

=head1 DESCRIPTION

TKT-1070. dashboard.sow/.epic/.ticket alias into the same shared 'dashboard'
option spec as bare C<dashboard> (lib/Tira/CLI.pm:1858), so C<--show-logs>,
C<--ssl>, and C<--with-questions> are genuinely accepted by all three -
confirmed live, none errors as an unknown option. SKILLS.md's usage lines
for these three commands, which C<--help> is generated from, did not name
any of the three. This checks exactly those three, not every flag the
shared spec happens to define.

=cut
