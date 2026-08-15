#!/usr/bin/env perl
# A command's documented signature lists the options it accepts.
#
# Found by the hourly hunt, probing for the shape of TKT-182: an option a
# command is validated as allowed to carry and then quietly drops. That probe
# came back clean - every option the ownership guards permit is honoured by the
# command that permits it. What it found instead is the same drift running the
# other way.
#
# The guard in Tira::CLI says, in its own words, that reminder settings belong
# to project.update, project.new and onboard. SKILLS.md documents
# --notify-after, --collector, --agent, --session and --heartbeat against
# project.update alone, and the documented signature for project.new lists none
# of them.
#
# All five work on project.new. Measured rather than argued: creating a project
# with --agent claude --session sess --collector coll --heartbeat 45 stores all
# four, project.show reads them back, and they are in project.yml.
#
# Nothing is broken. What is wrong is that a real capability is unfindable: an
# agent reading the signature concludes project.new cannot carry them and writes
# a two-step onboarding where one call would do - against a command whose entire
# reason for existing is doing the lot in a single call.
#
# The two lists are copies of one decision, and neither is wrong about the code.
# They are wrong about each other, which is why this checks them against each
# other rather than either against a third list somebody would have to maintain.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# --- the capability is real -------------------------------------------------------
#
# First, because everything below is about documenting it, and documenting
# something that does not work would be worse than saying nothing.

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'made' );

$tira->project_new(
    name => 'Made In One Call', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'MOS', epic_prefix => 'MOE', ticket_prefix => 'MOT',
    agent => 'claude', session => 'sess-at-new',
    collector => 'coll-at-new', heartbeat => 45, notify_after => 30,
);

my $made = $tira->project_show( project => $root );
is( $made->{agent},        'claude',      'project.new carries the agent' );
is( $made->{session},      'sess-at-new', 'and the session' );
is( $made->{collector},    'coll-at-new', 'and the collector' );
is( $made->{heartbeat},    45,            'and the heartbeat' );
is( $made->{notify_after}, 30,            'and notify-after' );

# --- and the guard says so ----------------------------------------------------------

my $cli = do {
    open my $fh, '<:raw', 'lib/Tira/CLI.pm' or die $!;
    local $/;
    <$fh>;
};

my ($reminder) = $cli =~ /Reminder settings belong to ([^\\"]+)/;
ok( $reminder, 'the guard names the commands reminder settings belong to' );
like( $reminder, qr/project\.new/, 'and project.new is one of them' );

# --- so the documented signature says so too ------------------------------------------
#
# The point of the card. Every option the guard permits on project.new has to
# appear in what somebody reads before typing it.

my $skills = do {
    open my $fh, '<:raw', 'SKILLS.md' or die $!;
    local $/;
    <$fh>;
};

my ($signature) = $skills =~ /^(- `tira\.project\.new .*?`)/ms;
ok( $signature, 'SKILLS.md carries a signature for project.new' );

for my $option (qw(notify-after collector agent session heartbeat)) {
    like( $signature, qr/--\Q$option\E/,
        "and it lists --$option, which project.new accepts and honours" );
}

# --- the two lists are checked against each other -------------------------------------
#
# Not against a third list somebody would have to keep up to date. The guard is
# the code's own statement of who may carry these, so it is the thing the
# documentation has to agree with, and a command added to the guard tomorrow
# fails this until it is written down.

{
    my @permitted = $reminder =~ /((?:project|onboard)[a-z.]*)/g;
    ok( scalar @permitted >= 2, 'the guard permits more than one command' );

    for my $command (@permitted) {
        next if $command eq 'onboard';    # asks its questions rather than taking options
        # However the document writes it. project.new's signature is a bullet
        # in backticks and project.update's is two lines in a fenced block, so
        # matching one shape found one of them and silently passed the other.
        my ($shown) = $skills =~ /tira\.\Q$command\E\b(.{0,320})/s;
        $shown //= '';
        # ${command}'s rather than $command's: in a double-quoted string the
        # apostrophe is Perl's old package separator, so "$command's" reads as
        # $command::s and interpolates as nothing. The first run of this file
        # printed two assertions named " signature lists ..." with the command
        # missing, which is a test that cannot tell you which case failed.
        like( $shown, qr/--collector/,
            "${command}'s signature lists the settings the guard lets it carry" );
    }
}

# --- while nothing about the behaviour moved --------------------------------------------

{
    my $bare = File::Spec->catdir( $tmp, 'bare' );
    $tira->project_new(
        name => 'Nothing Set', dir => $bare, members => ['michael'],
        columns => ['backlog, done'],
        sow_prefix => 'NSS', epic_prefix => 'NSE', ticket_prefix => 'NST',
    );
    my $plain = $tira->project_show( project => $bare );
    is( $plain->{agent},        undef, 'a project created without them has no agent' );
    is( $plain->{notify_after}, undef, 'and no notify-after, exactly as before' );
}

done_testing;

__END__

=head1 NAME

178-an-option-nobody-was-told-about.t - a signature lists the options its command takes

=head1 DESCRIPTION

C<Tira::CLI>'s ownership guard says reminder settings belong to
C<project.update>, C<project.new> and C<onboard>. C<SKILLS.md> documented them
against C<project.update> alone, and C<project.new>'s signature listed none of
them - though all five work there, which this file measures before asserting
anything about the documentation.

The two lists are copies of one decision and neither was wrong about the code,
so they are checked against each other rather than against a third list somebody
would have to maintain. A command added to the guard fails this until it is
written down.

=cut
