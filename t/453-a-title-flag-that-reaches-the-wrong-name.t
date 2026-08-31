#!/usr/bin/env perl
# TKT-779. lib/Tira/CLI.pm's browser-serve dispatch (line ~737) passes
# 'with_title => $option{with_title}' to Tira::CLI::Serve::_serve_browser -
# but $option{with_title} is never assigned anywhere in the file, so it is
# always undef regardless of whether --title was given. The correct,
# already-populated key is $option{title}, set by Getopt::Long's 'title:s'
# spec from --title - a DIFFERENT code path (the live-render closure a few
# lines earlier) already reads it correctly as 'with_title => defined
# $option{title}'. Result: 'd2 tira.dashboard -o browser --title' never
# showed card titles in the served dashboard, only refs, no matter what was
# typed.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Serve;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-31T00:00:00+0100'} );
$tira->create_project( name => 'Titled', dir => $root );

sub with_title_for {
    my (@argv) = @_;
    my %received;
    local $ENV{TIRA_HOME} = $root;
    Tira::CLI->run(
        command => 'dashboard', argv => \@argv, tira => $tira,
        browser_server => sub { %received = @_; return 1 },
    );
    return $received{with_title};
}

ok( with_title_for( '-o', 'browser', '--title' ),
    "--title reaches the browser serve dispatch's with_title argument as true - "
      . 'if this is false, line 737 is still reading the wrong option key' );

ok( !with_title_for( '-o', 'browser' ),
    'omitting --title leaves with_title false, unchanged from before this fix' );

done_testing;

__END__

=head1 NAME

t/453-a-title-flag-that-reaches-the-wrong-name.t - --title actually
reaches the browser-serve dispatch's with_title argument

=head1 DESCRIPTION

The browser-serve dispatch in C<Tira::CLI> passed
C<with_title =E<gt> $option{with_title}> to the browser server - a key
never assigned anywhere in the file, always undef. The correct key,
already populated by C<--title>'s own C<Getopt::Long> spec and already
read correctly by a sibling code path a few lines earlier, is
C<$option{title}>. Fixed to read C<defined $option{title}> in both
places. TKT-779.

=cut
