#!/usr/bin/env perl
# TKT-694. TKT-807 added /tasklist and /tasklist/sessions to %POLLED after
# both had been polling on a timer, unexempted, since before %POLLED was
# even written - a session-idle-expiry hole nobody noticed until a real
# report. The specific fix is one line per route; the general shape is the
# one that lasts. This scans every view for a setInterval-driven GET and
# fails the moment one targets a route %POLLED does not name, so the next
# timer-driven poll cannot silently opt itself out the way these two did.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $views_dir = File::Spec->catdir(qw(lib Tira views));
opendir my $dh, $views_dir or die "Cannot read $views_dir: $!";
my @js_files = sort grep { /\.js\z/ } readdir $dh;
closedir $dh;
ok( scalar @js_files, "found view JS files under $views_dir - " . scalar(@js_files) );

# A poll is a named function assigned with `const NAME=()=>fetch("ROUTE"...`
# and later handed to setInterval - the exact shape both /tasklist reads use.
# Anything routed to setInterval that this pattern cannot resolve to a GET
# route is itself worth a human look, so it is asserted resolvable rather
# than silently ignored.
my %polled_by_timer;
for my $file (@js_files) {
    my $path = File::Spec->catfile( $views_dir, $file );
    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    my @timer_fns = $source =~ /\bsetInterval\(\s*([A-Za-z_\$][\w\$]*)\s*,/g;
    for my $fn (@timer_fns) {
        my ($route) = $source =~ /\bconst\s+\Q$fn\E\s*=\s*\(\)\s*=>\s*fetch\(\s*["']([^"'?]*)/;
        ok( defined $route,
            "$file: setInterval target '$fn' resolves to a fetch(...) route this test can check" );
        $polled_by_timer{$route} = "$file:$fn" if defined $route;
    }
}
cmp_ok( scalar keys %polled_by_timer, '>=', 2,
    'found at least the two known timer-driven polls (/tasklist and /tasklist/sessions) - '
      . join( ', ', sort keys %polled_by_timer ) );

# --- every one of them must be named in DashboardWeb's own %POLLED ---------

my $dashboard_web = File::Spec->catfile(qw(lib Tira DashboardWeb.pm));
open my $fh, '<', $dashboard_web or die "Cannot read $dashboard_web: $!";
local $/;
my $dashboard_source = <$fh>;
close $fh;

my ($polled_literal) = $dashboard_source =~ /my\s+%POLLED\s*=\s*\((.*?)\);/s;
ok( defined $polled_literal, 'found %POLLED in DashboardWeb.pm to read its keys from' );
my %polled;
$polled{$1} = 1 while $polled_literal =~ /'([^']+)'\s*=>\s*1/g;

for my $route ( sort keys %polled_by_timer ) {
    ok( $polled{$route},
        "timer-driven route '$route' (from $polled_by_timer{$route}) is exempted in %POLLED, "
          . "or a tab left open all night keeps signing itself back in" );
}

done_testing;

__END__

=head1 NAME

t/479-a-timer-that-could-opt-itself-out.t - every setInterval-driven read
route is named in %POLLED, not just the ones that happen to be today

=head1 DESCRIPTION

TKT-807 added C</tasklist> and C</tasklist/sessions> to
C<Tira::DashboardWeb>'s C<%POLLED> after both had been extending every
signed-in session's expiry on every one- and five-second timer tick since
before C<%POLLED> existed - a session left open overnight never actually
expired. The fix for those two routes was one line each; what was missing
was anything that would catch the *next* one. This file scans every file
under C<lib/Tira/views/> for a C<setInterval>-driven C<fetch(...)> and fails
if the route it polls is not a key in C<%POLLED>, so a new timer-driven read
route cannot silently opt itself out of the idle-expiry exemption the way
these two did. TKT-694.

=cut
