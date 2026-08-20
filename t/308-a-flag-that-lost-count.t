#!/usr/bin/env perl
# Passing a single-valued flag twice is accepted, all but the last value is
# discarded, the command exits 0, and nothing says a value was dropped.
# --priority is the reason to fix this rather than note it: a card meant to
# be P5 lands as P1, exit 0, and the output prints the surviving value so it
# reads as success. 94 single-valued (=s/=i/:s) flags against 25 repeatable
# (=s@) ones in lib/Tira/CLI.pm, so the fix has to be general - a check that
# exists and does not reach the path that needs it is the same shape as two
# defects found beside this one. TKT-389.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Flags', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'doc' ],
    sow_prefix => 'FGS', epic_prefix => 'FGE', ticket_prefix => 'FGT',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- a single-valued flag given twice is refused, not silently narrowed ---
my ( $status, $out, $err ) = cli( 'record.create', '--title', 'Card', '--priority', '5', '--priority', '1' );
isnt( $status, 0, 'a single-valued flag given twice is refused' );
like( $err, qr/--priority/, 'naming the flag' );
like( $err, qr/5/,          'and the first value' );
like( $err, qr/1/,          'and the competing second value' );

# --- nothing was created - the refusal happens before any write -----------
my $listed = $tira->record_list( project => $root, type => 'ticket' );
is( scalar @{$listed}, 0, 'the card was never created - the refusal happened before any write' );

# --- the harmless end of the same mechanism is refused too -----------------
( $status, $out, $err ) = cli( 'record.create', '--title', 'FIRST', '--title', 'SECOND' );
isnt( $status, 0, '--title given twice is refused, not silently narrowed to the last value' );
like( $err, qr/--title/, 'naming --title' );

# --- a genuinely repeatable option is entirely unaffected ------------------
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Labelled' );
( $status, $out, $err ) = cli( 'record.update', '--ref', $card->{ref}, '--label', 'A', '--label', 'B' );
is( $status, 0, 'a repeatable option given twice still succeeds' ) or diag($err);
my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
is_deeply( [ sort @{ $shown->{labels} } ], [ 'A', 'B' ], 'and both values survive, in order' );

# --- a single-valued flag given once, as normal, is entirely unaffected ---
( $status, $out, $err ) = cli( 'record.create', '--title', 'Once' );
is( $status, 0, 'a single-valued flag given once still works exactly as before' ) or diag($err);

done_testing;

__END__

=head1 NAME

308-a-flag-that-lost-count.t - a single-valued option given twice is refused, not silently narrowed

=head1 DESCRIPTION

Covers TKT-389: any option spec that takes a value and is not itself
repeatable (no C<@> in its Getopt::Long spec) now refuses a command outright
if the same flag is given more than once, naming the flag and both competing
values, rather than silently keeping only the last one and exiting 0. The
guard is general, applied once over the whole option-spec table rather than
duplicated per flag. Repeatable options (C<=s@> and friends) are unaffected.

=cut
