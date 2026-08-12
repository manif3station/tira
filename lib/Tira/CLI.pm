package Tira::CLI;

use strict;
use warnings;

use Encode qw(decode encode_utf8 FB_CROAK);
use Cwd qw(abs_path cwd);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use Cpanel::JSON::XS ();
use Tira;

# PATH separators, executable extensions and the absence of an execute bit are
# all facts about the platform being described rather than the one this is
# running on, so they hang off a flag a test can set.
our $WINDOWS = $^O eq 'MSWin32' ? 1 : 0;

sub run {
    my ( $class, %args ) = @_;

    # Tira encodes its output to UTF-8 bytes and prints them. Perl puts a
    # text-mode layer on standard output on Windows, which rewrites every
    # newline on the way out, so the bytes that left the process were not the
    # bytes Tira produced - and Tira compares output bytes in its own cache.
    # Taking the layer off makes the output the same everywhere.
    binmode $_, ':raw' for ( \*STDOUT, \*STDERR );

    my $command = $args{command} // '';
    my $type = $args{type};
    my $argv = $args{argv} || [];
    my $tira = $args{tira} || Tira->new( path_resolver => _dd_path_resolver() );
    my $browser_server = $args{browser_server} || \&_serve_browser;
    my $restarter = $args{restarter} || \&_restart_into;
    my $guided_input = $args{input};
    my %option = ( output => 'toon' );
    our @RESTART_ARGV = @{$argv};
    my $environment_project;
    my $decoded = eval {
        for my $argument ( @{$argv} ) {
            $argument = decode( 'UTF-8', $argument, FB_CROAK ) if !utf8::is_utf8($argument);
        }
        if ( defined $ENV{TIRA_HOME} ) {
            $environment_project = utf8::is_utf8( $ENV{TIRA_HOME} )
              ? $ENV{TIRA_HOME} : decode( 'UTF-8', $ENV{TIRA_HOME}, FB_CROAK );
        }
        1;
    };
    return _error( $tira, 'toon', $@ || 'Invalid UTF-8 command-line input' ) if !$decoded;
    my $parsed = GetOptionsFromArray(
        $argv,
        'name=s' => \$option{name}, 'dir=s' => \$option{dir}, 'title:s' => \$option{title},
        'description=s' => \$option{description}, 'project=s' => \$option{project},
        'output|o=s' => \$option{output}, 'help' => \$option{help},
        'id=s' => \$option{id}, 'email=s' => \$option{email},
        'message=s' => \$option{message}, 'all' => \$option{all},
        'columns-json=s' => \$option{columns_json},
        'nested' => \$option{nested},
        'mark=s' => \$option{mark},
        'reason=s' => \$option{reason}, 'option=s@' => \$option{options},
        'voice=s' => \$option{voice}, 'remove' => \$option{remove},
        'question=s@' => \$option{questions}, 'filename=s' => \$option{filename},

        # Both of these were documented and neither could be passed: the
        # dashboard read with_questions from an option nothing ever set, and
        # card-sandbox-missing needs a sandbox the command line could not
        # take. Found by widening the documentation check to read the argument
        # tables, which is where almost every flag here is written down.
        'with-questions!' => \$option{with_questions},
        'no-session-expire' => \$option{no_session_expire},
        'ssl' => \$option{ssl},
        'sandbox=s' => \$option{sandbox},
        'collector=s' => \$option{collector}, 'agent=s' => \$option{agent},
        'session=s' => \$option{session}, 'heartbeat=s' => \$option{heartbeat},
        'outward=s' => \$option{outward}, 'inward=s' => \$option{inward},
        'type=s' => \$option{type}, 'label=s@' => \$option{labels},
        'after=s' => \$option{after}, 'before=s' => \$option{before},
        'new-name=s' => \$option{new_name}, 'prefix=s' => \$option{prefix},
        'digits=i' => \$option{digits}, 'ref=s@' => \$option{ref_list},
        'refs=s' => \$option{refs},
        'column=s' => \$option{column}, 'parent=s' => \$option{parent},
        'child=s' => \$option{child},
        'text=s' => \$option{text}, 'problem|problem-or-feature=s' => \$option{problem_or_feature},
        'solution-needed=s' => \$option{solution_needed}, 'source=s' => \$option{source},
        'from=s' => \$option{from}, 'to=s' => \$option{to},
        'author=s' => \$option{author}, 'file=s' => \$option{file},
        'format=s' => \$option{format}, 'comment=s' => \$option{comment},
        'sha=s' => \$option{sha}, 'extension=s' => \$option{extension},
        'summary=s' => \$option{summary}, 'uri=s' => \$option{uri},
        'gate=s' => \$option{gate}, 'result=s' => \$option{result},
        'details=s' => \$option{details},
        'item=s' => \$option{item}, 'status=s' => \$option{status},
        'field=s@' => \$option{fields}, 'pattern=s' => \$option{pattern},
        'fields=s@' => \$option{field_selection},
        'exclude-fields=s@' => \$option{exclude_fields},
        'include-empty' => \$option{include_empty},
        'since=s' => \$option{since},
        'if-changed=s' => \$option{if_changed},
        'count' => \$option{count}, 'refs-only' => \$option{refs_only},
        'brief' => \$option{brief}, 'truncate=i' => \$option{truncate},
        'last=i' => \$option{last}, 'first=i' => \$option{first},
        'meta-only' => \$option{meta_only},
        'where=s@' => \$option{where},
        'members=s@' => \$option{members}, 'columns=s@' => \$option{columns},
        'listen=s' => \$option{listen},
        'password=s' => \$option{password}, 'token=s' => \$option{token},
        'rule=s' => \$option{rule}, 'action=s' => \$option{action},
        'enter=s' => \$option{enter}, 'before-column=s' => \$option{before_column},
        'age=s' => \$option{age},
        'max=i' => \$option{max}, 'require=s' => \$option{require},
        'once' => \$option{once}, 'interval=i' => \$option{interval},
        'seconds=i' => \$option{seconds},
        'on-column=s' => \$option{on_column},
        'role=s@' => \$option{roles},
        'require-link=s' => \$option{require_link}, 'link-to=s' => \$option{link_to},
        'enter-role=s' => \$option{enter_role}, 'before-role=s' => \$option{before_role},
        'rounds=i' => \$option{rounds},
        'store=s' => \$option{store},
        'dashboard-host=s' => \$option{dashboard_host},
        'dashboard-port=s' => \$option{dashboard_port},
        'sow-columns=s@' => \$option{sow_columns}, 'epic-columns=s@' => \$option{epic_columns},
        'ticket-columns=s@' => \$option{ticket_columns},
        'sow-prefix=s' => \$option{sow_prefix}, 'epic-prefix=s' => \$option{epic_prefix},
        'ticket-prefix=s' => \$option{ticket_prefix},
        'snapshot=s' => \$option{snapshot},
        'older-than=s' => \$option{older_than},
        'notify-after=s' => \$option{notify_after}, 'mode=s' => \$option{mode},
        'watch!' => \$option{watched}, 'stale' => \$option{stale},
        'with-level' => \$option{with_level},
        'cache-ttl=i' => \$option{cache_ttl}, 'no-cache' => \$option{no_cache},
        'with=s' => \$option{with}, 'note=s' => \$option{note},
        'reporter=s' => \$option{reporter}, 'due-date=s' => \$option{due_date},
        'start-date=s' => \$option{start_date}, 'sdlc-gate=s' => \$option{sdlc_gate},
        'lifecycle=s' => \$option{lifecycle}, 'priority=s' => \$option{priority},
        'fix-version=s' => \$option{fix_version},
        'repair-columns' => \$option{repair_columns}, 'apply' => \$option{apply},
        'recursive' => \$option{recursive}, 'include-deleted' => \$option{include_deleted},
        'include-discard' => \$option{include_discard},
        'full' => \$option{full}, 'dry-run' => \$option{dry_run},
        'key-detail=s@' => \$option{key_details}, 'deliverable=s@' => \$option{deliverables},
        'scope-in=s@' => \$option{scope_in}, 'scope-out=s@' => \$option{scope_out},
        'acceptance|acceptance-criteria=s@' => \$option{acceptance}, 'test-step=s@' => \$option{test_steps},
        'bdd=s@' => \$option{bdd}, 'atdd=s@' => \$option{atdd},
        'assignee=s' => \$option{assignee}, 'person=s@' => \$option{people},
        'attach=s@' => \$option{attach},
        'affects-version=s@' => \$option{affects_versions},
        'set-key-details=s' => \$option{set_key_details},
        'set-deliverables=s' => \$option{set_deliverables},
        'set-acceptance|set-acceptance-criteria=s' => \$option{set_acceptance},
        'set-test-steps=s' => \$option{set_test_steps},
        'set-bdd=s' => \$option{set_bdd}, 'set-atdd=s' => \$option{set_atdd},
        'set-labels=s' => \$option{set_labels},
        'set-affects-versions=s' => \$option{set_affects_versions},
    );
    return _error( $tira, $option{output}, 'Invalid command-line options' ) if !$parsed || @{$argv};
    $option{ref} = $option{ref_list}[-1] if $option{ref_list};
    $option{$_} = _expand_home( $option{$_} ) for grep { defined $option{$_} } qw(dir project);

    if ( $option{help} || $command eq 'policies' ) {
        print $command eq 'policies' ? _policy_help() : _usage( $command, $type );
        return 0;
    }

    return _error( $tira, 'toon', "Unsupported output format '$option{output}'" )
      if $command eq 'attachment.get' && $option{output} !~ /\A(?:toon|json|human)\z/;
    return _error( $tira, 'toon', 'Table output is available only for dashboard commands' )
      if $option{output} eq 'table' && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;
    return _error( $tira, 'toon', 'Browser output is available only for dashboard commands' )
      if $option{output} =~ /\Abrowser(?:=|\z)/ && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;

    $option{project} = $environment_project if !defined $option{project} && defined $environment_project;

    my ( $browser_host, $browser_port );
    if ( $option{output} =~ /\Abrowser(?:=(.*))?\z/ ) {
        my $given = $1;
        # Precedence, stated once: an address on the command line wins, the
        # project's remembered address is next, the original default last.
        my $endpoint = defined $given && length $given ? $given : do {
            my $stored = eval { $tira->project_show( project => $option{project} )->{dashboard} };
            join ':', ( $stored->{host} // '0.0.0.0' ), ( $stored->{port} // 7899 );
        };
        my $valid = eval {
            ( $browser_host, $browser_port ) = _browser_endpoint($endpoint);
            1;
        };
        return _error( $tira, 'toon', $@ || 'Invalid browser endpoint' ) if !$valid;
    }

    # Only tira.onboard ever prompts. project.new stays purely argument-driven,
    # so no script or agent invoking it can be left waiting on input, and
    # onboard needs no terminal detection: without input it reaches end of
    # stream immediately and aborts rather than blocking.
    if ( $command eq 'onboard' ) {
        my ( $answers, $guided_status ) = _project_wizard( $tira, $guided_input // \*STDIN, \%option );
        if ( !$answers ) {
            print STDERR "Nothing was created.\n";
            return $guided_status;
        }
        %option = ( %option, %{$answers} );
    }

    my $cache;
    if ( defined $option{cache_ttl} && $option{cache_ttl} >= 1 && !$option{no_cache} ) {
        $cache = eval { _cache_context( $tira, $command, $type, \%option ) };
        if ( $cache && $cache->{hit} ) {
            print STDERR "tira: served from cache\n";
            print _utf8_bytes( $cache->{hit}{bytes} );
            return $cache->{hit}{status};
        }
    }
    my $result;
    my $ok = eval {
        $result = _invoke( $tira, $command, $type, \%option );
        1;
    };
    return _error( $tira, $option{output}, $@ || 'Unknown Tira failure' ) if !$ok;

    if ( $command eq 'attachment.get' ) {
        print $result->{content};
        return $result->{deleted} ? 1 : 0;
    }

    if ( defined $browser_host ) {
        my $render = sub {
            my %render_option = %option;
            $render_option{output} = 'table';
            my $dashboard = _invoke( $tira, $command, $type, \%render_option );
            return $tira->format_output(
                $dashboard, output => 'table', project => $option{project}, live => 1,
                with_title => defined $option{title},
            );
        };
        my $data = sub {
            my %data_option = %option;
            $data_option{output} = 'toon';
            $data_option{include_mtime} = 1;
            $data_option{with_questions} = 1;
            my $dashboard = _invoke( $tira, $command, $type, \%data_option );

            # A dashboard left open is running whatever Tira it started with.
            # Rather than making somebody visit every open board after an
            # update, the server notices and restarts itself into the new code;
            # the page then reloads when it sees a version it was not built by.
            _restart_if_updated( $restarter, $command, $type, $option{project} );
            $dashboard->{_version} = $Tira::VERSION;
            return $tira->format_output( $dashboard, output => 'json', project => $option{project} );
        };
        # His decision, taken here and said out loud. A board serving sessions
        # that never expire is a different thing from one that does, and
        # somebody starting it should be able to tell without reading a manual.
        if ( $option{no_session_expire} ) {
            $Tira::SESSION_NEVER_EXPIRES = 1;
            print {*STDERR} "Sessions on this board never expire: a sign-in lasts until somebody signs out.\n"
              . "Over plain HTTP that cookie is a credential with no end date, so serve it somewhere you trust.\n";
        }

        # Over plain HTTP a password typed into the login page and the cookie
        # that follows it both travel in clear, which the documentation used to
        # admit rather than fix. A self-signed certificate stops somebody
        # reading them off the wire; it does not stop somebody who can already
        # stand in the middle, and saying so is part of offering it.
        my %tls;
        if ( $option{ssl} ) {
            my $certificate = $tira->tls_certificate( project => $option{project} );
            %tls = ( ssl_cert => $certificate->{certificate_path}, ssl_key => $certificate->{key_path} );
            print {*STDERR} "Serving over HTTPS with the board's own certificate.\n"
              . "It is self-signed, so a browser will warn the first time and you accept it once.\n"
              . "That stops somebody reading your password off the wire. It does not stop\n"
              . "somebody who can already stand between you and this machine.\n";
        }

        my %providers = browser_providers( tira => $tira, project => $option{project} );
        my $served = eval {
            $browser_server->(
                host => $browser_host, port => $browser_port, render => $render, data => $data,
                %tls, %providers,
            );
            1;
        };
        return _error( $tira, 'toon', $@ || 'Unable to serve dashboard' ) if !$served;
        return 0;
    }

    if ( $option{output} eq 'human' && $option{count} && ref $result eq 'HASH' ) {
        print "$result->{count}\n";
        return _finish( $tira, \%option, $command, 0 );
    }
    if ( $option{output} eq 'human' && $option{refs_only} && ref $result eq 'ARRAY' ) {
        print map { "$_\n" } @{$result};
        return _finish( $tira, \%option, $command, 0 );
    }
    my $formatted = eval { $tira->format_output( $result, output => $option{output}, project => $option{project} ) };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print _utf8_bytes($formatted);
    my $status = ( defined $option{if_changed} && ref $result eq 'HASH' && $result->{unchanged} ) ? 1 : 0;
    _cache_store( $cache, $formatted, $status ) if $cache;
    return _finish( $tira, \%option, $command, $status );
}

# Whatever the command was, an unresolved collector failure is shown
# under its output, because the collector itself had nobody to tell.
sub _finish {
    my ( $tira, $option, $command, $status ) = @_;
    return $status if $command =~ /\Awarning\./;
    my $warnings = eval { $tira->warning_list( project => $option->{project} ) } || [];
    return $status if !@{$warnings};
    my $banner = "\nAttention:\n"
      . join( '', map { "  [$_->{id}] $_->{at} $_->{message}\n" } @{$warnings} )
      . "Fix the cause, then clear with: tira.warning.clear --id <ID>"
      . " (or --all). Until then this shows under every command.\n";

    # A machine payload must stay parseable, so the banner goes where a human
    # and a coding agent both still read it without corrupting the output.
    if ( $option->{output} eq 'human' ) { print _utf8_bytes($banner) }
    else { print {*STDERR} _utf8_bytes($banner) }
    return $status;
}

sub _dd_path_resolver {
    return sub {
        my ($name) = @_;
        require Developer::Dashboard::Config;
        require Developer::Dashboard::FileRegistry;
        require Developer::Dashboard::PathRegistry;
        my $home = $ENV{HOME} // '';
        $home =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe home path\n";
        $home = $1;
        my $paths = Developer::Dashboard::PathRegistry->new(
            home => $home, cwd => cwd(), workspace_roots => [], project_roots => [],
        );
        my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
        my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
        $paths->register_named_paths( $config->path_aliases );
        return $paths->resolve_dir($name);
    };
}

sub _browser_endpoint {
    my ($endpoint) = @_;
    $endpoint =~ /\A(0\.0\.0\.0|127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
      or die "Unsupported browser endpoint '$endpoint'\n";
    my ( $host, $port ) = ( $1, defined $2 ? 0 + $2 : 7899 );
    die "Browser port must be between 1 and 65535\n" if $port < 1 || $port > 65535;
    return ( $host, $port );
}

# Through a seam so a test can watch the decision without a process replacing
# itself mid-suite. exec swaps this process for a new one - nothing is forked,
# and no shell is involved.
# The entrypoint this command was reached through. $0 is not reliable: under
# the dashboard dispatcher it is the dispatcher, so restarting on it re-ran the
# wrong program and the board died instead of updating. Derived from the module
# path and the command, and checked before anything is replaced.
sub _entrypoint_for {
    my ($command) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    my $root = File::Spec->rel2abs(
        File::Spec->catdir( dirname( dirname($1) ), File::Spec->updir ) );
    my @parts = split /\./, $command;
    my $action = pop @parts;
    my $path = @parts
      ? File::Spec->catfile( $root, 'skills', @parts, 'cli', $action )
      : File::Spec->catfile( $root, 'cli', $action );
    ($path) = $path =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;

    # Executability is what makes a file a command on a POSIX system. Windows
    # has no such bit, and -x there answers about the extension - so asking for
    # it found nothing, _entrypoint_for returned undef, and a dashboard on
    # Windows never picked up a new version however many were installed.
    return ( $WINDOWS ? -f $path : -x $path ) ? $path : undef;
}

sub _restart_into {
    my (@argv) = @_;
    my ($perl) = $^X =~ /\A([^\x00-\x1f\x7f]+)\z/ or return 0;
    my $script = shift @argv or return 0;

    # Both the interpreter and the script are absolute here, so the search path
    # is never consulted to find them; taint mode objects to it regardless.
    # Handing the restarted process a known-safe path is better than laundering
    # whatever this one happened to inherit, and better than wiping it.
    # Both are absolute, so the search path is never consulted to find them;
    # this is about what the restarted process inherits. The POSIX directories
    # mean nothing on Windows, where emptying the path would break the child
    # rather than protect it, so only the shell variables go there.
    local $ENV{PATH} = '/usr/local/bin:/usr/bin:/bin' if !$WINDOWS;
    delete local @ENV{qw(IFS CDPATH ENV BASH_ENV)};
    exec( $perl, $script, @argv );
}

sub _restart_if_updated {
    my ( $restarter, $command, $type, $project ) = @_;
    my $installed = Tira::installed_version();

    # Unreadable means unknown, and restarting on unknown would loop forever.
    return 0 if !defined $installed || $installed eq $Tira::VERSION;

    # A restart that cannot work is worse than a stale board, because it turns
    # "running slightly old code" into "not running". So the target is checked
    # first, and if anything is missing the board simply carries on.
    my $script = _entrypoint_for( defined $type ? "$command.$type" : $command )
      // _entrypoint_for($command)
      or return 0;
    my @argv = grep { defined }
      map { /\A([^\x00-\x1f\x7f]*)\z/ ? $1 : undef } @Tira::CLI::RESTART_ARGV;
    return 0 if @argv != @Tira::CLI::RESTART_ARGV;

    # The project is passed explicitly rather than left to be rediscovered, so
    # the new process does not depend on a working directory or an environment
    # variable that may not survive the way it was launched.
    push @argv, '--project', $project
      if defined $project && $project =~ /\S/ && !grep { $_ eq '--project' } @argv;
    return $restarter->( $script, @argv );
}

sub _serve_browser {
    require Tira::DashboardWeb;
    return Tira::DashboardWeb->serve(@_);
}

# One provider set feeds both the CLI-launched Dancer2 server and the
# standalone dashboard.psgi, so browser mutations can never drift from the
# engine's validated command surface.
sub browser_providers {
    my (%args) = @_;
    my $tira = $args{tira};
    my $project = $args{project};
    my $json = Tira::json_object()->canonical;
    my %editable = map { $_ => 1 } qw(
        title description problem_or_feature solution_needed source
        sdlc_gate lifecycle fix_version assignee reporter priority
        start_date due_date
    );
    my %list_editable = (
        labels => 'labels_replace', affects_versions => 'affects_versions_replace',
        key_details => 'key_details_replace', deliverables => 'deliverables_replace',
        acceptance_criteria => 'acceptance_replace', test_steps => 'test_steps_replace',
        bdd => 'bdd_replace', atdd => 'atdd_replace',
        scope_included => 'scope', scope_excluded => 'scope',
    );
    return (
        move => sub {
            my ($payload) = @_;
            die "Move payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type ref column)) {
                die "Move payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $record = $tira->record_move(
                project => $project, type => $payload->{type},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ref => $payload->{ref}, column => $payload->{column},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        detail => sub {
            my ($payload) = @_;
            die "Record detail requires type and ref\n"
              if ref($payload) ne 'HASH' || !defined $payload->{type} || !defined $payload->{ref};
            my $record = $tira->record_show(
                project => $project, type => $payload->{type}, ref => $payload->{ref},
            );
            return $json->encode($record);
        },
        # The browser goes through the same subroutines the command line goes
        # through, so a rule cannot be enforced in one and forgotten in the
        # other. A failed sign-in answers ok => false rather than dying,
        # because the login page has to show a message, not a stack trace.
        # Fetched only when somebody expands the section. A card has a great
        # deal happen to it, and loading all of it whenever a card is opened
        # would bury everything else on the card.
        work_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->work_log( project => $project, ref => $payload->{ref} ) );
        },
        login_page => sub {
            my $project_name = eval { $tira->project_show( project => $project )->{name} };
            return $tira->login_page_html( name => $project_name );
        },
        login_start => sub {
            my ($payload) = @_;
            my $token = eval {
                $tira->login_start(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !defined $token;
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token } );
        },
        login_register => sub {
            my ($payload) = @_;
            my $person = eval {
                $tira->login_register(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !$person;
            my $token = $tira->login_start(
                project => $project, id => $payload->{id}, password => $payload->{password} );
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token, claimed => Cpanel::JSON::XS::true } );
        },
        session_resume => sub {
            my ($payload) = @_;
            my $session = $tira->session_resume( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_peek => sub {
            my ($payload) = @_;
            my $session = $tira->session_peek( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_end => sub {
            my ($payload) = @_;
            my $ended = eval { $tira->session_end( project => $project, token => $payload->{token} ) };
            return $json->encode( { ok => $ended ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false } );
        },
        question_answer => sub {
            my ($payload) = @_;
            die "Answering needs a question and some text\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{text};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_answer(
                    project => $project, id => $payload->{id},
                    text => $payload->{text}, author => $payload->{author},
                ),
            } );
        },
        question_attach => sub {
            my ($payload) = @_;
            die "Attaching needs a question, a filename and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id}
              || !defined $payload->{filename} || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            die "That upload is empty\n" if !length $content;

            # The browser hands over bytes rather than a path, so they are
            # written somewhere the engine can take a path to and then removed.
            require File::Temp;
            my ( $fh, $path ) = File::Temp::tempfile(
                SUFFIX => ( $payload->{filename} =~ /(\.[A-Za-z0-9]+)\z/ ? $1 : '.bin' ) );
            binmode $fh;
            print {$fh} $content;
            close $fh;
            my $question = eval {
                $tira->question_attach(
                    project => $project, id => $payload->{id},
                    file => $path, to => $payload->{to},
                    filename => $payload->{filename} );
            };
            my $error = $@;
            unlink $path;
            die $error if !$question;
            return $json->encode( { ok => Cpanel::JSON::XS::true, question => $question } );
        },
        question_mark => sub {
            my ($payload) = @_;
            die "Marking needs a question and a mark\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{mark};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_mark(
                    project => $project, id => $payload->{id}, mark => $payload->{mark} ),
            } );
        },
        columns => sub {
            my ($query) = @_;
            return $json->encode(
                $tira->column_list( project => $project, type => $query->{type} ) );
        },
        column_apply => sub {
            my ($payload) = @_;
            die "Column layout must be an object with a type and columns\n"
              if ref($payload) ne 'HASH' || ref $payload->{columns} ne 'ARRAY';
            return $json->encode(
                $tira->column_apply(
                    project => $project, type => $payload->{type},
                    columns => $payload->{columns},
                )
            );
        },
        search => sub {
            my ($query) = @_;

            # No type: the board filter searches the whole project, because a
            # question reference can name a card on any board.
            return $json->encode( [] ) if !defined $query->{text} || $query->{text} eq '';
            return $json->encode(
                $tira->search(
                    project => $project, text => $query->{text},
                    ( defined $query->{type} && $query->{type} ne '' ? ( type => $query->{type} ) : () ),
                    refs_only => 1,
                )
            );
        },
        create => sub {
            my ($payload) = @_;
            die "Create payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type column title)) {
                die "Create payload requires type, column, and title\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || $payload->{$key} eq '';
            }
            my %optional;
            for my $field (qw(description priority assignee reporter)) {
                next if !defined $payload->{$field} || $payload->{$field} eq '';
                die "Field '$field' requires a plain value\n" if ref $payload->{$field};
                $optional{$field} = $payload->{$field};
            }
            $optional{reporter} = $payload->{_signed_in}
              if !defined $optional{reporter} && defined $payload->{_signed_in};
            my $record = $tira->create_record(
                project => $project, type => $payload->{type}, title => $payload->{title},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                %optional,
            );
            $record = $tira->record_move(
                project => $project, ref => $record->{ref}, column => $payload->{column},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            ) if $payload->{column} ne 'backlog';
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        update => sub {
            my ($payload) = @_;
            die "Update payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref field)) {
                die "Update payload requires ref, field, and value\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || !exists $payload->{value};
            }
            my $field = $payload->{field};
            my $value = $payload->{value};
            if ( $list_editable{$field} ) {
                die "Field '$field' requires an array value\n" if ref $value ne 'ARRAY';
                die "Field '$field' accepts plain text items only\n" if grep { ref $_ || !defined $_ } @{$value};
                my %change;
                if ( $field =~ /\Ascope_(included|excluded)\z/ ) {
                    my $side = $1;
                    my $scope = $tira->record_show( project => $project, ref => $payload->{ref} )->{scope};
                    $change{scope} = { %{ $scope // {} }, $side => $value };
                }
                else {
                    $change{ $list_editable{$field} } = $value;
                }
                my $record = $tira->record_update( project => $project, ref => $payload->{ref}, %change );
                return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
            }
            die "Field '$field' is not editable\n" if !$editable{$field};
            die "Field '$field' requires a plain value\n" if ref $value;
            die "Update base must be a plain value\n" if exists $payload->{base} && ref $payload->{base};
            my $record = $tira->record_update(
                project => $project, ref => $payload->{ref}, $field => $value,
                ( exists $payload->{base} ? ( expect => { $field => $payload->{base} } ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        link_types => sub {
            return $json->encode(
                [ map { { outward => $_->{outward}, inward => $_->{inward} } }
                  @{ $tira->link_type_list( project => $project ) } ]
            );
        },
        ( map {
            my ( $name, $method ) = @{$_};
            ( $name => sub {
                my ($payload) = @_;
                die ucfirst( $name =~ tr/_/ /r ) . " requires parent and child\n"
                  if ref($payload) ne 'HASH'
                  || !defined $payload->{parent} || ref $payload->{parent}
                  || !defined $payload->{child} || ref $payload->{child};
                my $result = $tira->$method(
                    project => $project, parent => $payload->{parent}, child => $payload->{child},
                );
                return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
            } );
        } ( [ hierarchy_link => 'hierarchy_link' ], [ hierarchy_unlink => 'hierarchy_unlink' ],
            [ subitem_link => 'subitem_link' ], [ subitem_unlink => 'subitem_unlink' ] ) ),
        link_add => sub {
            my ($payload) = @_;
            die "Link add requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $link = $tira->link_add(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, link => $link } );
        },
        link_remove => sub {
            my ($payload) = @_;
            die "Link removal requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $result = $tira->link_remove(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
        },
        checklist_add => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref item status)) {
                die "Checklist add requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $entry = $tira->checklist_add(
                project => $project, ref => $payload->{ref},
                item => $payload->{item}, status => $payload->{status},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        checklist_update => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            die "Checklist update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->checklist_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        comment_add => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            $payload->{author} = $payload->{_signed_in}
              if !defined $payload->{author} && defined $payload->{_signed_in};
            for my $key (qw(ref author text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            die "Project person '$payload->{author}' is inactive\n"
              if grep { $_->{id} eq $payload->{author} && !$_->{active} }
              @{ $tira->person_list( project => $project ) };
            my $comment = $tira->comment_add(
                project => $project, ref => $payload->{ref},
                author => $payload->{author}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_update => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $comment = $tira->comment_update(
                project => $project, ref => $payload->{ref},
                comment => $payload->{comment}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_remove => sub {
            my ($payload) = @_;
            die "Comment removal payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment)) {
                die "Comment removal requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $removed = $tira->comment_remove(
                project => $project, ref => $payload->{ref}, comment => $payload->{comment},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, removed => $removed } );
        },
        people => sub {
            return $json->encode(
                [ map { { id => $_->{id}, name => $_->{name} } }
                  grep { $_->{active} } @{ $tira->person_list( project => $project ) } ]
            );
        },
        attachment_fetch => sub {
            my ($payload) = @_;
            die "Attachment fetch requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $got = $tira->attachment_get(
                project => $project, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
            );
            die "Attachment '$payload->{sha}' not found\n" if $got->{deleted};
            my $record = $tira->record_show( project => $project, ref => $payload->{ref} );
            my ($reference) =
              grep { $_->{sha} eq $payload->{sha} }
              ( @{ $record->{attachments} }, map { @{ $_->{attachments} // [] } } @{ $record->{comments} } );
            my $extension = $payload->{extension} // ( $reference ? $reference->{extension} : 'bin' );
            my $filename = $reference ? $reference->{original_filename} : "$payload->{sha}.$extension";
            return {
                content => $got->{content},
                content_type => _attachment_content_type($extension),
                filename => $filename,
                inline => _attachment_content_type($extension) eq 'application/octet-stream' ? 0 : 1,
            };
        },
        attachment_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires ref, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            my $attachment = $tira->attachment_add_content(
                project => $project, ref => $payload->{ref},
                filename => $payload->{filename}, content => $content,
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, attachment => $attachment } );
        },
        attachment_discard => sub {
            my ($payload) = @_;
            die "Discard payload must be an object\n" if ref($payload) ne 'HASH';
            my $reference = $tira->attachment_discard(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                extension => $payload->{extension},
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            );
            return Tira::json_object()->canonical->encode(
                { ok => Cpanel::JSON::XS::true, attachment => $reference } );
        },

        attachment_remove => sub {
            my ($payload) = @_;
            die "Attachment removal requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $result = $tira->attachment_detach(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, %{$result} } );
        },
    );
}

# The viewer forces text-like content (html included) to plain text so
# nothing fetched from the store can execute inside the dialog's frame.
# CA18: per-call opt-in read-through cache. Entries live under the
# project's own .tira/cache (never a shared temp path), key on the full
# argument set, and are valid only while both the ttl holds and a board
# fingerprint (hi-res mtimes of the config, boards, columns, and
# attachment store) is unchanged — so any write invalidates immediately
# and a caller can never read its own stale data. A corrupt entry warns
# and falls back to a live read; a hit is always reported on stderr.
sub _board_fingerprint {
    my ($root) = @_;
    require Time::HiRes;
    my @stamps;
    my @paths = (
        File::Spec->catfile( $root, '.tira', 'project.yml' ),
        File::Spec->catdir( $root, '.tira', 'attachments' ),
    );

    # The counter Tira raises on every write. Modification times are the same
    # for two writes inside one clock tick on Windows - about sixteen
    # milliseconds - so a caller could be served the board as it was before its
    # own write. This has no clock in it.
    my $generation = File::Spec->catfile( $root, '.tira', '.generation' );
    if ( open my $fh, '<', $generation ) {
        my $line = <$fh>;
        close $fh;
        push @stamps, 'generation=' . ( defined $line ? $line : '' );
    }
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        push @paths, $board;
        my $dh;
        next if !opendir $dh, $board;
        my @entries = map { File::Spec->catdir( $board, $_ ) }
          sort grep { !/\A\./ } readdir $dh;
        closedir $dh;
        push @paths, @entries;

        # And the records themselves. A directory's modification time answers a
        # different question from the one being asked here: it changes when the
        # set of names changes, not when a file's contents do. A card edited in
        # place adds and removes no name, so on Windows the directory was
        # untouched, the cache was judged current, and the caller was served the
        # board as it was before its own write.
        for my $column ( grep { -d } @entries ) {
            my $files;
            next if !opendir $files, $column;
            push @paths, map { File::Spec->catfile( $column, $_ ) }
              sort grep { /\.json\z/ } readdir $files;
            closedir $files;
        }
    }
    for my $path (@paths) {
        my @stat = Time::HiRes::stat($path);
        push @stamps, $path . '=' . ( @stat ? $stat[9] : 'absent' );
    }
    return join ';', @stamps;
}

sub _cache_context {
    my ( $tira, $command, $type, $option ) = @_;
    my $root = $tira->discover_project( project => $option->{project} );
    ($root) = $root =~ /\A(.+)\z/s;
    my $key_source = Tira::json_object()->canonical->encode( {
        command => $command, type => $type,
        map { $_ => $option->{$_} }
          grep { defined $option->{$_} && $_ ne 'cache_ttl' && $_ ne 'no_cache' }
          sort keys %{$option},
    } );
    my $key = Digest::SHA::sha256_hex( encode_utf8($key_source) );
    my $dir = File::Spec->catdir( $root, '.tira', 'cache' );
    my $file = File::Spec->catfile( $dir, "$key.json" );
    my $context = {
        dir => $dir, file => $file, ttl => $option->{cache_ttl},
        fingerprint => _board_fingerprint($root),
    };
    if ( -f $file ) {
        require MIME::Base64;
        my $entry = eval {
            open my $fh, '<:raw', $file or die "unreadable\n";
            local $/;
            Tira::json_decode(<$fh>);
        };
        if ( !$entry || ref $entry ne 'HASH' || !defined $entry->{bytes} ) {
            print STDERR "tira: discarding corrupt cache entry\n";
        }
        elsif ( time() - ( $entry->{stored_at} // 0 ) <= $context->{ttl}
            && ( $entry->{fingerprint} // '' ) eq $context->{fingerprint} ) {
            $context->{hit} = {
                bytes => Encode::decode( 'UTF-8', MIME::Base64::decode_base64( $entry->{bytes} ) ),
                status => $entry->{status} // 0,
            };
        }
    }
    return $context;
}

sub _cache_store {
    my ( $context, $formatted, $status ) = @_;
    eval {
        require MIME::Base64;
        File::Path::make_path( $context->{dir} ) if !-d $context->{dir};
        my ( $fh, $temp ) = File::Temp::tempfile( DIR => $context->{dir}, SUFFIX => '.tmp' );
        binmode $fh, ':raw';
        print {$fh} Tira::json_object()->canonical->encode( {
            stored_at => time(), fingerprint => $context->{fingerprint},
            status => $status, bytes => MIME::Base64::encode_base64( _utf8_bytes($formatted), '' ),
        } );
        close $fh;
        rename $temp, $context->{file} or die "rename failed\n";
        1;
    } or print STDERR "tira: unable to store cache entry\n";
    return;
}

# The guided setup behind tira.onboard. Plain reads and writes — no terminal control
# codes, no new dependency, nothing spawned — so the command stays taint-clean.
# It is only ever entered deliberately (see the caller): a wizard that reads
# standard input would otherwise hang every script and agent that runs the
# command without arguments, which is most of them.
# a leading ~ means the user's home directory wherever it is typed.
# The shell expands it for an unquoted command-line argument, but never for an
# answer typed at a prompt or for a quoted flag — which is how a directory
# literally named '~' gets created.
sub _expand_home {
    my ($path) = @_;
    return $path if !defined $path || $path !~ m{\A~(?:/|\z)};
    my ($home) = ( $ENV{HOME} // '' ) =~ /\A([^\x00-\x1f\x7f]*)\z/;
    return $path if !defined $home || $home eq '';
    $path =~ s{\A~}{$home};
    return $path;
}

# Line editing without a dependency: Term::ReadLine's editing implementations
# are not installed anywhere this runs, so relying on one would silently give
# the user nothing. POSIX termios is core, so the editor is written directly
# against it and degrades to a plain read whenever input is not a terminal.
sub _raw_mode {
    my ($fh) = @_;
    my $fd = fileno($fh);
    return undef if !defined $fd || $fd < 0 || !-t $fh;
    require POSIX;
    my $saved = POSIX::Termios->new;
    return undef if !eval { $saved->getattr($fd) };
    my $raw = POSIX::Termios->new;
    $raw->getattr($fd);
    $raw->setlflag( ( $raw->getlflag // 0 ) & ~( POSIX::ICANON() | POSIX::ECHO() ) );
    $raw->setcc( POSIX::VMIN(),  1 );
    $raw->setcc( POSIX::VTIME(), 0 );
    $raw->setattr( $fd, POSIX::TCSANOW() );
    return sub { $saved->setattr( $fd, POSIX::TCSANOW() ); return };
}

sub _redraw {
    my ( $prompt, $buffer, $cursor ) = @_;
    my $column = length($prompt) + $cursor + 1;
    print "\r\e[2K$prompt$buffer\r\e[${column}G";
    return;
}

# Returns the finished line, or undef when the user abandons the prompt.
sub _edit_line {
    my ( $in, $prompt, $restore ) = @_;
    my ( $buffer, $cursor ) = ( '', 0 );
    _redraw( $prompt, $buffer, $cursor );
    while (1) {
        my $char = getc($in);
        if ( !defined $char || $char eq "\x04" || $char eq "\x03" ) {
            $restore->();
            print "\n";
            return undef;
        }
        if ( $char eq "\r" || $char eq "\n" ) {
            $restore->();
            print "\n";
            return $buffer;
        }
        if ( $char eq "\x01" ) { $cursor = 0 }                        # Ctrl-A
        elsif ( $char eq "\x05" ) { $cursor = length $buffer }        # Ctrl-E
        elsif ( $char eq "\x15" ) { $buffer = ''; $cursor = 0 }       # Ctrl-U
        elsif ( $char eq "\x0b" ) { substr $buffer, $cursor, length($buffer) - $cursor, '' }  # Ctrl-K
        elsif ( $char eq "\x7f" || $char eq "\x08" ) {
            if ( $cursor > 0 ) { substr $buffer, --$cursor, 1, '' }
        }
        elsif ( $char eq "\e" ) {
            my $bracket = getc($in);
            my $code = defined $bracket && $bracket eq '[' ? getc($in) : undef;
            if ( defined $code ) {
                if    ( $code eq 'D' ) { $cursor-- if $cursor > 0 }
                elsif ( $code eq 'C' ) { $cursor++ if $cursor < length $buffer }
                elsif ( $code eq 'H' ) { $cursor = 0 }
                elsif ( $code eq 'F' ) { $cursor = length $buffer }
            }
        }
        elsif ( $char =~ /\A[[:print:]]\z/ ) {
            substr $buffer, $cursor, 0, $char;
            $cursor++;
        }
        _redraw( $prompt, $buffer, $cursor );
    }
}

sub _ask {
    my ( $in, $question, $default ) = @_;
    my $shown = defined $default && $default ne '' ? " [$default]" : '';
    my $prompt = "$question$shown: ";
    my $answer;
    if ( my $restore = _raw_mode($in) ) {
        $answer = _edit_line( $in, $prompt, $restore );
    }
    else {
        print $prompt;
        $answer = <$in>;
    }
    return undef if !defined $answer;
    chomp $answer;
    $answer =~ s/\A\s+|\s+\z//g;
    return length $answer ? $answer : ( defined $default ? $default : '' );
}

sub _ask_yes {
    my ( $in, $question, $default ) = @_;
    while (1) {
        my $answer = _ask( $in, "$question [" . ( $default ? 'Y/n' : 'y/N' ) . ']', '' );
        return undef if !defined $answer;
        return $default if $answer eq '';
        return 1 if $answer =~ /\Ay(?:es)?\z/i;
        return 0 if $answer =~ /\An(?:o)?\z/i;
        print "  Please answer yes or no.\n";
    }
}

# Is there a coding agent on this machine at all? Its own sub so a
# test can drive both answers, rather than proving whichever one this
# particular machine happens to give.
# PATH is separated by a colon on POSIX and a semicolon on Windows, and a
# program there is executable because of its extension rather than a mode bit.
# Splitting on a colon and looking for an extensionless file found nothing on
# Windows however much was installed, and answered "no agent" rather than
# failing - so onboarding quietly offered nothing.

sub _agent_available {
    my ($name) = @_;
    my @suffixes = $WINDOWS ? ( split /;/, $ENV{PATHEXT} // '.COM;.EXE;.BAT;.CMD' ) : ('');

    # Split on the separator the platform being described uses, rather than
    # asking File::Spec, which answers for the platform this is running on and
    # so cannot be driven from anywhere else.
    my $separator = $WINDOWS ? ';' : ':';
    for my $dir ( split /\Q$separator\E/, $ENV{PATH} // '' ) {
        next if !length $dir;
        for my $suffix (@suffixes) {
            my $candidate = File::Spec->catfile( $dir, "$name$suffix" );
            return 1 if $WINDOWS ? -f $candidate : -x $candidate;
        }
    }
    return 0;
}

# Everything an existing project already knows, so re-running onboarding is a
# matter of pressing enter rather than typing it all again.
sub _wizard_defaults {
    my ( $tira, $dir ) = @_;
    return {} if !defined $dir || $dir eq '';
    my $project = eval { $tira->project_show( project => $dir ) } or return {};
    my %defaults = ( name => $project->{name} );
    my @people = map { $_->{id} } @{ $project->{people} // [] };
    $defaults{members} = [ join ', ', @people ] if @people;
    $defaults{$_} = $project->{$_}
      for grep { defined $project->{$_} } qw(collector agent session heartbeat notify_after);
    my %columns;
    for my $type (qw(sow epic ticket)) {
        my $refs = eval { $tira->board_refs( project => $dir, type => $type ) };
        $defaults{"${type}_prefix"} = $refs->{prefix} if $refs;
        my $list = eval { $tira->column_list( project => $dir, type => $type ) } or next;
        $columns{$type} = join ', ', map { $_->{label} // $_->{name} } @{$list};
        $defaults{"${type}_columns"} = [ $columns{$type} ];
    }
    my @distinct = keys %{ { map { $_ => 1 } values %columns } };
    $defaults{columns} = [ $distinct[0] ] if @distinct == 1;
    return \%defaults;
}

# Command-line flags win over what the project already stores, but only over
# the project they were given for: naming a different one rebuilds the defaults
# from scratch rather than merging, so a setting the new project does not have
# cannot be inherited from the old one by pressing enter.
sub _wizard_all_defaults {
    my ( $tira, $dir, $option ) = @_;
    my $stored = _wizard_defaults( $tira, $dir );
    my %default = ( %{$stored},
        map { $_ => $option->{$_} } grep { defined $option->{$_} } keys %{$option} );
    return ( $stored, \%default );
}

sub _project_wizard {
    my ( $tira, $in, $option ) = @_;
    print "Tira project setup — answer the questions, or press Ctrl-D to abort.\n\n";
    my %answers;

    # The directory comes first because everything else can be pre-filled from
    # the project already living there. Asking it second would mean offering
    # one project's answers while writing to another.
    # Asking first is only useful if it can answer itself: offer whatever
    # project is already resolvable rather than making somebody type the path
    # before any of the pre-filling can help.
    my $suggested = $option->{dir}
      // eval {
        $tira->discover_project( defined $option->{project} ? ( project => $option->{project} ) : () );
      }
      // '.';
    my ( $stored, $default ) = _wizard_all_defaults( $tira, $suggested, $option );
    my $dir = _ask( $in, 'Project directory', $suggested );
    return ( undef, 2 ) if !defined $dir;
    $answers{dir} = _expand_home($dir);
    ( $stored, $default ) = _wizard_all_defaults( $tira, $answers{dir}, $option )
      if $answers{dir} ne $suggested;
    print "\nEditing the project already at that directory — press enter to keep each answer.\n\n"
      if %{$stored};

    while (1) {
        my $name = _ask( $in, 'Project name', $default->{name} );
        return ( undef, 2 ) if !defined $name;
        if ( $name eq '' ) {
            print "  A project needs a name.\n";
            next;
        }
        $answers{name} = $name;
        last;
    }

    my $members = _ask( $in, 'People, separated by commas',
        $default->{members} ? join( ', ', @{ $default->{members} } ) : '' );
    return ( undef, 2 ) if !defined $members;
    # Enter means "none yet", not "a person with an empty name" — the
    # empty-string guard exists for an explicit --members "" on a command line.
    $answers{members} = [$members] if $members ne '';

    my %default_prefix = ( sow => 'SOW', epic => 'EPC', ticket => 'TKT' );
    for my $type (qw(sow epic ticket)) {
        while (1) {
            my $prefix = _ask( $in, "Reference prefix for \u$type records",
                $default->{"${type}_prefix"} // $default_prefix{$type} );
            return ( undef, 2 ) if !defined $prefix;
            if ( $prefix !~ /\A[A-Z][A-Z0-9-]{0,31}\z/ ) {
                print "  Invalid prefix: it must start with a capital letter and use capitals, digits, and hyphens.\n";
                next;
            }
            $answers{"${type}_prefix"} = $prefix;
            last;
        }
    }

    my $shared = _ask_yes( $in, 'Do all three boards use the same columns?', 1 );
    return ( undef, 2 ) if !defined $shared;
    if ($shared) {
        my $columns = _ask( $in, 'Columns, in order, separated by commas',
            $default->{columns} ? join( ', ', @{ $default->{columns} } ) : '' );
        return ( undef, 2 ) if !defined $columns;
        $answers{columns} = [$columns] if $columns ne '';
    }
    else {
        for my $type (qw(sow epic ticket)) {
            my $columns = _ask( $in, "Columns for the \u$type board",
                $default->{"${type}_columns"} ? join( ', ', @{ $default->{"${type}_columns"} } ) : '' );
            return ( undef, 2 ) if !defined $columns;
            $answers{"${type}_columns"} = [$columns] if $columns ne '';
        }
    }

    # Asked whether or not anything can send reminders: it decides what the
    # staleness report says, which is useful with no automation at all.
    while (1) {
        my $stuck = _ask( $in, 'Minutes before a card counts as stuck (blank for never)',
            $default->{notify_after} );
        return ( undef, 2 ) if !defined $stuck;
        last if $stuck eq '';
        if ( $stuck !~ /\A[0-9]+(?:\.[0-9]+)?\z/ || $stuck <= 0 ) {
            print "  That must be a positive number of minutes.\n";
            next;
        }
        $answers{notify_after} = $stuck;
        last;
    }

    # With no coding agent installed there is nothing to configure and nothing
    # that could deliver, so none of this is asked.
    if ( _agent_available('claude') ) {
        while (1) {
            my $agent = _ask( $in, 'Which coding agent should be reminded', $default->{agent} // 'claude' );
            return ( undef, 2 ) if !defined $agent;
            if ( $agent ne 'claude' ) {
                print "  The only coding agent supported today is claude.\n";
                next;
            }
            $answers{agent} = $agent;
            last;
        }
        while (1) {
            my $session = _ask( $in, 'Session id of the agent to remind', $default->{session} );
            return ( undef, 2 ) if !defined $session;
            last if $session eq '';
            if ( $session !~ /\A[A-Za-z0-9_-]{1,128}\z/ ) {
                print "  A session id is letters, digits, hyphens and underscores.\n";
                next;
            }
            $answers{session} = $session;
            last;
        }
        while (1) {
            my $collector = _ask( $in, 'Name for this project reminder job',
                $default->{collector} // Tira::_column_slug( $answers{name} ) );
            return ( undef, 2 ) if !defined $collector;
            last if $collector eq '';
            if ( $collector !~ /\A[a-z][a-z0-9-]{0,63}\z/ ) {
                print "  That must be lowercase letters, digits and hyphens.\n";
                next;
            }
            $answers{collector} = $collector;
            last;
        }
    }

    # One number of minutes, not two. The owner read the second as a repeat of
    # the first, and he was right to: there is no point looking more often than
    # the shortest window that could make anything stale. An explicit
    # --heartbeat still wins for anyone who wants to tune it.
    $answers{heartbeat} = $option->{heartbeat} // $answers{notify_after}
      if defined $answers{session}
      && defined( $option->{heartbeat} // $answers{notify_after} );

    # Which kind of project this is, asked rather than assumed. The questions
    # are the engine's, so what onboarding asks can be read by a test instead
    # of inferred from a sequence of prints. Left unanswered it stays unset,
    # and an unset project behaves exactly as every project does today.
    for my $question ( @{ $tira->onboarding_questions } ) {
        print "\n$question->{why}\n";
        while (1) {
            my $answer = _ask( $in, $question->{text}, $stored->{ $question->{id} } );
            return ( undef, 2 ) if !defined $answer;
            last if $answer eq '';
            if ( !grep { $_ eq $answer } @{ $question->{options} } ) {
                print '  Answer with ' . join( ' or ', @{ $question->{options} } ) . ".\n";
                next;
            }
            $answers{ $question->{id} } = $answer;
            last;
        }
    }

    print "\nAbout to create:\n";
    print "  name       $answers{name}\n";
    print "  directory  $answers{dir}\n";
    print "  people     " . ( join( ', ', @{ $answers{members} // [] } ) || '(none)' ) . "\n";
    print "  prefixes   sow $answers{sow_prefix}, epic $answers{epic_prefix}, ticket $answers{ticket_prefix}\n";
    for my $key ( grep { /_columns\z|\Acolumns\z/ } sort keys %answers ) {
        print "  $key " . join( ', ', @{ $answers{$key} } ) . "\n";
    }
    for my $key (qw(mode notify_after agent session collector heartbeat)) {
        print "  $key " . ( $answers{$key} // '(none)' ) . "\n" if exists $answers{$key};
    }
    print "\n";
    my $confirmed = _ask_yes( $in, 'Create this project?', 1 );
    return ( undef, 2 ) if !defined $confirmed;
    return ( undef, 1 ) if !$confirmed;
    return ( \%answers, 0 );
}

sub _attachment_content_type {
    my ($extension) = @_;
    return Tira::_attachment_content_type($extension);
}

sub _invoke {
    my ( $tira, $command, $record_type, $option ) = @_;
    # Who is running this, said once in the environment rather than remembered
    # on every command. Moves and edits from the command line went into the
    # work log attributed to nobody - the log knew what happened and never who,
    # which is most of what a work log is for. The browser has always known,
    # because there is a login in front of it. Absent both, the entry says
    # nobody rather than guessing at a name.
    if ( !defined $option->{author} && defined $ENV{TIRA_AUTHOR} && $ENV{TIRA_AUTHOR} ne '' ) {
        $option->{author} = utf8::is_utf8( $ENV{TIRA_AUTHOR} )
          ? $ENV{TIRA_AUTHOR} : decode( 'UTF-8', $ENV{TIRA_AUTHOR}, FB_CROAK );
    }

    my %args = %{$option};
    delete @args{qw(output help apply repair_columns recursive include_deleted include_discard full dry_run attach set_key_details set_deliverables set_acceptance set_test_steps set_bdd set_atdd set_labels set_affects_versions field_selection exclude_fields include_empty older_than stale with_level all columns_json nested mark members columns sow_prefix epic_prefix ticket_prefix sow_columns epic_columns ticket_columns)};
    if ( defined $option->{field_selection} || defined $option->{exclude_fields}
        || $option->{include_empty} || defined $option->{since}
        || $option->{brief} || defined $option->{truncate} ) {
        my $comment_scope = ( defined $option->{field_selection} || defined $option->{since} )
          && !defined $option->{exclude_fields} && !$option->{include_empty}
          && !$option->{brief} && !defined $option->{truncate};
        die "Read options are available on show, list, and export commands\n"
          if $command !~ /\A(?:record\.(?:show|list)|export)\z/
          && !( $comment_scope && $command =~ /\A(?:comment\.list|attachment\.list|diff)\z/ );
        $args{fields} = $option->{field_selection} if defined $option->{field_selection};
        $args{exclude_fields} = $option->{exclude_fields} if defined $option->{exclude_fields};
    }
    if ( $command =~ /\A(?:record\.(?:show|list)|export|history\.list)\z/ ) {
        die "Cannot combine --full with --truncate\n"
          if $option->{full} && defined $option->{truncate};
        die "Truncate must be zero or a positive character count\n"
          if defined $option->{truncate} && $option->{truncate} < 0;
        $args{truncate} = defined $option->{truncate} ? $option->{truncate}
          : $option->{full} ? undef : 2000;
        delete $args{truncate} if !defined $args{truncate};
    }
    $args{omit_empty} = 1
      if $command =~ /\A(?:record\.(?:show|list)|export)\z/ && !$option->{include_empty};
    delete $args{omit_empty} if $command eq 'history.list';
    die "Conditional reads are available on show and export commands\n"
      if defined $option->{if_changed} && $command !~ /\A(?:record\.show|export)\z/;
    die "Count is available on list, export, and search commands, and the comment, attachment, gate, and evidence lists\n"
      if $option->{count} && $command !~ /\A(?:record\.list|export|search|comment\.list|attachment\.list|gate\.list|evidence\.list|history\.list|diff)\z/;
    die "Snapshot baselines are available on the diff command\n"
      if defined $option->{snapshot} && $command ne 'diff';
    die "Older-than is available on the stale command\n"
      if defined $option->{older_than} && $command ne 'stale';
    die "Stale is available on the stale command\n"
      if $option->{stale} && $command ne 'stale';
    die "With-level is available on the stale command\n"
      if $option->{with_level} && $command ne 'stale';
    # Accepted and ignored is the worst of the three outcomes. An error is
    # fixed in seconds; doing the work would be right; answering with a
    # successful record while doing nothing cost this project every ticket's
    # parent and was invisible until somebody looked at a card.
    if ( defined $option->{parent} && $command =~ /\A(?:record|sow|epic|ticket)\.(?:update|create)\z/ ) {
        my $child = $option->{ref} // '<this record>';
        die "A parent is set with hierarchy.link, not by updating the record:\n"
          . "  tira.hierarchy.link --parent $option->{parent} --child $child\n";
    }

    die "All is available on the warning.clear and login.logout commands\n"
      if $option->{all} && $command ne 'warning.clear' && $command ne 'login.logout';
    die "A password belongs to the login.register and login.check commands\n"
      if defined $option->{password} && $command !~ /\Alogin\.(?:register|check)\z/;
    die "A token belongs to the login commands\n"
      if defined $option->{token} && $command !~ /\Alogin\./;
    die "A column layout belongs to the column.apply command\n"
      if defined $option->{columns_json} && $command ne 'column.apply';
    die "Nested belongs to the project.new, project.create and onboard commands\n"
      if $option->{nested} && $command !~ /\A(?:project\.(?:new|create)|onboard)\z/;
    die "A mark belongs to the question.mark command\n"
      if defined $option->{mark} && $command ne 'question.mark';
    die "A reason and options belong to the question.ask and question.update commands, and to police.suspend\n"
      if ( defined $option->{reason} || $option->{options} )
      && $command !~ /\Aquestion\.(?:ask|update)\z/
      && $command ne 'police.suspend';
    die "A voice note belongs to the question.ask, question.update and question.voice commands\n"
      if defined $option->{voice} && $command !~ /\Aquestion\.(?:ask|update|voice)\z/;
    die "Remove belongs to the question.voice and question.attach commands\n"
      if $option->{remove} && $command !~ /\Aquestion\.(?:voice|attach)\z/;
    die "Naming a question belongs to the attachment.list command\n"
      if $option->{questions} && $command ne 'attachment.list';
    die "Watch is available on the column.update command\n"
      if defined $option->{watched} && $command ne 'column.update';
    die "Notify-after is available on the column.update, project.update, project.new and onboard commands\n"
      if defined $option->{notify_after}
      && $command !~ /\A(?:column\.update|project\.update|project\.new|onboard)\z/;
    die "Reminder settings belong to the project.update, project.new and onboard commands\n"
      if $command !~ /\A(?:project\.update|project\.new|onboard)\z/
      && grep { defined $option->{$_} } qw(collector agent session heartbeat);
    die "Dashboard address options belong to the project.update command\n"
      if $command ne 'project.update'
      && grep { defined $option->{$_} } qw(dashboard_host dashboard_port listen);
    if ( defined $option->{listen} ) {
        # The compact form the owner asked for: --listen any:8080 is the same
        # thing as --dashboard-host any --dashboard-port 8080.
        my ( $host, $port ) = $option->{listen} =~ /\A([^:]+)(?::([0-9]+))?\z/
          or die "Listen address must be HOST or HOST:PORT\n";
        $args{dashboard_host} = $host;
        $args{dashboard_port} = $port if defined $port;
    }
    delete $args{listen};
    die "Bootstrap options belong to the project.new command\n"
      if $command ne 'project.new'
      && $command ne 'onboard'
      && grep { defined $option->{$_} }
      qw(members columns sow_columns epic_columns ticket_columns
         sow_prefix epic_prefix ticket_prefix);
    if ( defined $option->{cache_ttl} || $option->{no_cache} ) {
        die "Caching is available on read commands only\n"
          if $command !~ /\A(?:record\.(?:show|list)|export|search|diff|board\.show|project\.show|(?:comment|attachment|gate|evidence|checklist)\.list)\z/;
        die "Cache TTL must be a positive number of seconds\n"
          if defined $option->{cache_ttl} && $option->{cache_ttl} < 1;
    }
    delete @args{qw(cache_ttl no_cache)};
    die "Windows (--last/--first) are available on the comment, gate, evidence, and history lists\n"
      if ( defined $option->{last} || defined $option->{first} )
      && $command !~ /\A(?:comment|gate|evidence|history)\.list\z/;
    die "Meta-only is available on the comment and attachment lists, gate and evidence lists, show, list, and export\n"
      if $option->{meta_only}
      && $command !~ /\A(?:comment\.list|attachment\.list|gate\.list|evidence\.list|record\.(?:show|list)|export)\z/;
    die "Where filtering is available on list and export commands, and the gate and evidence lists\n"
      if defined $option->{where} && $command !~ /\A(?:record\.list|export|gate\.list|evidence\.list|history\.list)\z/;
    my @batch_refs = (
        @{ $option->{ref_list} // [] } > 1 ? @{ $option->{ref_list} } : (),
        defined $option->{refs} ? ( split /,/, $option->{refs} ) : (),
    );
    if (@batch_refs) {
        die "Multiple refs are only available on show\n" if $command !~ /\Arecord\.show\z/;
        die "Conditional reads do not batch; poll with export --fields ref,content_hash instead\n"
          if defined $option->{if_changed};
        @batch_refs = ( @{ $option->{ref_list} // [] }, @batch_refs )
          if @{ $option->{ref_list} // [] } == 1 && defined $option->{refs};
        $args{refs} = \@batch_refs;
        delete $args{ref};
        delete $args{ref_list};
    }
    delete $args{ref_list};
    delete $args{refs} if !@batch_refs;
    die "Refs-only is available on list and search commands\n"
      if $option->{refs_only} && $command !~ /\A(?:record\.list|search)\z/;
    $args{type} = $record_type if defined $record_type;
    my %sets = (
        set_key_details => 'key_details_replace', set_deliverables => 'deliverables_replace',
        set_acceptance => 'acceptance_replace', set_test_steps => 'test_steps_replace',
        set_bdd => 'bdd_replace', set_atdd => 'atdd_replace',
        set_labels => 'labels_replace', set_affects_versions => 'affects_versions_replace',
    );
    for my $set ( keys %sets ) {
        next if !defined $option->{$set};
        my $append = $set eq 'set_labels' ? 'labels'
          : $set eq 'set_affects_versions' ? 'affects_versions'
          : $sets{$set} =~ s/_replace\z//r;
        die "Cannot combine append and replacement for '$append'\n" if defined $args{$append};
        $args{ $sets{$set} } = _json_array_input( $option->{$set} );
    }
    $args{label} = $option->{labels}[0] if $command =~ /\Acolumn\.(?:add|rename)\z/ && $option->{labels};

    return $tira->create_project( name => $option->{name}, dir => $option->{dir} // '.' ) if $command eq 'project.create';
    if ( $command eq 'project.new' || $command eq 'onboard' ) {
        my $summary = $tira->project_new(
            name => $option->{name}, dir => $option->{dir} // '.',
            members => $option->{members}, columns => $option->{columns},
            map( { ( "${_}_columns" => $option->{"${_}_columns"} ) }
                grep { defined $option->{"${_}_columns"} } qw(sow epic ticket) ),
            ( defined $option->{digits} ? ( digits => $option->{digits} ) : () ),
            map( { ( "${_}_prefix" => $option->{"${_}_prefix"} ) }
                grep { defined $option->{"${_}_prefix"} } qw(sow epic ticket) ),
            map( { ( $_ => $option->{$_} ) }
                grep { defined $option->{$_} } qw(notify_after collector agent session heartbeat) ),
            ( $option->{nested} ? ( nested => 1 ) : () ),
        );

        # Written after the project exists, because it is a fact about the
        # project rather than one of the things that makes one. Unanswered
        # leaves it unset, and unset is every board that exists today.
        $tira->project_mode( project => $option->{dir} // '.', mode => $option->{mode} )
          if defined $option->{mode};

        # Collecting the settings and leaving the job unregistered
        # looked like it had worked. Onboarding registers it, and reports the
        # name it will really answer to, which is not the name that was typed.
        if ( $command eq 'onboard' && defined $summary->{project}{heartbeat} ) {
            # Project_show carries no root, so use the directory that was created.
            my $job = eval { $tira->collector_install( project => $option->{dir} // '.' ) };
            if ($job) {
                print "\nRegistered the reminder job as '$job->{name}'.\n"
                  . "Start it with: dashboard collector start $job->{name}\n\n";
                $summary->{collector} = $job;
            }
        }
        return $summary;
    }
    if ( $command eq 'question.attach' ) {
        return $tira->question_attach(
            project => $args{project}, id => $option->{id},
            file => $option->{file}, to => $option->{to},
            filename => $option->{filename}, remove => $option->{remove} );
    }
    if ( $command eq 'question.voice' ) {
        my $path = $option->{file} // $option->{voice};
        die "Use only one of --file or --remove\n" if defined $path && $option->{remove};
        return $tira->question_voice(
            project => $args{project}, id => $option->{id},
            file => $path, remove => $option->{remove} );
    }
    if ( $command =~ /\Aquestion\.(ask|list|answer|update|mark|discard)\z/ ) {
        my $action = $1;

        # By card reference alone: the reference already names the board, so
        # asking for the board as well would be asking for what is known.
        my %question = ( project => $args{project} );
        $question{ref} = $option->{ref_list}[0] if $option->{ref_list};
        $question{$_} = $option->{$_} for grep { defined $option->{$_} } qw(id text mark author reason);
        $question{voice} = $option->{voice} if defined $option->{voice} && $action eq 'update';
        $question{file} = $option->{file} if defined $option->{file} && $action eq 'answer';
        $question{options} = $option->{options} if $option->{options};
        $question{status} = $option->{status} if defined $option->{status};
        $question{since} = $option->{since} if defined $option->{since};
        return $tira->question_add(%question) if $action eq 'ask';
        return $tira->question_list(%question) if $action eq 'list';
        return $tira->question_answer(%question) if $action eq 'answer';
        return $tira->question_update(%question) if $action eq 'update';
        return $tira->question_discard(%question) if $action eq 'discard';
        return $tira->question_mark(%question);
    }
    return $tira->warning_list(%args) if $command eq 'warning.list';
    return $tira->warning_add(%args) if $command eq 'warning.add';
    return $tira->warning_clear( %args, all => $option->{all} ) if $command eq 'warning.clear';
    return $tira->notification_message( project => $args{project} ) if $command eq 'notify.compose';
    return $tira->collector_entry(%args) if $command eq 'collector.show';
    return $tira->collector_install(%args) if $command eq 'collector.install';
    return $tira->collector_remove(%args) if $command eq 'collector.remove';
    if ( $command =~ /\Anotify\.(record|list)\z/ ) {
        my $action = $1;
        my %notify = ( project => $args{project}, ref => $option->{ref_list} );
        $notify{column} = $option->{column} if defined $option->{column};
        return $tira->notification_list(%notify) if $action eq 'list';
        return $tira->notification_record(%notify);
    }
    if ( $command eq 'record.create' ) {

        # The record itself stays exactly what is stored - an agent can trust
        # that what it holds is what is on disk. The advice about it belongs to
        # the layer that talks to agents, not to the data.
        my $created = $tira->create_record(%args);
        my $reminder = $tira->record_reminder($created);
        return defined $reminder ? { %{$created}, reminder => $reminder } : $created;
    }
    return $tira->export_records(%args) if $command eq 'export';
    return $tira->diff_records(%args) if $command eq 'diff';
    if ( $command eq 'stale' ) {
        my %dwell = ( project => $args{project} );
        $dwell{type} = $args{type} if defined $args{type};
        $dwell{older_than} = $option->{older_than} if defined $option->{older_than};
        $dwell{stale} = 1 if $option->{stale};
        $dwell{with_level} = 1 if $option->{with_level};
        return $tira->dwell_list(%dwell);
    }
    if ( $command eq 'history.list' ) {
        my %history = %args;
        delete $history{fields};
        $history{field} = $option->{fields}[0] if $option->{fields};
        return $tira->history_list(%history);
    }
    if ( $command eq 'import' ) {
        die "Import file is required\n" if !defined $option->{file};
        my $changes = Tira::json_decode( _text_input( $option->{file} ) );
        return $tira->bulk_import( %args, changes => $changes, dry_run => $option->{dry_run} );
    }
    return $tira->replace_records( %args, dry_run => $option->{dry_run} ) if $command eq 'replace';
    return $tira->project_show(%args) if $command eq 'project.show';

    # Reading and setting are one command, because the answer is one fact and
    # two commands would invite a board where it was set and never read.
    return { mode => $tira->project_mode(%args) } if $command eq 'project.mode';
    return { max => $tira->project_limit(%args) } if $command eq 'project.limit';
    return $tira->project_update(%args) if $command eq 'project.update';
    return $tira->person_list(%args) if $command eq 'project.people.list';
    return $tira->person_add(%args) if $command eq 'project.people.add';
    return $tira->person_update(%args) if $command eq 'project.people.update';
    return $tira->person_remove(%args) if $command eq 'project.people.remove';
    return $tira->person_activate(%args) if $command eq 'project.people.activate';
    return $tira->person_deactivate(%args) if $command eq 'project.people.deactivate';
    return $tira->link_type_list(%args) if $command eq 'project.link-types.list';
    return $tira->link_type_add(%args) if $command eq 'project.link-types.add';
    return $tira->link_type_remove(%args) if $command eq 'project.link-types.remove';
    return $tira->project_validate( %args, repair => $option->{repair_columns} ) if $command eq 'project.validate';
    return $tira->board_show(%args) if $command eq 'board.show';
    return $tira->board_refs(%args) if $command eq 'board.refs';
    return $tira->column_list(%args) if $command eq 'column.list';
    return $tira->column_add(%args) if $command eq 'column.add';
    return $tira->column_rename(%args) if $command eq 'column.rename';
    return $tira->column_reorder(%args) if $command eq 'column.reorder';
    return $tira->column_remove(%args) if $command eq 'column.remove';
    return $tira->column_update(%args) if $command eq 'column.update';
    if ( $command eq 'column.apply' ) {
        my $layout = eval { Tira::json_object()->utf8->decode( $option->{columns_json} // '' ) };
        die "A column layout must be JSON: a list of objects with a name\n" if ref $layout ne 'ARRAY';
        return $tira->column_apply( project => $args{project}, type => $args{type}, columns => $layout );
    }
    return $tira->column_sync( %args, apply => $option->{apply} ) if $command eq 'column.sync';

    if ( $command eq 'column.roles' ) {
        return $tira->column_roles(%args) if !$option->{roles};

        # Written the way he says it: which column is the backlog, which is
        # in progress. Each --role takes name=column, and any role may be
        # left unset because most projects have a column for very few of them.
        my %roles;
        for my $pair ( @{ $option->{roles} } ) {
            my ( $role, $column ) = split /=/, $pair, 2;
            die "A role is written as name=column, not '$pair'\n"
              if !defined $column || $column eq '' || $role eq '';
            $roles{$role} = $column;
        }
        return $tira->column_roles_set( %args, roles => \%roles );
    }

    if ( $command =~ /\Arecord\.(show|list|update|move|discard|restore|clone)\z/ ) {
        my $action = $1;
        return $tira->record_show_many(%args) if $action eq 'show' && $args{refs};
        return $tira->record_show(%args) if $action eq 'show';
        return $tira->record_list(%args) if $action eq 'list';
        return $tira->record_update(%args) if $action eq 'update';
        return $tira->record_move(%args) if $action eq 'move';
        return $tira->record_discard(%args) if $action eq 'discard';
        return $tira->record_restore(%args) if $action eq 'restore';
        return $tira->record_clone(%args);
    }

    return $tira->gates_install(%args) if $command eq 'gates.install';
    return $tira->work_log(%args) if $command eq 'worklog.show';

    if ( $command eq 'police.suspend' || $command eq 'police.log' ) {
        my $store = $option->{store} // _police_store( $args{project} );
        return $tira->enforcement_log( %args, store => $store )
          if $command eq 'police.log';
        my $quiet = $tira->police_suspend(
            %args, store => $store,
            seconds => $option->{seconds}, reason => $option->{reason} );

        # The owner sees every suspension as it happens, so quiet is never
        # something that simply occurs.
        print {*STDERR} "$quiet->{terminal}\n";
        return $quiet;
    }

    if ( $command eq 'police' || $command eq 'policy.bridge' ) {
        my $store = $option->{store} // _police_store( $args{project} );

        if ( $command eq 'policy.bridge' ) {

            # Who is tailing it. One agent per ticket means an agent's concern
            # is its own cards, so the bridge narrows to whoever says who they
            # are - by --author, or by TIRA_AUTHOR in the environment, said
            # once rather than on every command. Nobody named hears everything,
            # which is how the owner watches the whole board.
            my $agent = $option->{author};
            my $backlog = $tira->bridge_backlog( store => $store, lines => 200, agent => $agent );
            print map { "$_\n" } @{$backlog};
            _bridge_follow( $tira, $store, rounds => $option->{rounds}, agent => $agent,
                interval => $option->{interval}, sleeper => $option->{sleeper} )
              if !$option->{once};
            return { streamed => scalar @{$backlog} };
        }

        # Before anything is reported: what to hand the agent. Police watching a
        # board nobody has set up finds nothing, and that silence looks exactly
        # like compliance - so the owner gets something to copy across rather
        # than writing the instructions himself every time. Printed on every
        # run, because remembering which run was the first is the sort of thing
        # he should not have to do.
        my $prompt = eval { $tira->police_prompt(%args) };
        print {*STDERR} "\n$prompt\n" if defined $prompt;

        my $result = $tira->police_pass( %args, store => $store,
            world => _police_world( tira => $tira, project => $tira->discover_project(%args) ) );
        die "$result->{advice}\n" if !$result->{watching};
        $tira->bridge_write( store => $store, violations => $result->{violations} );
        print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
        return $result if $option->{once};
        return _police_follow( $tira, \%args, $store, $option );
    }

    if ( $command =~ /\Apolicy\.(add|list|remove)\z/ ) {
        my $action = $1;
        return $tira->policy_list(%args) if $action eq 'list';
        return $tira->policy_remove(%args) if $action eq 'remove';
        my %policy = map { $_ => $option->{$_} }
          grep { defined $option->{$_} }
          qw(rule action enter column age max pattern message require require_link link_to sandbox);

        # Where the policy is declared decides how narrow it is: naming a
        # board, a column or a card each makes it beat the level above.
        $policy{type} = $option->{type} if defined $option->{type};
        $policy{on_column} = $option->{on_column} if defined $option->{on_column};
        $policy{ref} = $args{ref} if defined $args{ref};
        $policy{enter_role} = $option->{enter_role} if defined $option->{enter_role};
        $policy{before_role} = $option->{before_role} if defined $option->{before_role};

        # --before already means a date filter elsewhere, so the column form
        # is spelled out rather than overloading a flag that means something
        # different on every other command.
        $policy{before} = $option->{before_column} if defined $option->{before_column};
        return $tira->policy_add( %args, %policy );
    }

    if ( $command =~ /\Alogin\.(register|check|status|logout)\z/ ) {
        my $action = $1;
        return $tira->login_register( %args, password => $option->{password} )
          if $action eq 'register';

        # A wrong password and a person who does not exist must look the same
        # from outside, or the command becomes a way to find out who is here.
        return { ok => $tira->login_verify( %args, password => $option->{password} )
              ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false }
          if $action eq 'check';

        # The listing says who, never what they are holding: a token is the
        # credential itself.
        return [ map { { person => $_->{person}, started_at => $_->{started_at},
                         last_seen_at => $_->{last_seen_at} } }
                 @{ $tira->session_list(%args) } ]
          if $action eq 'status';

        die "Use --id PERSON or --all to say whose sessions to end\n"
          if !$option->{all} && ( !defined $args{id} || $args{id} eq '' );
        my $ended = 0;
        for my $session ( @{ $tira->session_list(%args) } ) {
            next if !$option->{all} && $session->{person} ne $args{id};
            $tira->session_end( %args, token => $session->{token} );
            $ended++;
        }
        return { ended => $ended };
    }

    my %method = (
        'hierarchy.link' => 'hierarchy_link', 'hierarchy.unlink' => 'hierarchy_unlink', 'hierarchy.show' => 'hierarchy_show',
        'subitem.link' => 'subitem_link', 'subitem.unlink' => 'subitem_unlink',
        'link.add' => 'link_add', 'link.remove' => 'link_remove', 'link.list' => 'link_list',
        'assign.list' => 'assignment_list', 'assign.add' => 'assignment_add',
        'assign.remove' => 'assignment_remove', 'assign.set' => 'assignment_set',
        'comment.list' => 'comment_list', 'comment.add' => 'comment_add',
        'comment.update' => 'comment_update', 'comment.remove' => 'comment_remove',
        'comment.attach' => 'comment_attach',
        'attachment.add' => 'attachment_add', 'attachment.list' => 'attachment_list',
        'attachment.get' => 'attachment_get', 'attachment.remove' => 'attachment_remove',
        'attachment.detach' => 'attachment_detach',
        'attachment.discard' => 'attachment_discard',
        'evidence.list' => 'evidence_list', 'evidence.add' => 'evidence_add',
        'evidence.annotate' => 'evidence_annotate',
        'gate.list' => 'gate_list', 'gate.add' => 'gate_add',
        'gate.annotate' => 'gate_annotate',
        'checklist.list' => 'checklist_list', 'checklist.add' => 'checklist_add',
        'checklist.update' => 'checklist_update',
        'search' => 'search', 'search.index' => 'search_index', 'dashboard' => 'dashboard',
        'dashboard.sow' => 'dashboard', 'dashboard.epic' => 'dashboard', 'dashboard.ticket' => 'dashboard',
    );
    my $method = $method{$command} or die "Unsupported Tira command '$command'\n";
    $args{person} = $option->{people}[0] if $command =~ /\Aassign\.(?:add|remove)\z/ && $option->{people};
    $args{people} = $option->{people} // [] if $command eq 'assign.set';
    $args{recursive} = $option->{recursive} if $command eq 'hierarchy.show';
    if ( $command =~ /\Adashboard(?:\.(sow|epic|ticket))?\z/ ) {
        $args{type} = $1 if defined $1;
        # Every board is created with Backlog and Discard, and the
        # owner saw one and never the other. A person looking at a board should
        # see where discarded work went; the ref-only path an agent queries is
        # untouched, so nobody pays for cards they did not ask about.
        $args{include_discard} = $option->{include_discard}
          // ( $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/ );
        $args{summary} = $option->{output} ne 'json';
        $args{with_title} = defined $option->{title};

        # A board somebody is looking at must show which cards are waiting,
        # whether or not they asked for titles. The ref-only path an agent
        # queries stays untouched.
        $args{with_questions} = $option->{with_questions}
          // ( $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/ );
        $args{include_mtime} = $option->{include_mtime} || $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/;
    }
    $args{include_deleted} = $option->{include_deleted} if $command eq 'attachment.list';
    $args{questions} = $option->{questions} if $command eq 'attachment.list' && $option->{questions};
    if ( $command =~ /\Acomment\.(?:add|update)\z/ && defined $option->{file} ) {
        die "Use only one of --text or --file\n" if defined $option->{text};
        $args{text} = _text_input( $option->{file}, utf8 => 1 );
    }
    if ( $command eq 'comment.add' && $option->{attach} ) {
        my $comment = $tira->$method(%args);
        $tira->comment_attach( %args, comment => $comment->{id}, file => $_ ) for @{ $option->{attach} };
        return $tira->comment_list(%args)->[-1];
    }
    return $tira->$method(%args);
}

# Police keeps its state outside the project it watches, so that it can never
# become a second writer to the board - which is what destroyed this project's
# own board on the day the subsystem was designed.
sub _police_store {
    my ($project) = @_;
    my $home = $ENV{HOME} // File::Spec->tmpdir;
    my $slug = defined $project ? $project : 'here';
    $slug =~ s/[^A-Za-z0-9]+/-/g;
    $slug =~ s/\A-|-\z//g;
    return File::Spec->catdir( $home, '.tira-police', $slug );
}

# The world police needs and the engine will not touch. Gathered here, handed
# in as plain facts, so that Tira itself still invokes no shell.
#
# It used to return five empty lists and nothing else. Six declared rules read
# this - leftover-process, leftover-container, commit-without-card,
# work-without-card, unpushed-work and board-unbacked - and every one of them
# evaluated against nothing and stayed silent. A rule that is silent because it
# was shown nothing looks exactly like a rule being obeyed, which is the very
# sentence police prints to the owner when a rule is missing entirely. Found on
# 2026-08-12, when board-unbacked said the board had never been backed up while
# the backups the push gate writes sat in ~/.tira-backups.
sub _police_world {
    my (%args) = @_;
    my $root = $args{project};
    my $where = defined $root && -d $root ? $root : undef;

    my $world = {
        branches   => _git_branches($where),
        worktrees  => _git_worktrees($where),
        processes  => _running_processes(),
        containers => _running_containers(),
        commits    => _unpushed_commits($where),
    };
    $world->{unpushed_since} = @{ $world->{commits} } ? $world->{commits}[-1]{at} : undef;
    $world->{working_since} = _tree_changing_since($where);
    $world->{backed_up_at} = _last_backup( $args{backups} // _backup_home($where) );
    $world->{card_in_progress} = exists $args{card_in_progress}
      ? $args{card_in_progress}
      : _card_in_progress( $args{tira}, $root );
    return $world;
}

# Whether anything on the board is being worked. work-without-card asks it the
# other way round - a tree that is changing while nothing is at a working gate
# is work nobody can see - so getting this wrong makes that rule accuse the
# agent of exactly what it is in the middle of doing properly.
sub _card_in_progress {
    my ( $tira, $root ) = @_;
    return undef if !$tira || !defined $root;
    my $working = 0;
    for my $type (qw(sow epic ticket)) {
        my $roles = eval { $tira->column_roles( project => $root, type => $type ) } || {};
        my $records = eval { $tira->record_list( project => $root, type => $type ) } || [];
        my $moving = $roles->{'in-progress'};
        for my $record ( @{$records} ) {
            my $column = $record->{column} // '';
            $working++, last
              if defined $moving
              ? $column eq $moving
              : $column !~ /\A(?:backlog|done|discard)\z/;
        }
        last if $working;
    }
    return $working ? 1 : 0;
}

# Every external command runs through here, in list form so no shell is
# involved even in this module - a card title with a semicolon in it is a
# perfectly ordinary card title. A command that is not installed is not a
# failure: a machine with no Docker has no leftover containers.
sub _reading {
    my (@command) = @_;

    # List form: the program is named separately from its arguments, so this is
    # always "run this program" and never "ask a shell what was meant" - a card
    # title with a semicolon in it is an ordinary card title. A program that is
    # not installed is not a failure either: a machine with no Docker has no
    # leftover containers, and everything else carries on being watched.
    # Asked for by name first. Perl warns "Can't exec" when a program is not
    # there, and a machine with no Docker is not an error worth printing into
    # the middle of whatever the owner was reading.
    return [] if !_program_exists( $command[0] );

    my @lines;
    if ( open my $handle, '-|', @command ) {
        @lines = <$handle>;
        close $handle;
    }
    chomp @lines;
    return \@lines;
}

sub _program_exists {
    my ($program) = @_;
    return -x $program ? 1 : 0 if $program =~ m{[/\\]};
    for my $directory ( File::Spec->path ) {
        return 1 if -x File::Spec->catfile( $directory, $program );
    }
    return 0;
}

# Asking git about somewhere that is not a repository makes git say so, on
# standard error, in the middle of whatever the owner was reading. Nothing here
# silences it, because silencing the whole program's standard error would take
# it away from whoever else was using it - a test capturing it, most obviously.
# So it is not provoked in the first place.
sub _is_repository {
    my ($where) = @_;
    return 0 if !defined $where;
    my $here = abs_path($where) // $where;
    my $last = '';
    while ( $here ne $last ) {
        return 1 if -e File::Spec->catfile( $here, '.git' );
        ( $last, $here ) = ( $here, dirname($here) );
    }
    return 0;
}

# -C rather than chdir, so the whole of this module stays in one directory and
# nothing has to be put back afterwards.
sub _git_branches {
    my ($where) = @_;
    return [] if !_is_repository($where);
    return _reading( 'git', '-C', $where, 'branch', '--format=%(refname:short)' );
}

sub _git_worktrees {
    my ($where) = @_;
    return [] if !_is_repository($where);
    return [ map { s/\Aworktree\s+//r } grep { /\Aworktree\s/ }
          @{ _reading( 'git', '-C', $where, 'worktree', 'list', '--porcelain' ) } ];
}

# The process table, with when each one started, because every rule about a
# leftover asks how long it has been there rather than whether it exists.
sub _running_processes {
    return _processes_from( _reading( 'ps', '-eo', 'pid=,lstart=,args=' ) );
}

# Reading the table is kept apart from asking for it, so what this understands
# can be proved against real ps output on a machine where the answer is known.
sub _processes_from {
    my ($lines) = @_;
    my @processes;
    for my $line ( @{$lines} ) {
        next if $line !~ /\A\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)\z/;
        my ( $pid, $started, $command ) = ( $1, $2, $3 );
        next if $pid == $$;
        push @processes,
          { pid => $pid, started_at => _stamp_from_ps($started), command => $command };
    }
    return \@processes;
}

sub _stamp_from_ps {
    my ($text) = @_;
    my %month = do { my $n = 0; map { $_ => ++$n } qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) };
    return undef if $text !~ /\A\w{3}\s+(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d{4})\z/;
    return undef if !$month{$1};
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02d', $6, $month{$1}, $2, $3, $4, $5;
}

sub _running_containers {
    return _containers_from(
        _reading( 'docker', 'ps', '--format', '{{.Names}}\t{{.CreatedAt}}' ) );
}

# Kept apart from asking Docker for the same reason: the suite runs inside a
# container with no Docker in it, so asking would prove nothing about whether
# the answer is understood. This is proved against real docker ps output.
sub _containers_from {
    my ($lines) = @_;
    my @containers;
    for my $line ( @{$lines} ) {
        my ( $name, $created ) = split /\t/, $line, 2;
        next if !defined $name || $name eq '';
        push @containers, { name => $name, started_at => _stamp_from_docker($created) };
    }
    return \@containers;
}

sub _stamp_from_docker {
    my ($text) = @_;
    return undef if !defined $text;
    return $text =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/
      ? "$1-$2-$3T$4:$5:$6"
      : undef;
}

# Where this branch was last pushed to. Asking git for @{upstream} was the
# obvious way and the wrong one: this very repository has origin/master and one
# unpushed commit, and no upstream configured for the branch - so git answered
# "fatal: no upstream configured", loudly, on somebody else's terminal, and
# both rules that depend on this went quiet on the one board that most needed
# them. --verify --quiet asks without complaining, and the remote the branch
# names is tried when the usual one is not there.
sub _tracking_branch {
    my ( $where, $branch ) = @_;
    my ($configured) =
      @{ _reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', '--verify', '--quiet',
            "$branch\@{upstream}" ) };
    return $configured if defined $configured && $configured ne '';

    my @remotes = ('origin');
    my ($named) = @{ _reading( 'git', '-C', $where, 'config', '--get', "branch.$branch.remote" ) };
    unshift @remotes, $named if defined $named && $named ne '';
    for my $remote (@remotes) {
        my ($found) = @{ _reading( 'git', '-C', $where, 'rev-parse', '--verify', '--quiet',
                "$remote/$branch" ) };
        return "$remote/$branch" if defined $found && $found ne '';
    }
    return undef;
}

# Commits this branch has and the branch it is pushed to does not. Nowhere to
# have been pushed means nothing is sitting unpushed - a branch nobody has ever
# pushed is not the same as work left waiting.
sub _unpushed_commits {
    my ($where) = @_;
    return [] if !_is_repository($where);
    my ($branch) = @{ _reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', 'HEAD' ) };
    return [] if !defined $branch || $branch eq '' || $branch eq 'HEAD';
    my $upstream = _tracking_branch( $where, $branch );
    return [] if !defined $upstream || $upstream eq '';
    my $lines = _reading( 'git', '-C', $where, 'log', '--format=%H%x09%cI%x09%s', "$upstream..HEAD" );
    return [ map { my ( $sha, $at, $subject ) = split /\t/, $_, 3;
            { sha => $sha, at => $at, subject => $subject // '' } } @{$lines} ];
}

# When the working tree last changed, which is what work-without-card means by
# work. A clean tree is not work in progress, so it answers with nothing.
sub _tree_changing_since {
    my ($where) = @_;
    return undef if !_is_repository($where);
    my $changed = _reading( 'git', '-C', $where, 'status', '--porcelain' );
    return undef if !@{$changed};
    my $oldest;
    for my $line ( @{$changed} ) {
        next if $line !~ /\A.{3}(.+)\z/;
        my $path = File::Spec->catfile( $where, $1 );
        next if !-e $path;
        my $when = ( stat $path )[9];
        $oldest = $when if !defined $oldest || $when < $oldest;
    }
    return undef if !defined $oldest;
    my @when = gmtime $oldest;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $when[5] + 1900, $when[4] + 1, @when[ 3, 2, 1, 0 ];
}

# Where tools/board-backup writes: one directory per project, named for the
# absolute path so two projects on one machine never write over each other.
sub _backup_home {
    my ($where) = @_;
    return undef if !defined $where;
    my $home = $ENV{HOME} // $ENV{USERPROFILE};
    return undef if !defined $home;
    my $slug = abs_path($where) // $where;
    $slug =~ s/[^A-Za-z0-9]+/-/g;
    $slug =~ s/\A-|-\z//g;
    return File::Spec->catdir( $home, '.tira-backups', $slug );
}

# The most recent backup, read from the stamp in its name. The newest one is
# the only one the rule cares about - it asks how long it has been since the
# last one, not how many there have ever been.
sub _last_backup {
    my ($directory) = @_;
    return undef if !defined $directory || !-d $directory;
    opendir my $handle, $directory or return undef;
    my @stamps = sort grep { /\A\d{8}T\d{6}Z\z/ } readdir $handle;
    closedir $handle;
    return undef if !@stamps;
    return $stamps[-1] =~ /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/
      ? "$1-$2-$3T$4:$5:$6Z"
      : undef;
}

# A loop that never ends cannot be called by anything, including a test - so
# the number of rounds and the waiting are both injectable. Left alone it runs
# for ever, which is what an agent tailing a bridge wants.
sub _bridge_follow {
    my ( $tira, $store, %args ) = @_;
    my $rounds = $args{rounds};
    my $wait = $args{sleeper} || sub { sleep $_[0] if $_[0] };
    my $every = defined $args{interval} ? $args{interval} : 2;
    my $path = $tira->bridge_log_path( store => $store );

    # Counted through the same filter the agent reads through, or a line
    # written for somebody else would advance the mark and swallow the next
    # line that was actually for this one.
    my %narrow = ( store => $store, lines => 1_000_000,
        ( defined $args{agent} ? ( agent => $args{agent} ) : () ) );
    my $seen = -f $path ? scalar @{ $tira->bridge_backlog(%narrow) } : 0;
    my $done = 0;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        $wait->($every);
        my $all = $tira->bridge_backlog(%narrow);
        next if @{$all} <= $seen;
        print map { "$_\n" } @{$all}[ $seen .. $#{$all} ];
        $seen = scalar @{$all};
    }
    return $seen;
}

sub _police_follow {
    my ( $tira, $args, $store, $option ) = @_;
    my $interval = defined $option->{interval} ? $option->{interval} : 30;
    my $rounds = $option->{rounds};
    my $wait = $option->{sleeper} || sub { sleep $_[0] if $_[0] };

    # A supervisor that dies quietly is worse than none, because its silence
    # reads as everything being fine.
    # How it leaves is injectable, so that what it says on the way out can be
    # proved by calling the handler rather than by killing the process - a
    # handler nothing has ever run is a handler nobody knows works.
    my $leave = $option->{leave} || sub { exit 0 };
    for my $signal (qw(INT TERM HUP)) {
        $SIG{$signal} = sub { _police_goodbye( $tira, $signal ); $leave->() };
    }
    my $done = 0;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        # Gathered every round, not once at the start: a container that comes up
        # an hour into a watch is exactly the kind of thing this is for.
        my $result = eval {
            $tira->police_pass( %{$args}, store => $store,
                world => _police_world( tira => $tira, project => $tira->discover_project( %{$args} ) ) );
        };
        if ( !$result ) {
            # Transient trouble is not a reason to stop watching.
            print {*STDERR} 'police could not read the board: ' . ( $@ || 'unknown' ) . "\n";
        }
        else {
            $tira->bridge_write( store => $store, violations => $result->{violations} );
            print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
        }
        $wait->($interval);
    }
    return { rounds => $done };
}

# Split out from the signal handler so that what police says on its way out can
# be called and checked, rather than only reached by killing the process.
sub _police_goodbye {
    my ( $tira, $signal ) = @_;
    print {*STDERR} $tira->police_farewell( reason => "signal $signal" ) . "\n";
    return 1;
}

sub _policy_help {
    my (%args) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return '';
    my $doc = $args{document}
      // File::Spec->catfile( dirname( dirname( dirname($1) ) ), 'docs', 'POLICIES.md' );
    if ( -f $doc && open my $fh, '<:raw', $doc ) {
        my $text = do { local $/; <$fh> };
        close $fh;
        return $text;
    }
    return _policy_help_fallback();
}

# Said when the document is not there. An installation missing its docs should
# still be able to tell an agent what exists, rather than answering nothing.
sub _policy_help_fallback {
    return join "\n",
      'Tira policies',
      '',
      'Rules: ' . join( ', ', @{ Tira::policy_rules() } ),
      'Actions: ' . join( ', ', @{ Tira::policy_actions() } ),
      '',
      'Declare one:  d2 tira.policy.add --rule <rule> --action <action> [parameters]',
      'See them:     d2 tira.policy.list',
      'Watch:        d2 tira.police            (the owner runs this)',
      'Listen:       d2 tira.policy.bridge     (the agent runs this)',
      '';
}

sub _text_input {
    my ( $file, %args ) = @_;
    my $fh;
    if ( $file eq '-' ) {
        $fh = *STDIN;
    }
    else {
        open $fh, '<:raw', $file or die "Cannot read '$file': $!\n";
    }
    my $content = do { local $/; <$fh> };
    close $fh if $file ne '-';
    return $args{utf8} ? decode( 'UTF-8', $content, FB_CROAK ) : $content;
}

sub _json_array_input {
    my ($file) = @_;
    my $data = Tira::json_decode( _text_input($file) );
    die "Replacement input must be a JSON array\n" if ref($data) ne 'ARRAY';
    return $data;
}

sub _error {
    my ( $tira, $output, $message ) = @_;
    $message =~ s/\s+\z//;
    my $formatted = eval { $tira->format_output( { error => $message }, output => $output ) };
    $formatted = Tira::json_object()->canonical->pretty->encode( { error => $message } ) if !defined $formatted;
    print STDERR _utf8_bytes($formatted);
    return 2;
}

sub _utf8_bytes {
    my ($text) = @_;
    return utf8::is_utf8($text) ? encode_utf8($text) : $text;
}

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: dashboard tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';
    return "Usage: dashboard tira.$type.create --title TITLE [record field options] [-o toon|json|human]\n"
      if defined $type;
    return "Usage: dashboard tira.$command [options] [-o toon|json|human]\n";
}

1;

__END__

=head1 NAME

Tira::CLI - Shared command boundary for Tira DD commands

=head1 DESCRIPTION

Parses the common project and record metadata options, invokes L<Tira>, and
applies the TOON-first output and structured error contract. Project-location
selection is intentionally omitted from user-facing help. Text input is decoded
strictly as UTF-8 and structured output is emitted as UTF-8 bytes; attachment
content remains raw. Dashboard commands additionally support self-contained
HTML and validated Dancer2 browser serving.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

=cut
