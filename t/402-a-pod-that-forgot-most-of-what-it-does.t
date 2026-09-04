#!/usr/bin/env perl
# TKT-558: Tira::DashboardWeb's build_psgi_app POD said it "Accepts render,
# data, move, detail, update, comment_add, comment_update, comment_remove,
# people, attachment_fetch, attachment_add, and attachment_remove coderefs" -
# 12 names, unchanged since long before tasklist/login/policy/checklist
# support existed. The module's own @PROVIDERS table (what build_psgi_app
# actually accepts and requires) had grown to 47 entries with nobody
# reconciling the two - found during a standing documentation-gap hunt.

use strict;
use warnings;

use Test::More;

# t/486 marker: about this file, not its code - this file asserts that THIS
# module's own POD describes what THIS module does, so the POD and the code
# have to come from the same file. A walker over the layer would let one
# module's POD answer for another's providers, which is the fault in reverse.
# TKT-921.
my $module = 'lib/Tira/DashboardWeb.pm';
open my $fh, '<', $module or die "Cannot read $module: $!";
my $body = do { local $/; <$fh> };
close $fh;

my ($providers_block) = $body =~ /my \@PROVIDERS = \((.*?)\n\);/s;
die "Could not find \@PROVIDERS in $module\n" if !defined $providers_block;
my @providers = $providers_block =~ /\[\s*(\w+)\s*=>/g;
ok( scalar(@providers) >= 40, 'found the full @PROVIDERS table (sanity: at least 40 entries)' );

my ($pod) = $body =~ /=head2 build_psgi_app\n\n(.*?)\n\n=head2/s;
die "Could not find build_psgi_app's own POD section in $module\n" if !defined $pod;

my @missing = grep { $pod !~ /\Q$_\E/ } @providers;
is_deeply( \@missing, [], 'every @PROVIDERS name is mentioned in build_psgi_app\'s own POD' )
  or diag( 'missing from POD: ' . join( ', ', @missing ) );

done_testing;

__END__

=head1 NAME

402-a-pod-that-forgot-most-of-what-it-does.t - build_psgi_app's POD names every provider it accepts

=head1 DESCRIPTION

TKT-558: reads lib/Tira/DashboardWeb.pm directly (the same source-scanning
shape t/344 already uses for lib/Tira.pm's own METHODS section), extracts
every name in the module's C<@PROVIDERS> table, and asserts each one is
named somewhere in C<build_psgi_app>'s own POD text - so this section can
no longer silently fall behind new providers the way it did from the
module's earliest version until this ticket.

=cut
