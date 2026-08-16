#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $now = '2026-08-06T10:00:00+0100';
my $tira = Tira->new( clock => sub { $now } );
my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'comments' );
$tira->create_project( name => 'Comment removal', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->create_record( project => $root, type => 'ticket', title => 'Card' );

my $pound = chr 0xA3;
$tira->comment_add( project => $root, ref => 'TKT-001', author => 'ada', text => 'first' );
$tira->comment_add( project => $root, ref => 'TKT-001', author => 'ada', text => "cost ${pound}523" );

{
    $now = '2026-08-06T10:05:00+0100';
    my $removed = $tira->comment_remove( project => $root, ref => 'TKT-001', comment => 'CMT-001' );
    is( $removed->{id}, 'CMT-001', 'comment_remove returns the removed comment' );
    is( $removed->{body}, 'first', 'the removed comment keeps its body in the response' );

    my $comments = $tira->comment_list( project => $root, ref => 'TKT-001' );
    is( scalar @{$comments}, 1, 'exactly one comment remains after removal' );
    is( $comments->[0]{id}, 'CMT-002', 'the surviving comment keeps its original id' );
    is( $comments->[0]{body}, "cost ${pound}523", 'the surviving UTF-8 body is untouched' );

    my $record = $tira->record_show( project => $root, ref => 'TKT-001' );
    is( $record->{last_updated}, '2026-08-06T10:05:00+0100', 'removal updates the record last_updated' );
}

{
    my $error = eval { $tira->comment_remove( project => $root, ref => 'TKT-001', comment => 'CMT-009' ); 1 } ? '' : $@;
    like( $error, qr/Comment 'CMT-009' not found/, 'removing an unknown comment dies clearly' );
    my $comments = $tira->comment_list( project => $root, ref => 'TKT-001' );
    is( scalar @{$comments}, 1, 'a failed removal changes nothing' );
}

{
    my $next = $tira->comment_add( project => $root, ref => 'TKT-001', author => 'ada', text => 'after removal' );
    is( $next->{id}, 'CMT-003', 'comment ids keep increasing after a removal' );
}

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $command = shift @argv;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

{
    my ( $status, $out, $err ) =
      run_cli( 'comment.remove', '--ref', 'TKT-001', '--comment', 'CMT-003', '-o', 'json' );
    is( $status, 0, 'tira.comment.remove succeeds through the CLI' );
    is( $err, '', 'comment removal has no stderr' );
    is( decode_json($out)->{id}, 'CMT-003', 'the CLI reports the removed comment' );
    my $comments = $tira->comment_list( project => $root, ref => 'TKT-001' );
    is( scalar @{$comments}, 1, 'the CLI removal persists' );
}

{
    my ( $status, $out, $err ) =
      run_cli( 'comment.remove', '--ref', 'TKT-001', '--comment', 'CMT-042' );
    is( $status, 2, 'removing a missing comment through the CLI fails' );
    like( $err, qr/Comment 'CMT-042' not found/, 'the CLI failure is actionable' );
}

done_testing;

__END__

=head1 NAME

18-comment-remove.t - comment deletion engine and CLI contract

=head1 DESCRIPTION

Guards Tira's comment_remove engine behavior (targeted removal, clear unknown-id
failure, last_updated bump, monotonic ids) and the tira.comment.remove CLI verb.

=cut
