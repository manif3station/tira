#!/usr/bin/env perl
# TKT-353. comment.add is the only one of four write/read pairs where the
# write flag and the stored field disagree: gate --details reads back as
# details, evidence --summary as summary, checklist --item as item, and
# comment --text reads back as body. Reported live: a read-back check doing
# c.get('text') on the stored record returned None silently, indistinguishable
# from a comment that had not landed.
#
# Not fixed by renaming the stored field - nothing can migrate it, and a
# rename would be worse than the confusion. 'text' rides alongside 'body' on
# the way OUT instead: comment_add, comment_update and comment_list all
# expose both keys with the same value, built fresh at each read boundary
# rather than by mutating the comment object that gets persisted - the exact
# persistence-leak TKT-407 already found once elsewhere in this project.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Agreed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'AGS', epic_prefix => 'AGE', ticket_prefix => 'AGT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card with a comment' );

# --- comment_add's own return exposes both names ----------------------------

my $added = $tira->comment_add( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', text => 'the text I wrote' );
is( $added->{body}, 'the text I wrote', 'the stored name still answers' );
is( $added->{text}, 'the text I wrote', 'and the write-side name now answers too, the same value' );

# --- and so does the read-back the reporter actually did --------------------

my $listed = $tira->comment_list( project => $root, type => 'ticket', ref => $card->{ref} );
is( $listed->[0]{text}, 'the text I wrote',
    "a caller reaching for the obvious name after a write finds it, rather than silent undef" );
is( $listed->[0]{body}, 'the text I wrote', 'without losing the name every other reader already expects' );

# --- comment_update's own return agrees too ----------------------------------

my $updated = $tira->comment_update( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', comment => $added->{id}, text => 'edited' );
is( $updated->{text}, 'edited', 'an edit answers under the write-side name too' );
is( $updated->{body}, 'edited', 'and the stored name, in step with it' );

# --- and none of this leaked onto what actually gets persisted --------------

my $raw = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
ok( !exists $raw->{comments}[0]{text},
    'the duplicate is built at each read, not written onto the comment object itself' );

# --- --fields text works the way --fields body already did ------------------

my $selected = $tira->comment_list( project => $root, type => 'ticket', ref => $card->{ref},
    fields => ['text'] );
is_deeply( [ sort keys %{ $selected->[0] } ], [ 'id', 'text' ],
    '--fields text selects the alias the same way --fields body selects the original' );

done_testing;

__END__

=head1 NAME

371-a-name-that-agreed-with-itself.t - comment.add's --text reads back as text too

=head1 DESCRIPTION

comment.add was the only one of four write/read field pairs where the flag
and the stored name disagreed - gate, evidence and checklist all match,
comment alone read back as C<body> for a C<--text> write. C<comment_add>,
C<comment_update> and C<comment_list> now all expose C<text> alongside
C<body>, the same value, built fresh at each read boundary rather than
mutated onto the comment object itself - so nothing leaks onto what
C<_replace_record> actually persists to disk.

=cut
