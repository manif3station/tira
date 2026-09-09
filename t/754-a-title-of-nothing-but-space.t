#!/usr/bin/env perl
# create_record refuses an empty title but accepts one made only of spaces,
# storing a card no listing can show a name for.
#
# Measured 2026-08-29 in the perl-test container: create_record with
# title => '   ' returned a ref with a title of length 3, while
# title => '' is refused with "Record title is required".
#
# record_update takes --title too, so a card can be blanked to whitespace
# after creation even if create_record is fixed alone - both callers need
# the same trimmed-emptiness check. TKT-754.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A title of nothing but space', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'TNS', epic_prefix => 'TNE', ticket_prefix => 'TNT',
);

# --- create_record: whitespace-only title is refused like empty ---------------

eval { $tira->create_record( project => $root, type => 'ticket', title => '' ) };
my $empty_error = $@;
like( $empty_error, qr/Record title is required/, 'an empty title is refused (control)' );

eval { $tira->create_record( project => $root, type => 'ticket', title => '   ' ) };
my $whitespace_error = $@;
is( $whitespace_error, $empty_error, 'a whitespace-only title is refused with the exact same message as empty' );

eval { $tira->create_record( project => $root, type => 'ticket', title => "\t\n " ) };
like( $@, qr/Record title is required/, 'other whitespace (tabs, newlines) is refused too' );

# --- create_record: padded-but-real titles are accepted and stored unchanged --

my $card = $tira->create_record( project => $root, type => 'ticket', title => '  real  ' );
is( $card->{title}, '  real  ', 'a title with real content around the padding is stored exactly as typed' );

# --- record_update: whitespace-only title is refused the same way -------------

eval {
    $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude', title => '   ',
    );
};
like( $@, qr/Record title is required/, 'record_update refuses a whitespace-only title too' );

eval {
    $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude', title => '',
    );
};
like( $@, qr/Record title is required/, 'record_update refuses an empty title too (a card cannot be blanked after creation)' );

my $unchanged = $tira->record_show( project => $root, ref => $card->{ref} );
is( $unchanged->{title}, '  real  ', 'the refused updates left the stored title untouched' );

# --- record_update: a padded-but-real title is still accepted -----------------

my $updated = $tira->record_update(
    project => $root, ref => $card->{ref}, author => 'claude', title => '  still real  ',
);
is( $updated->{title}, '  still real  ', 'record_update still accepts and stores a real title unchanged' );

done_testing();

__END__

=head1 NAME

t/754-a-title-of-nothing-but-space.t - a whitespace-only title is refused
the same way an empty one is, at both create_record and record_update

=head1 DESCRIPTION

TKT-754. C<create_record>'s title guard tested only for exact emptiness, so
a title of nothing but spaces passed it and produced a card no listing,
board, or C<tira.next> answer could show a name for. C<record_update> took
C<--title> with no emptiness check at all, so even a fixed C<create_record>
left the same card blankable afterwards. Both callers now share one
predicate that trims before testing for emptiness and refuses the trimmed-
empty case with the existing message - the stored value itself is never
rewritten, so a title with real content and incidental padding is still
kept exactly as typed.

=cut
