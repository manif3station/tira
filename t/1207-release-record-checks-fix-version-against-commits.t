#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
require Tira::CLI::Release;

# TKT-1207. d2 tira.release.record --fix-version 5.245 on TKT-1194 succeeded
# although every commit that mentions TKT-1194 carries VERSION=5.240 in .env.
# release_record validated only that the value was version-shaped, so a
# wrong-but-real version went in and was found only by mapping commits to
# versions by hand during a ten-card batch release.
#
# What is held here: a --fix-version that differs from the VERSION in the
# ref's own (oldest) commit is refused, naming the ref, both versions and the
# commit, and records nothing for that card; the matching version, a ref with
# no commit, 'none', an 'n/a' value, a board outside a git repository and
# --force-version all record as before; and in a batch a refused card is
# reported in refused[] while the others are recorded.

my $git = qx(git --version 2>/dev/null);
plan skip_all => 'git is not available' if $? != 0;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-10-02T02:30:00Z' } );
$tira->project_new(
    name => 'Rel', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);

my %card = map { $_ => $tira->create_record( project => $root, type => 'ticket', title => "Card $_", priority => 3 )->{ref} } qw(one two three);

sub git {
    my (@argv) = @_;
    my $out = qx(git -C "$root" @argv 2>&1);
    die "git @argv failed: $out" if $? != 0;
    return $out;
}

sub commit_version {
    my ( $version, $subject ) = @_;
    open my $fh, '>', File::Spec->catfile( $root, '.env' ) or die $!;
    # The subject rides along as a comment so two commits at the same version
    # are still two different files, and git has something to commit.
    print {$fh} "VERSION=$version\n# $subject\n";
    close $fh;
    git('add .env');
    git( "-c user.name=t -c user.email=t\@example.com commit -q -m '$subject'" );
    return substr( git('rev-parse HEAD'), 0, 7 );
}

git('init -q');
my $first  = commit_version( '1.01', "$card{one}: first fix" );
my $second = commit_version( '1.02', "$card{two}: second fix" );

sub facts_for {
    my (@refs) = @_;
    return Tira::CLI::Release::commit_versions( $tira, { project => $root, refs => [@refs] } );
}

sub record {
    my ( $ref, $version, %extra ) = @_;
    return eval {
        $tira->release_record(
            project => $root, ref => $ref, gate => q(gate-run), result => q(pass),
            details => q(ran), evidence => q(passed), fix_version => $version, author => q(claude),
            commit_versions => facts_for($ref), %extra,
        );
    };
}

sub fix_version_of {
    my ($ref) = @_;
    return $tira->record_show( project => $root, ref => $ref )->{fix_version};
}

sub gates_of {
    my ($ref) = @_;
    return scalar @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };
}

# --- a version that disagrees with the ref's own commit is refused -----------

{
    my $got = record( $card{one}, '1.02' );
    is( $got, undef, 'a --fix-version that differs from the ref\'s own commit is refused' );
    like( $@, qr/\Q$card{one}\E/, 'the refusal names the card' );
    like( $@, qr/1\.02/, 'and the version it was given' );
    like( $@, qr/1\.01/, 'and the version its commit carries' );
    like( $@, qr/\Q$first\E/, 'and the commit' );
    like( $@, qr/--force-version/, 'and names the override' );
    ok( !defined fix_version_of( $card{one} ), 'nothing was recorded for the refused card: no fix_version' );
    is( gates_of( $card{one} ), 0, 'no gate entry either' );
}

# --- the matching version records ---------------------------------------------

{
    my $got = record( $card{two}, '1.02' );
    ok( $got, 'the version its own commit carries records' );
    is( fix_version_of( $card{two} ), '1.02', 'and is on the card' );
}

# --- everything that must stay silent ----------------------------------------

{
    my $got = record( $card{three}, '9.99' );
    ok( $got, 'a ref no commit names records any version, as before (a review card has none)' );
    is( fix_version_of( $card{three} ), '9.99', 'and it is on the card' );
}

for my $value ( 'none', 'n/a - work outside a release' ) {
    my $ref = $tira->create_record( project => $root, type => 'ticket', title => "Card $value", priority => 3 )->{ref};

    # A commit that does carry a different version, so it is the value being
    # exempt - not the card having no commit - that lets this record.
    commit_version( '1.06', "$ref: has a commit at 1.06" );
    my $got = record( $ref, $value );
    ok( $got, "'$value' is not a version number and is never compared, even for a card with a commit" );
}

{
    my $got = record( $card{one}, '1.02', force_version => 1 );
    ok( $got, '--force-version records the mismatching version anyway' );
    is( fix_version_of( $card{one} ), '1.02', 'and it is on the card' );
}

# --- the subject match is exact: one ref is not a prefix of another ---------

{
    my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Prefix', priority => 3 )->{ref};
    ( my $longer = $other ) =~ s/(\d+)\z/${1}0/;
    my $sha = commit_version( '1.03', "$longer: not this card" );
    my $got = record( $other, '1.03' );
    ok( $got, "$other is not matched by a commit whose subject begins $longer: it has no commit of its own" );
    ok( $sha, 'the lookalike commit exists' );
}

# --- a batch: the refused card is reported, the others are recorded ----------

{
    my $a = $tira->create_record( project => $root, type => 'ticket', title => 'Batch a', priority => 3 )->{ref};
    my $b = $tira->create_record( project => $root, type => 'ticket', title => 'Batch b', priority => 3 )->{ref};
    commit_version( '1.04', "$a: batch a" );
    commit_version( '1.05', "$b: batch b" );
    my $got = eval {
        $tira->release_record(
            project => $root, refs => [ $a, $b ], gate => 'gate-run', result => 'pass',
            details => 'ran', evidence => 'passed', fix_version => '1.05', author => 'claude',
            commit_versions => facts_for( $a, $b ),
        );
    };
    ok( $got, 'a batch with one mismatching card still answers' );
    is( scalar @{ $got->{recorded} // [] }, 1, 'one card was recorded' );
    is( scalar @{ $got->{refused} // [] }, 1, 'one card was refused' );
    is( $got->{refused}[0]{ref}, $a, 'the refused one is the card whose commit carries 1.04' );
    like( $got->{refused}[0]{error}, qr/1\.04/, 'naming the version its commit carries' );
    ok( !defined fix_version_of($a), 'the refused card has no fix_version' );
    is( fix_version_of($b), '1.05', 'the other card recorded' );
}

# --- a board that is not in a git repository is never checked -----------------

{
    my $plain = File::Spec->catdir( $tmp, 'plain' );
    $tira->project_new(
        name => 'Plain', dir => $plain, members => ['claude'],
        columns => ['backlog, done'], sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
    );
    my $ref = $tira->create_record( project => $plain, type => 'ticket', title => 'No repo', priority => 3 )->{ref};
    my $got = eval {
        $tira->release_record(
            project => $plain, ref => $ref, gate => 'gate-run', result => 'pass',
            details => 'ran', evidence => 'passed', fix_version => '2.00', author => 'claude',
        );
    };
    ok( $got, 'outside a git repository there is nothing to compare against, so it records' );
}

# --- the engine looks at no repository: it compares the fact it is handed ----

{
    my $ref = $tira->create_record( project => $root, type => 'ticket', title => 'Pure engine', priority => 3 )->{ref};
    my %call = (
        project => $root, ref => $ref, gate => 'gate-run', result => 'pass',
        details => 'ran', evidence => 'passed', fix_version => '3.01', author => 'claude',
    );

    my $got = eval { $tira->release_record( %call, commit_versions => { $ref => { commit => 'abcdef1234567', version => '3.00' } } ) };
    is( $got, undef, 'given a fact that disagrees, the engine refuses with no repository involved' );
    like( $@, qr/3\.01.*\Q$ref\E.*abcdef1.*3\.00/s, 'naming the version given, the card, the short commit and the version it carries' );

    $got = eval { $tira->release_record( %call, commit_versions => { $ref => { commit => 'abcdef1234567', version => '3.01' } } ) };
    ok( $got, 'given a fact that agrees, it records' );
}

{
    my $ref = $tira->create_record( project => $root, type => 'ticket', title => 'No fact', priority => 3 )->{ref};
    my $got = eval {
        $tira->release_record(
            project => $root, ref => $ref, gate => 'gate-run', result => 'pass',
            details => 'ran', evidence => 'passed', fix_version => '3.02', author => 'claude',
            commit_versions => { 'SOMEONE-ELSE-1' => { commit => 'abc', version => '1.00' } },
        );
    };
    ok( $got, 'a fact about another ref says nothing about this one, so it records' );
}

# --- the gatherer: which commit, and which version, belongs to a ref ----------

{
    my $facts = facts_for( $card{one} );
    is( $facts->{ $card{one} }{version}, '1.01', 'the version in .env at the card\'s own commit' );
    like( $facts->{ $card{one} }{commit}, qr/\A\Q$first\E/, 'and that commit' );
    is_deeply( facts_for( $card{three} ), {}, 'a ref no commit names has no fact at all' );

    my $twice = $tira->create_record( project => $root, type => 'ticket', title => 'Two commits', priority => 3 )->{ref};
    my $earlier = commit_version( '2.01', "$twice: first commit" );
    commit_version( '2.02', "$twice: a follow-up" );
    my $twice_facts = facts_for($twice);
    is( $twice_facts->{$twice}{version}, '2.01', 'with two commits, the OLDEST one is the one compared' );
    like( $twice_facts->{$twice}{commit}, qr/\A\Q$earlier\E/, 'and it is named' );
}

# --- the gatherer leaves out everything it cannot compare ---------------------

{
    {
        package Stub::Where;
        sub new { my ( $class, $path ) = @_; return bless { path => $path }, $class }
        sub discover_project { return $_[0]{path} }
    }

    sub repo_with {
        my ( $name, $files, $subject ) = @_;
        my $dir = File::Spec->catdir( $tmp, $name );
        mkdir $dir or die "mkdir $dir: $!";
        qx(git -C "$dir" init -q 2>&1);
        for my $file ( sort keys %{$files} ) {
            open my $fh, '>', File::Spec->catfile( $dir, $file ) or die $!;
            print {$fh} $files->{$file};
            close $fh;
        }
        qx(git -C "$dir" add -A 2>&1);
        qx(git -C "$dir" -c user.name=t -c user.email=t\@example.com commit -q -m '$subject' 2>&1);
        return $dir;
    }

    my $not_git = File::Spec->catdir( $tmp, 'not-a-repository' );
    mkdir $not_git or die $!;
    is_deeply( Tira::CLI::Release::commit_versions( Stub::Where->new($not_git), { ref => 'ZZ-1' } ), {},
        'outside a git repository there is no fact' );

    my $no_env = repo_with( 'no-env', { 'README' => "hello\n" }, 'ZZ-1: a commit in a tree with no .env' );
    is_deeply( Tira::CLI::Release::commit_versions( Stub::Where->new($no_env), { ref => 'ZZ-1' } ), {},
        'a commit whose tree has no .env gives no fact' );

    my $no_version = repo_with( 'no-version', { '.env' => "OTHER=1\n" }, 'ZZ-2: a .env with no VERSION line' );
    is_deeply( Tira::CLI::Release::commit_versions( Stub::Where->new($no_version), { ref => 'ZZ-2' } ), {},
        'a .env with no VERSION line gives no fact' );

    my $with_version = repo_with( 'with-version', { '.env' => "VERSION=4.20\n" }, 'ZZ-3: a real one' );
    is( Tira::CLI::Release::commit_versions( Stub::Where->new($with_version), { ref => 'ZZ-3' } )->{'ZZ-3'}{version},
        '4.20', 'and a .env with one gives it, so the three cases above are about the repository, not the helper' );
}

# --- a shallow clone cannot say which commit is oldest, so it gives no fact ----

{
    my $shallow = File::Spec->catdir( $tmp, 'shallow' );
    my $cloned  = qx(git clone -q --depth 1 "file://$root" "$shallow" 2>&1);
    is( $?, 0, 'a shallow clone of the repository was made' ) or diag $cloned;

    # Only discover_project is asked of the invocant, so a stand-in is enough
    # to point the gatherer at a different directory.
    {
        package Stub::Tira;
        sub new { my ( $class, $path ) = @_; return bless { path => $path }, $class }
        sub discover_project { return $_[0]{path} }
    }
    my $facts = Tira::CLI::Release::commit_versions( Stub::Tira->new($shallow), { ref => $card{one} } );
    is_deeply( $facts, {}, 'a shallow clone gives no fact, even for a ref whose commit is in it' );

    my $whole = Tira::CLI::Release::commit_versions( Stub::Tira->new($root), { ref => $card{one} } );
    is( $whole->{ $card{one} }{version}, '1.01', 'while the full repository still does' );
}

# --- the command line: --force-version reaches the engine, and only there ----

require Tira::CLI;

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @warned ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => $tira, argv => [ '--author', 'claude', @argv ] );
    };
    return ( $status, $out . $err, \@warned );
}

{
    my $ref = $tira->create_record( project => $root, type => 'ticket', title => 'Through the CLI', priority => 3 )->{ref};
    my $sha = commit_version( '1.07', "$ref: cli case" );
    my @release = ( '--ref', $ref, '--gate', 'gate-run', '--result', 'pass', '--details', 'ran', '--evidence', 'passed' );

    my ( $status, $said, $warned ) = cli( 'release.record', @release, '--fix-version', '1.08' );
    isnt( $status, 0, 'the command line refuses a mismatching --fix-version' );
    like( $said, qr/1\.07/, 'and says which version the commit carries' );
    like( $said, qr/\Q$sha\E/, 'and which commit' );
    is_deeply( $warned, [], 'with no Perl warning' );
    ok( !defined fix_version_of($ref), 'and records nothing' );

    ( $status, $said ) = cli( 'release.record', @release, '--fix-version', '1.08', '--force-version' );
    is( $status, 0, '--force-version on the command line records it anyway' );
    is( fix_version_of($ref), '1.08', 'and the version is on the card' );

    ( $status, $said ) = cli( 'record.update', '--ref', $ref, '--force-version' );
    isnt( $status, 0, '--force-version on a command that does not read it is refused, not swallowed' );
    like( $said, qr/release\.record/, 'naming the command that does' );
}

done_testing;

__END__

=head1 NAME

1207-release-record-checks-fix-version-against-commits.t - release.record refuses a fix_version its own commit contradicts

=head1 DESCRIPTION

TKT-1207. C<release.record> accepted any version-shaped C<--fix-version>, so
recording 5.245 on a card whose commits carry 5.240 went through. This file
holds that a mismatch with the ref's own oldest commit is refused with both
versions and the commit named and nothing recorded, that the matching version,
a ref with no commit, C<none>, an C<n/a> value, a board outside git and
C<--force-version> all record as before, that one ref is not matched as the
prefix of another, and that a batch reports the refused card and records the
rest.

=cut
