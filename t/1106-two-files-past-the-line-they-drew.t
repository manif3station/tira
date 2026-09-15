#!/usr/bin/env perl

# TKT-1103. lib/Tira/CLI/Police.pm and lib/Tira/CLI/Serve.pm both crossed
# Michael's 1000-line cap (TKT-1092) - Serve.pm when TKT-1100 added the
# TIRA_POLICY_BRIDGE_HOLDER marker, Police.pm the same ticket's own
# singleton generalization plus its accumulated growth since TKT-1043's
# lift. t/524's own exemption list already named both, but "exempt with a
# card watching it" is not the same as "fixed" - this test asserts the
# actual state the exemption is there to end.
#
# WRITTEN RED: before this ticket, neither lib/Tira/CLI/Police.pod nor
# lib/Tira/CLI/Serve.pod exists, and both .pm files are still over 1000
# lines with their POD still inline.

use strict;
use warnings;

use FindBin;
use File::Spec;
use Test::More;

my $lib = File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib', 'Tira', 'CLI' );

for my $name (qw(Police Serve)) {
    my $pm  = File::Spec->catfile( $lib, "$name.pm" );
    my $pod = File::Spec->catfile( $lib, "$name.pod" );

    ok( -f $pod, "lib/Tira/CLI/$name.pod exists as a sibling of $name.pm" )
      or diag "not found at $pod";

    open my $pm_fh, '<', $pm or die "Cannot open '$pm': $!";
    my @pm_lines = <$pm_fh>;
    close $pm_fh;

    is( scalar(@pm_lines), grep( {1} @pm_lines ), "sanity: $name.pm read" );
    ok( scalar(@pm_lines) <= 1000,
        "lib/Tira/CLI/$name.pm is at or under Michael's 1000-line cap (TKT-1092) - "
          . scalar(@pm_lines) . ' lines' );

    my @pm_pod_markers = grep { /^=\w/ } @pm_lines;
    is( scalar(@pm_pod_markers), 0,
        "lib/Tira/CLI/$name.pm carries no POD markers of its own any more - "
          . "it all moved to $name.pod" )
      or diag "found: @pm_pod_markers";

    my ($last_code_line) = grep { /\S/ } reverse @pm_lines;
    like( $last_code_line, qr/^\s*1;\s*$/,
        "lib/Tira/CLI/$name.pm's last non-blank line is a bare '1;'" );

  SKIP: {
        skip "lib/Tira/CLI/$name.pod does not exist yet", 2 if !-f $pod;

        open my $pod_fh, '<', $pod or die "Cannot open '$pod': $!";
        my @pod_lines = <$pod_fh>;
        close $pod_fh;

        like( $pod_lines[0], qr/^=head1 NAME/,
            "lib/Tira/CLI/$name.pod starts with =head1 NAME" );
        like( $pod_lines[-1], qr/^=cut/,
            "lib/Tira/CLI/$name.pod ends with =cut" );
    }
}

done_testing;

__END__

=head1 NAME

1106-two-files-past-the-line-they-drew.t - Police.pm and Serve.pm both under the cap, POD moved out

=head1 WHY

TKT-1103: lib/Tira/CLI/Police.pm and lib/Tira/CLI/Serve.pm both crossed
Michael's 1000-line cap (TKT-1092), grown there by TKT-1100's own singleton
work. t/524's exemption list named both with a card reference, which is a
promise a card is watching, not proof the file is fixed - this test is
that proof.

=head1 WHAT IS ASSERTED

For each of Police.pm and Serve.pm: a sibling .pod file exists, the .pm
itself carries no POD markers and ends in a bare "1;", the .pod starts
with "=head1 NAME" and ends with "=cut", and the .pm's own line count is
at or under 1000.

=head1 WHAT IS NOT ASSERTED

Anything about how Police.pm's remaining code is organized beyond the
line-count cap itself - TKT-1103's own checklist tracks whether a further
concern gets lifted into its own module, separate from this test's own
narrower claim.

=cut
