#!/usr/bin/env perl
# attachment_list is entirely scoped to one --ref: it reads that one
# record's own attachments and nothing else. Attachments are
# content-addressed and deliberately deduplicated, so two cards sharing a
# file is ordinary rather than exceptional - but nothing on the board could
# answer "which OTHER records reference this sha" without fetching every
# record and grepping its attachments array by hand.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $now  = '2026-09-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->create_project( name => 'A question nothing could answer', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );

$tira->create_record( project => $root, type => 'ticket', title => 'First' );
$tira->create_record( project => $root, type => 'ticket', title => 'Second' );
$tira->create_record( project => $root, type => 'ticket', title => 'Third' );

# --- a sha shared by two cards -----------------------------------------------

my $shared = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', filename => 'shared.txt', content => "same bytes\n",
);
$tira->attachment_add_content(
    project => $root, ref => 'TKT-002', filename => 'copy.txt', content => "same bytes\n",
);

can_ok( 'Tira', 'attachment_where' );

my $found = $tira->attachment_where( project => $root, sha => $shared->{sha} );
is( ref $found, 'ARRAY', 'attachment_where returns an array' );
is( scalar @{$found}, 2, 'both cards sharing the sha are listed' );
my %refs = map { $_->{ref} => 1 } @{$found};
ok( $refs{'TKT-001'} && $refs{'TKT-002'}, 'both TKT-001 and TKT-002 are named' );

# --- a sha referenced by only one card ---------------------------------------

my $lone = $tira->attachment_add_content(
    project => $root, ref => 'TKT-003', filename => 'lone.txt', content => "only here\n",
);
my $lone_found = $tira->attachment_where( project => $root, sha => $lone->{sha} );
is( scalar @{$lone_found}, 1, 'a sha only one card references lists just that one' );
is( $lone_found->[0]{ref}, 'TKT-003', 'and names the right card' );

# --- a sha nothing references returns an empty list, not an error -----------

my $nothing = $tira->attachment_where( project => $root, sha => '0' x 64 );
is_deeply( $nothing, [], 'a sha nothing references returns an empty list' );

# --- --extension narrows the search when given -------------------------------

my $narrowed = $tira->attachment_where( project => $root, sha => $shared->{sha}, extension => 'txt' );
is( scalar @{$narrowed}, 2, '--extension matching the real extension still finds both' );
my $wrong_ext = $tira->attachment_where( project => $root, sha => $shared->{sha}, extension => 'md' );
is_deeply( $wrong_ext, [], 'a mismatched --extension narrows to nothing' );

# --- --sha is required --------------------------------------------------------

eval { $tira->attachment_where( project => $root ) };
like( $@, qr/sha is required/i, '--sha is required' );

done_testing();

__END__

=head1 NAME

t/766-a-question-nothing-could-answer.t - attachment_where answers which
other records reference a given sha

=head1 DESCRIPTION

TKT-766. C<attachment_list> only ever resolves through one record's own
attachments via C<--ref>; nothing walked the board to find every OTHER
record referencing a given sha, even though attachments are deliberately
content-addressed and deduplicated so sharing one is ordinary. C<attachment_where>
walks every record (C<record_list> with C<include_discard>) and returns
every reference to the given sha, optionally narrowed by C<--extension>. A
sha nothing references is a valid empty-list answer, not a refusal.

=cut
