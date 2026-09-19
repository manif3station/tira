#!/usr/bin/env perl
# TKT-1072. dashboard.sow/.epic/.ticket dispatch to the same shared 'dashboard'
# GetOptions spec as bare `dashboard` (lib/Tira/CLI.pm:1858), so all four
# genuinely accept the identical flag set except --type (fixed by the
# command name itself for the three type-specific forms, and the one
# variable flag for bare dashboard). SKILLS.md hand-maintains four separate,
# nearly-identical usage-line strings for this one shared spec, and it has
# drifted twice in one day (TKT-1068, TKT-1070) from exactly that duplication
# - each fix named the flags found missing SO FAR (t/1071), not a general
# guard against the next one.
#
# This compares the four lines directly against each other rather than
# against a hand-named list, so a flag added to the shared spec tomorrow and
# missed on even one of the four lines fails here immediately - the same
# rule this whole card exists because two hand-copies had already drifted
# from a third.
#
# By design (Codex review pass), this catches DRIFT between the four lines,
# not a flag missing from all four at once - a genuinely different failure
# (the whole catalogue lagging the real Getopt spec), which is what
# TKT-1034/1050's own family of tests already checks against lib/Tira/CLI.pm
# directly. A short flag like -o is compared too, not only long --flags -
# caught live: an injected -O in place of -o silently vanished from both
# sides under a long-flag-only regex, until the pattern was widened to match
# either dash count.
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

my %line;
for my $cmd (qw(dashboard dashboard.sow dashboard.epic dashboard.ticket)) {
    my ($line) = $skills =~ /^tira\.\Q$cmd\E\s+(\S.*)$/m;
    ok( $line, "SKILLS.md carries a usage line for tira.$cmd" ) or next;
    $line{$cmd} = $line;
}

# The one genuine difference: bare `dashboard` alone takes --type (its type
# is a variable, not fixed by the command name), and none of the three
# type-specific forms do - dashboard.ticket's own type is already fixed by
# its name. Stripped before comparing, so the comparison is honest about
# what should differ and loud about what should not.
sub flags_of {
    my ($line) = @_;
    my %flags = map { $_ => 1 } $line =~ /(-{1,2}[a-z][a-z-]*)/g;
    delete $flags{'--type'};
    return \%flags;
}

my $baseline = flags_of( $line{dashboard} );
for my $cmd (qw(dashboard.sow dashboard.epic dashboard.ticket)) {
    next if !$line{$cmd};
    my $these = flags_of( $line{$cmd} );
    my @missing = sort grep { !$these->{$_} } keys %{$baseline};
    my @extra   = sort grep { !$baseline->{$_} } keys %{$these};
    is_deeply( \@missing, [],
        "tira.${cmd}'s usage line is missing no flag that bare tira.dashboard's own line carries" );
    is_deeply( \@extra, [],
        "and names no flag bare tira.dashboard's own line does not - the two cannot drift apart silently" );
}

done_testing;

__END__

=head1 NAME

t/1072-four-lines-one-source.t - the four dashboard usage lines cannot drift
apart from each other, only from --type

=head1 DESCRIPTION

TKT-1072. C<dashboard.sow>/C<.epic>/C<.ticket> alias into the exact same
shared C<dashboard> C<Getopt::Long> spec as bare C<dashboard>
(C<lib/Tira/CLI.pm:1858>), so all four genuinely accept the identical flag
set except C<--type> (which only bare C<dashboard> takes - the three
type-specific forms fix their own type by name). C<SKILLS.md> hand-maintains
four separate usage-line strings for this one shared spec, and it drifted
twice in one day (TKT-1068, TKT-1070) - each earlier fix (C<t/1071>) named
the specific flags found missing at the time, not a general guard against
the next one. This compares all four lines' flag sets to each other
directly (stripping only C<--type>), so a flag missed on even one line the
next time the shared spec grows fails here immediately, rather than waiting
for a third live report.

=cut
