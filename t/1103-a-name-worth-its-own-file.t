#!/usr/bin/env perl

# TKT-1098. Michael's live ask (2026-09-15, msg #8320, same message that
# asked why lib/Tira.pm was still >15k lines - see TKT-1092): move
# lib/Tira.pm's own POD block out into a sibling lib/Tira.pod, the standard
# CPAN convention perldoc/pod2* tools already look for when a same-basename
# .pod file exists beside a .pm one. Before this, every line of Tira's
# documentation lived inline at the end of the module, counted toward the
# same 500/1000-line caps TKT-1092 is trying to bring the file under, for no
# reason connected to the code itself.
#
# WRITTEN RED: before this ticket, lib/Tira.pod does not exist at all, and
# lib/Tira.pm's own POD block is still there.

use strict;
use warnings;

use FindBin;
use File::Spec;
use Test::More;

my $lib  = File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib' );
my $pm   = File::Spec->catfile( $lib, 'Tira.pm' );
my $pod  = File::Spec->catfile( $lib, 'Tira.pod' );

ok( -f $pod, 'lib/Tira.pod exists as a sibling of lib/Tira.pm' )
  or diag "not found at $pod";

open my $pm_fh, '<', $pm or die "Cannot open '$pm': $!";
my @pm_lines = <$pm_fh>;
close $pm_fh;

my @pm_pod_markers = grep { /^=\w/ } @pm_lines;
is( scalar(@pm_pod_markers), 0,
    'lib/Tira.pm carries no POD markers of its own any more - it all moved '
      . 'to lib/Tira.pod' )
  or diag "found: @pm_pod_markers";

my ($last_code_line) = grep { /\S/ } reverse @pm_lines;
like( $last_code_line, qr/^\s*1;\s*$/,
    "lib/Tira.pm's last non-blank line is a bare '1;' - no orphaned "
      . '__END__ or POD marker trailing after it' );

SKIP: {
    skip 'lib/Tira.pod does not exist yet', 2 if !-f $pod;

    open my $pod_fh, '<', $pod or die "Cannot open '$pod': $!";
    my @pod_lines = <$pod_fh>;
    close $pod_fh;

    like( $pod_lines[0], qr/^=head1 NAME/,
        'lib/Tira.pod starts with the same =head1 NAME the module used to '
          . 'carry inline' );
    like( $pod_lines[-1], qr/^=cut/,
        "lib/Tira.pod ends with the module's own closing =cut" );
}

done_testing;

__END__

=head1 NAME

1103-a-name-worth-its-own-file.t - lib/Tira.pm's POD lives in lib/Tira.pod

=head1 WHY

TKT-1098, from Michael's own live ask: lib/Tira.pm carried its whole POD
block inline, counting toward the very line-count caps TKT-1092 is trying
to bring the file under for no reason connected to the code. The standard
CPAN convention - a same-basename .pod file beside the .pm - is what
perldoc and pod2* tools already look for.

=head1 WHAT IS ASSERTED

lib/Tira.pod exists, lib/Tira.pm carries no POD markers of its own any
more, lib/Tira.pm's last non-blank line is a bare "1;" with nothing
orphaned after it, and lib/Tira.pod's own content starts and ends exactly
where the module's POD block used to.

=head1 WHAT IS NOT ASSERTED

Anything about the POD's own wording or structure - this is a location
move only, verified elsewhere (this ticket's own verify gate) by a direct
diff against the pre-move content.

=cut
