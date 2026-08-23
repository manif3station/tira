#!/usr/bin/env perl
# "This board has never been policed, so nothing has been checked" ships in
# production, is provably reachable, and had zero assertions anywhere in the
# suite - hidden by a ternary Devel::Cover's statement coverage marks
# covered the moment EITHER branch runs, and this project's gate checks
# statement and subroutine coverage only, not branch coverage. The true
# branch ("No violations outstanding, as of the pass at ...") is tested in
# t/273; this proves the false one. TKT-403.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Unpoliced', dir => $root, members => ['claude'], agent => 'claude',
    columns => ['backlog, implement, done'],
    sow_prefix => 'UPS', epic_prefix => 'UPE', ticket_prefix => 'UPT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        $status = Tira::CLI->run( command => 'police.outstanding', tira => $tira,
            argv => [ '--store', $store, @argv ] );
    }
    return ( $status, $out . $err );
}

# --- the untested branch: no policy declared, so no pass was ever taken -----

{
    my ( $status, $said ) = run();
    is( $status, 0, 'a never-policed board still exits 0' );
    like( $said, qr/this board has never been policed, so nothing has been checked/i,
        'and says exactly that - the false branch of the ternary, proven' );
    unlike( $said, qr/no violations outstanding/i,
        'not the true branch\'s sentence, which is what a text-blind assertion would miss' );
}

# --- the existing, already-tested branch stays exactly as it was ------------

{
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    $tira->police_pass( project => $root, store => $store );
    my ( $status, $said ) = run();
    is( $status, 0, 'a policed, clean board still exits 0' );
    like( $said, qr/no violations outstanding, as of the pass at/i,
        'and the existing message is unchanged' );
    unlike( $said, qr/never been policed/i, 'not the never-policed sentence' );
}

done_testing;

__END__

=head1 NAME

359-the-branch-nobody-ran.t - the never-policed ternary branch, proven

=head1 DESCRIPTION

C<tira.police.outstanding>'s "this board has never been policed" message
was reachable - a board with no policy declared never writes a last-pass
timestamp, so C<police_outstanding_taken_at> returns undef - but had no
assertion anywhere in the suite, hidden from statement coverage by a
ternary whose true branch (tested in t/273) was enough to mark the whole
line covered. This proves the false branch's exact sentence, and that the
existing, already-tested branch is unaffected.

=cut
