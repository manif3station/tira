#!/usr/bin/env perl
# bulk_import's own reference lookup reused the generic _record_data
# refusals ("Record reference is required" / "Invalid record reference"),
# which the CLI boundary augments with "- supply it with --ref" for the
# ~40 commands that actually take --ref. An import has no --ref: the
# reference is the key of the change object itself ({"TKT-001": {...}}),
# so a caller whose JSON had an empty or malformed key was told to type a
# flag that does not exist on tira.import. TKT-346.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Imported', dir => $root, members => ['claude'],
    sow_prefix => 'IMS', epic_prefix => 'IME', ticket_prefix => 'IMT',
);

# --- an empty ref key names where the reference belongs, not --ref ---------------

{
    eval { $tira->bulk_import( project => $root, changes => { '' => { title => 'x' } } ) };
    my $message = $@;
    ok( $message, 'an empty import key is refused' );
    like( $message, qr/key/i, 'and it names the key, the actual structure at fault' );
    unlike( $message, qr/--ref/, 'and it does not point at --ref, which tira.import does not take' );
}

# --- a malformed ref key gets the same treatment ----------------------------------

{
    eval { $tira->bulk_import( project => $root, changes => { 'not-a-ref' => { title => 'x' } } ) };
    my $message = $@;
    ok( $message, 'a malformed import key is refused' );
    like( $message, qr/key/i, 'and it names the key too' );
    unlike( $message, qr/--ref/, 'and it does not point at --ref here either' );
}

# --- a genuinely missing card still gets its own, already-clear refusal ----------

{
    eval { $tira->bulk_import( project => $root, changes => { 'ZZZ-999' => { title => 'x' } } ) };
    like( $@, qr/not found/, 'a well-formed but nonexistent ref keeps its own distinct message' );
}
done_testing;

__END__

=head1 NAME

338-an-import-key-that-was-not-a-flag.t - bulk_import names its own key, not --ref

=head1 DESCRIPTION

C<bulk_import>'s reference lookup reused C<_record_data>'s generic
refusals, which the CLI boundary augments with "supply it with C<--ref>"
for the roughly forty commands that take that flag. An import has no
C<--ref> - the reference is the key of the change object itself. An empty
or malformed key now gets its own wording naming the import's own
structure, while a genuinely missing record keeps its distinct, already
clear "not found" message, and every other C<_record_data> caller (the
record commands t/244 already covers) is untouched. TKT-346.

=cut
