#!/usr/bin/env perl
# TIRA_HOME names a board through _dd_path_resolver, which merges a repo-local
# .developer-dashboard.json (found by walking up from the working directory
# to the nearest .git) over the user's global path_aliases. A repo that
# defines the SAME alias name a global config already uses silently wins
# whenever the working directory sits inside it - the caller asked for the
# board an alias has always meant and got whichever board happened to be
# nearest instead, with no warning and no difference in the output.
#
# Measured live: an identical alias, naming a scratch board, resolved to the
# real board instead from two working directories that themselves held such
# an override, and a command run that way did real damage before anybody
# noticed - a column was turned unwatched and a stray card created on the
# wrong board. TKT-368.

use strict;
use warnings;

use Cwd qw(cwd);
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use Cpanel::JSON::XS qw(encode_json);

eval {
    require Developer::Dashboard::Config;
    require Developer::Dashboard::FileRegistry;
    require Developer::Dashboard::PathRegistry;
    1;
} or plan skip_all => 'Developer::Dashboard is not installed here';

use lib 'lib';
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
$tmp =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe temporary path';
$tmp = $1;

my $home          = File::Spec->catdir( $tmp, 'home' );
my $global_target = File::Spec->catdir( $tmp, 'global-target' );
my $repo_target   = File::Spec->catdir( $tmp, 'repo-target' );
make_path($_) for ( $home, $global_target, $repo_target,
    File::Spec->catdir( $repo_target, '.git' ) );

my $config_dir = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
make_path($config_dir);
open my $global_fh, '>', File::Spec->catfile( $config_dir, 'config.json' )
  or die "Cannot write global config: $!";
print {$global_fh} encode_json( { path_aliases => { 'shared-name' => $global_target } } );
close $global_fh;

# The repo-local file load_repo reads, at the root .git marks - naming the
# SAME alias a different board, the way one project's own config could
# without meaning to collide with anything.
open my $repo_fh, '>', File::Spec->catfile( $repo_target, '.developer-dashboard.json' )
  or die "Cannot write repo config: $!";
print {$repo_fh} encode_json( { path_aliases => { 'shared-name' => $repo_target } } );
close $repo_fh;

my $original_cwd = cwd();
local $ENV{HOME} = $home;

chdir $home or die "Cannot chdir to $home: $!";
my $from_neutral = Tira::CLI::_dd_path_resolver()->('shared-name');
is( $from_neutral, $global_target,
    'from a directory with no repo override, the global alias is used' );

chdir $repo_target or die "Cannot chdir to $repo_target: $!";
my $from_repo = Tira::CLI::_dd_path_resolver()->('shared-name');
is( $from_repo, $global_target,
    'and from inside a repo that names the same alias differently, the global alias still wins - TKT-368' );

chdir $original_cwd or die "Cannot restore cwd to $original_cwd: $!";

done_testing;

__END__

=head1 NAME

295-a-name-that-meant-two-things.t - a board selector means one board, not
whichever repo the working directory happens to be inside

=head1 DESCRIPTION

_dd_path_resolver registered every alias Developer::Dashboard::Config's
path_aliases returned, which merges a repo-local .developer-dashboard.json
over the user's global config - so a repo that names an alias the global
config already uses silently redefines what that name means, for as long as
the working directory sits inside that repo. Reading only
global_path_aliases makes a board selector the stable, user-level thing
TKT-250 already said it was: one way to name a board, and nothing nearby
gets to mean something different by the same name.

=cut
