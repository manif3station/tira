#!/usr/bin/env perl
# TKT-1045. The work-log section (collapsed and fetched only when asked for)
# is independent of the card-dialog/provider/mutation-route contract
# t/19-dashboard-dialog.t exists to prove, and was lifted out of that file -
# 611 lines before this split, 578 after - as its own concern, the same
# reason TKT-1041/1042/1043/1044 lifted four lib/ modules' own separable
# concerns the same week.
#
# The preamble that builds $live_html is duplicated from t/19 rather than
# shared, since each .t file is its own process and there is no shared-setup
# helper for this dialog fixture yet.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8 encode_utf8);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib', 't/lib';
use GatedApp qw(signed_in);
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'dialog' );
my $tira = Tira->new( clock => sub { '2026-08-06T15:00:00+0100' } );
$tira->create_project( name => 'Dialog project', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'in-progress', label => 'In Progress' );
$tira->person_add( project => $root, id => 'ada', name => 'Ada Lovelace' );
$tira->person_add( project => $root, id => 'bob', name => 'Bob Retired' );
$tira->person_deactivate( project => $root, id => 'bob' );
$tira->create_record( project => $root, type => 'ticket', title => 'Dialog card' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    $ENV{TIRA_AUTHOR} = 'ada';
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, undef, undef, $calls ) =
  browser_cli( 'dashboard.ticket', '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard starts with the dialog providers' );

my $live_html = $calls->[0]{render}->();

# --- the work log, collapsed and fetched only when asked for --------------

# A card has a great deal happen to it. Loading all of it whenever a card is
# opened would bury everything else, so the section renders closed and the
# request only goes out when somebody expands it - which is also the whole
# difference between a card that opens instantly and one that does not.
like( $live_html, qr/const renderWorkLog\s*=/, 'the dialog builds a work log section' );
like( $live_html, qr/card-worklog__toggle/, 'with something to click' );
like( $live_html, qr/let worklogOpen\s*=\s*false/, 'starting closed' );
like( $live_html, qr/body\.hidden\s*=\s*!worklogOpen/, 'and drawn closed unless somebody had it open' );
like( $live_html, qr/if\s*\(!open\s*\|\|\s*loaded\)\s*return/,
    'and it fetches once, on expanding, rather than on every click' );

{
    # The request must be reached from the click handler and from nowhere that
    # runs while a card is merely being opened. If it were anywhere else the
    # section would look lazy while loading eagerly, which is the failure that
    # would never show up by reading the rendered page.
    my ($handler) = $live_html =~ /head\.addEventListener\("click",\s*\(\)\s*=>\s*\{(.*?)\}\);\s*if\s*\(worklogOpen\)/s;
    ok( $handler, 'the toggle has a click handler' );
    like( $handler // '', qr/readLog\(\)/,
        'which is what reads the log, so opening a card asks for nothing' );

    # One place fetches it, so there is one place to be wrong about when.
    my $fetches = () = $live_html =~ m{fetch\(\s*"/worklog\?ref="}g;
    is( $fetches, 1, 'and exactly one place in the page fetches a work log' );
}

# It renders into the sections host, so it scrolls with everything else. Put
# outside it, the section pinned itself to the bottom of the dialog and cut off
# whatever was above - which every assertion in this file passed straight
# through, and only looking at the screen caught.
like( $live_html, qr/const host\s*=\s*sectionsHost/,
    'the work log renders among the sections rather than beside them' );
unlike( $live_html, qr/<div class="card-worklog"><\/div>/,
    'with no host of its own outside the scrolling area' );

done_testing();

__END__

=head1 NAME

t/1045-a-log-that-waits-to-be-asked.t - the work-log section renders closed

=head1 DESCRIPTION

Split out of t/19-dashboard-dialog.t (TKT-1045), the same week
TKT-1041/1042/1043/1044 lifted four lib/ modules' own separable concerns:
the work-log section is a self-contained concern (collapsed by default,
fetched once on expand, rendered into the shared sections host rather than
pinned outside it) independent of the card-dialog/provider/mutation-route
contract the rest of t/19 proves.

=head1 SEE ALSO

L<t/19-dashboard-dialog.t>

=cut

