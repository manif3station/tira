#!/usr/bin/env perl
# TKT-1190. Every "Unknown field '...'" die (field selection, diff's field
# scoping, --where clauses) names only the bad field, never a single valid
# one - so fixing a typo means grepping lib/Tira.pm's own @RECORD_FIELDS by
# hand rather than reading it off the error the tool already gave you.
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
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-09-28T09:00:00Z' } );
$tira->create_project( name => 'Unknown Field', dir => $root );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Card' );

# --- --fields / --exclude-fields (_field_projection) ------------------------

eval { $tira->record_show( project => $root, ref => $ticket->{ref}, fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'still names the bad field' );
like( $@, qr/\btitle\b/, 'and now also lists a real field name so a typo can be fixed from the error alone' );

# --- --where (_parse_where) --------------------------------------------------

eval { $tira->record_list( project => $root, where => ['nosuchfield=1'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'where clauses still name the bad field' );
like( $@, qr/\btitle\b/, 'and also list a real field name' );

# --- diff --fields (diff_records's own field scoping) -----------------------

eval { $tira->diff_records( project => $root, snapshot => {}, fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'diff field scoping still names the bad field' );
like( $@, qr/\btitle\b/, 'and also lists a real field name' );

# --- history --field (history_list's own \%HISTORY_FIELD check) -------------
# Same shape, found while fixing the three above - not in the original
# report but the same class of gap, in scope for the same reason.

eval { $tira->history_list( project => $root, ref => $ticket->{ref}, field => 'nosuchfield' ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'history field filtering still names the bad field' );
like( $@, qr/\btitle\b/, 'and also lists a real field name' );

done_testing;

__END__

=head1 NAME

1190-unknown-field-names-what-is-valid.t - an error that could have answered its own question

=head1 DESCRIPTION

Three die sites in lib/Tira.pm (_field_projection, diff_records's field
scoping, _parse_where) already hold the valid-field hash they are checking
a name against - they just never say what is in it. Fixing a typo meant a
source read instead of a second glance at the error.

=cut
