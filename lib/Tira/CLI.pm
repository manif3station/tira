package Tira::CLI;

use strict;
use warnings;

use Encode qw(decode encode_utf8 FB_CROAK LEAVE_SRC);
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

# The option guard - %MISLEADING_OPTIONS, %OPTION_READ_BY and the refusal that
# enforces them - lives in Tira::CLI::Options. Lifted on TKT-837 to make room
# under t/430's cap, and loaded with require at the points that read it.
#
# THE NAME STAYS HERE. _refuse_unread_options keeps a forwarder in this package
# rather than being called at its new address, because three test files disable
# the guard by localising *Tira::CLI::_refuse_unread_options to prove what the
# refusal is worth - t/237, t/252 and others. Calling the lifted sub directly
# moved the name out from under them, and the override silently stopped
# overriding: the guard still fired, the command still refused, and the tests
# failed claiming the code had regressed. A lift must not change what a caller
# can reach, which is the same rule the Tasklist lift followed on TKT-832.
sub _refuse_unread_options {
    require Tira::CLI::Options;
    goto &Tira::CLI::Options::_refuse_unread_options;
}

# The process that set a served board up, recorded before the server forks.
# Outside a served board it is simply this process, so a plain command asking
# the question gets the honest answer rather than a special case.
our $SERVING_PID;

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
    # Left undefined here on purpose, and resolved where they are USED. What they
    # name lives in Tira::CLI::Serve, which most runs never need, so a bare
    # \&Package::sub taken here would either load that module on every
    # invocation or dangle - and dangling is what happened once already:
    # \&_serve_browser survived the move as a reference nothing had rewritten,
    # because a code reference is not a call and every check was looking for
    # calls.
    #
    # The obvious fix was a closure per default that required the module and
    # delegated. It works and it is lazy, and it cost 100% coverage: two of the
    # three were never called by any test, because every test that serves a
    # board passes its own. A closure is a subroutine with statements in it; a
    # code reference resolved inside an expression is neither. So each default
    # is now taken at its call site, after a require that actually runs there.
    # TKT-607.
    my $browser_server         = $args{browser_server};
    my $onboard_browser_server = $args{onboard_browser_server};

    # The same kind of seam as browser_server above, and for the same reason.
    # Starting police beside the board FORKS, and a forked child that runs the
    # watch loop does not return - so a test exercising this path without a seam
    # would leave a police daemon running inside the harness. TKT-897.
    my $police_starter = $args{police_starter};
    my $police_stopper = $args{police_stopper};
    my $restarter              = $args{restarter};
    my $guided_input = $args{input};
    my %option = ( output => 'toon' );
    our @RESTART_ARGV = @{$argv};
    my $environment_project;
    my $decoded = eval {
        for my $argument ( @{$argv} ) {
            $argument = decode( 'UTF-8', $argument, FB_CROAK ) if !utf8::is_utf8($argument);
        }
        # LEAVE_SRC, because decode consumes what it is given. Reading the
        # environment used to empty it, and it did not matter while a flag
        # could carry the board instead: the first command in a process took
        # the value and every command after it in that process saw an empty
        # string. With one way to name a board there is nothing to fall back
        # on, and a suite that runs many commands in one process finds it at
        # once - which is how this was found. TKT-250.
        if ( defined $ENV{TIRA_HOME} ) {
            $environment_project = utf8::is_utf8( $ENV{TIRA_HOME} )
              ? $ENV{TIRA_HOME}
              : decode( 'UTF-8', $ENV{TIRA_HOME}, FB_CROAK | LEAVE_SRC );
        }
        1;
    };
    return _error( $tira, 'toon', $@ || 'Invalid UTF-8 command-line input' ) if !$decoded;
    my @spec = (
        'name=s' => \$option{name}, 'dir=s' => \$option{dir}, 'title:s' => \$option{title},
        'description=s' => \$option{description},
        'output|o=s' => \$option{output}, 'help' => \$option{help},
        'id=s' => \$option{id}, 'email=s' => \$option{email},
        'message=s' => \$option{message}, 'all' => \$option{all},
        # Repeated jobs (EPC-014, TKT-837). 'schedule' and 'enabled' are new
        # names. 'command' is NOT declared here: it already exists above as
        # 'command=s@' for required-action proofs, and declaring it twice is
        # exactly what t/450 refuses - Getopt::Long prints "Duplicate
        # specification" to STDERR on every invocation. Tira::CLI::Job reads
        # the existing array form instead.
        'schedule=s' => \$option{schedule}, 'enabled=s' => \$option{enabled},
        # How often a monitor expects to speak, in minutes. TKT-863, his answer
        # to Q-115. Empty means no expectation, which the dashboard shows dim.
        'expect-every=s' => \$option{expect_every},
        # How long to wait before running a monitor's command again when it
        # ends. TKT-891, his voice 6694 - so nobody types a while loop.
        'restart-every=s' => \$option{restart_every},
        'columns-json=s' => \$option{columns_json},
        'nested' => \$option{nested},
        'mark=s' => \$option{mark},
        'reason=s' => \$option{reason}, 'option=s@' => \$option{options},
        'voice=s' => \$option{voice}, 'remove' => \$option{remove}, 'caller-kind=s' => \$option{caller_kind},
        'question=s@' => \$option{questions}, 'filename=s' => \$option{filename},

        # Both of these were documented and neither could be passed: the
        # dashboard read with_questions from an option nothing ever set, and
        # card-sandbox-missing needs a sandbox the command line could not
        # take. Found by widening the documentation check to read the argument
        # tables, which is where almost every flag here is written down.
        'with-questions!' => \$option{with_questions},
        'no-session-expire' => \$option{no_session_expire},
        'show-logs' => \$option{show_logs},
        'with-police' => \$option{with_police},
        'ssl' => \$option{ssl},
        'sandbox=s' => \$option{sandbox},
        'repo=s' => \$option{repo}, 'repair!' => \$option{repair},
        'collector=s' => \$option{collector}, 'agent=s' => \$option{agent},
        'session=s' => \$option{session}, 'heartbeat=s' => \$option{heartbeat},
        'all-sessions' => \$option{all_sessions},
        'unlinked' => \$option{unlinked},
        'repeated-reason=s' => \$option{repeated_reason},
        'repeated-confirm=s' => \$option{repeated_confirm},
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
        'chat=s' => \$option{chat},
        'author=s' => \$option{author}, 'file=s@' => \$option{files},
        'format=s' => \$option{format}, 'comment=s' => \$option{comment},
        'sha=s' => \$option{sha}, 'extension=s' => \$option{extension},
        'summary=s' => \$option{summary}, 'uri=s' => \$option{uri},
        'gate=s' => \$option{gate}, 'result=s' => \$option{result},
        'details=s' => \$option{details}, 'evidence=s' => \$option{evidence},
        'item=s' => \$option{item}, 'status=s' => \$option{status},
        'peek' => \$option{peek},
        'command=s@' => \$option{command}, 'proof=s@' => \$option{proof},
        'field=s@' => \$option{fields}, 'pattern=s' => \$option{pattern},
        'fields=s@' => \$option{field_selection},
        'exclude-fields=s@' => \$option{exclude_fields},
        'include-empty' => \$option{include_empty},
        'since=s' => \$option{since},
        'if-changed=s' => \$option{if_changed},
        'count' => \$option{count}, 'refs-only' => \$option{refs_only},
        'tasklist' => \$option{tasklist},
        'brief' => \$option{brief}, 'truncate=i' => \$option{truncate},
        'last=i' => \$option{last}, 'first=i' => \$option{first},
        'position=i' => \$option{position},
        'attach=s@' => \$option{attach}, 'sort=s' => \$option{sort},
        'meta-only' => \$option{meta_only},
        'where=s@' => \$option{where},
        'members=s@' => \$option{members}, 'columns=s@' => \$option{columns},
        'listen=s' => \$option{listen},
        'password=s' => \$option{password},
        'rule=s' => \$option{rule}, 'action=s' => \$option{action},
        'enter=s' => \$option{enter}, 'before-column=s' => \$option{before_column},
        'age=s' => \$option{age}, 'read-age=s' => \$option{read_age},
        'max=i' => \$option{max}, 'require=s' => \$option{require},
        'once' => \$option{once}, 'interval=i' => \$option{interval},
        'fresh' => \$option{fresh},

        # An exit status a scheduled job can act on, and a work list rather
        # than a data dump. Both opt-in: a command that starts exiting
        # non-zero breaks every script running it today, and the precedent for
        # a status carrying an answer is --if-changed. TKT-279.
        # Named by-rule rather than summary: --summary already belongs to
        # evidence.add, and Getopt::Long answers a duplicate specification with
        # a warning printed into the output, which turned a JSON payload into
        # something no caller could parse. The suite said so twice at once.
        'exit-nonzero-if-any' => \$option{exit_nonzero_if_any},
        'by-rule' => \$option{by_rule},

        # Agreeing to lose work. Spelled out rather than a single letter,
        # because the one command that can destroy a board should not be
        # reachable by a slip of the hand.
        'yes' => \$option{yes},
        'claiming-schema=i' => \$option{claiming_schema},
        'seconds=i' => \$option{seconds},
        'pid=i' => \$option{pid},
        'on-column=s' => \$option{on_column},
        'role=s@' => \$option{roles}, 'remove-role=s@' => \$option{remove_roles},
        'gate-name=s@' => \$option{gate_names},
        'require-link=s' => \$option{require_link}, 'link-to=s' => \$option{link_to},
        'notify' => \$option{notify},
        'enter-role=s' => \$option{enter_role}, 'before-role=s' => \$option{before_role},

        # The third of the three the command reference offers. It was
        # documented beside the other two and never in this list, so
        # policy.add answered "Unknown option: column-role" and refused the
        # whole command - while the engine declared the field and evaluated it
        # in the same loop as its neighbours. Only the way to give it a value
        # was missing. TKT-221.
        'column-role=s' => \$option{column_role},
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
        'said=s' => \$option{said}, 'heard=s' => \$option{heard},
        'agent-session=s' => \$option{agent_session},
        'watch!' => \$option{watched}, 'terminal!' => \$option{terminal}, 'stale' => \$option{stale},
        'queue!' => \$option{queue}, 'required-action=s@' => \$option{required_action}, 'blocking' => \$option{blocking},
        'entry-required-action=s@' => \$option{entry_required_action},
        'administrative-action=s@' => \$option{administrative_action}, 'next=s@' => \$option{next},
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
        'exempt-required=s@' => \$option{required_exempt}, 'exempt-reason=s@' => \$option{exempt_reason},
        'acceptance|acceptance-criteria=s@' => \$option{acceptance}, 'test-step=s@' => \$option{test_steps},
        'bdd=s@' => \$option{bdd}, 'atdd=s@' => \$option{atdd},
        'assignee=s' => \$option{assignee}, 'person=s@' => \$option{people},
        'affects-version=s@' => \$option{affects_versions},
        'set-key-details=s' => \$option{set_key_details},
        'set-deliverables=s' => \$option{set_deliverables},
        'set-acceptance|set-acceptance-criteria=s' => \$option{set_acceptance},
        'set-test-steps=s' => \$option{set_test_steps},
        'set-bdd=s' => \$option{set_bdd}, 'set-atdd=s' => \$option{set_atdd},
        'set-labels=s' => \$option{set_labels},
        'set-affects-versions=s' => \$option{set_affects_versions},
        'set-scope-in=s' => \$option{set_scope_in},
        'set-scope-out=s' => \$option{set_scope_out},
    );

    # TKT-389: a single-valued option given twice on the same command line
    # silently kept the last value and dropped the rest, with exit 0 - for
    # --priority in particular a card meant to be P5 lands as P1, and the
    # surviving value is what the output prints, so it reads as success.
    # Guarded once here, generically, over every spec that takes a value and
    # is not itself repeatable (no '@'): the 94 against 25 the ticket counted
    # would otherwise have been 94 places to keep in step by hand.
    my @duplicate_option;
    my %already_given;
    for ( my $i = 0; $i < @spec; $i += 2 ) {
        my $spec_str = $spec[$i];
        next if $spec_str =~ /\@/;
        next if $spec_str !~ /[=:]/;
        ( my $primary = $spec_str ) =~ s/[|=:!].*//;
        my $target = $spec[ $i + 1 ];
        $spec[ $i + 1 ] = sub {
            my ( undef, $value ) = @_;

            # A default such as output => 'toon' is set in %option before
            # parsing even starts, so "the target already holds a value" is
            # not the same question as "this flag was already given" - the
            # first --output on a command line must not be read as a second
            # occurrence of one that was never actually typed.
            push @duplicate_option,
              "--$primary was given more than once ('" . $$target . "' and '$value')"
              if $already_given{$primary}++;
            $$target = $value;
        };
    }
    # An unknown COMMAND already gets "Did you mean" - the dispatcher this
    # project sits inside supplies that. An unknown OPTION got only "Unknown
    # option: X" straight from Getopt::Long, discarded into a generic
    # "Invalid command-line options" with nothing suggested - the same help a
    # command typo gets, missing for the far more common typo of a flag.
    # TKT-298: one bad option name discarded a whole update carrying twenty
    # composed fields, and finding which flag was wrong cost writing a probe
    # value into a live card. Getopt::Long only warns to STDERR, so its own
    # unknown-option text is captured here rather than re-derived.
    my $unknown_option_warning = '';
    my $parsed = do {
        local $SIG{__WARN__} = sub { $unknown_option_warning .= $_[0] };
        GetOptionsFromArray( $argv, @spec );
    };
    return _error( $tira, $option{output},
        join( '; ', @duplicate_option )
          . " - repeating a single-valued option drops every value but the last silently. Give it once.\n" )
      if @duplicate_option;
    if ( !$parsed || @{$argv} ) {
        my @unknown = $unknown_option_warning =~ /Unknown option:\s*(\S+)/g;
        require Tira::CLI::Usage;
        return _error( $tira, $option{output}, Tira::CLI::Usage::_unknown_option_message( \@unknown, \@spec ) )
          if @unknown;

        # Any other Getopt::Long complaint - a value missing, one of the
        # wrong type - used to reach STDERR unfiltered, since nothing
        # installed a $SIG{__WARN__} before this. Capturing the unknown-
        # option case above must not silence these too; printed here so the
        # diagnostic Getopt::Long already wrote is not simply discarded.
        print {*STDERR} _utf8_bytes($unknown_option_warning) if $unknown_option_warning ne '';
        return _error( $tira, $option{output}, 'Invalid command-line options' );
    }

    # --file is a list only where a batch makes sense, and one file everywhere
    # else. Nine commands read it - attachment, question voice and answer, bulk
    # import, comment add and update among them - so handing eight of them an
    # arrayref and fixing each with ->[0] would be eight places to drift, which
    # is the fault TKT-389 is about. Collapsed once, here.
    #
    # Giving it twice used to keep the last and discard the rest with exit 0.
    # That is one of the single-valued flags TKT-389 counts, closed here because
    # this card had to touch the option anyway; the rest stay on that card.
    # TKT-338.
    if ( $option{files} ) {
        return _error( $tira, $option{output},
            "Only attachment.add, tasklist.task.attach.add and tasklist.task.attach.discard take more than one --file\n" )
          if @{ $option{files} } > 1
          && $command !~ /\A(?:attachment\.add|tasklist\.task\.attach\.(?:add|discard))\z/;
        $option{file} = $option{files}[0];
    }
    $option{ref} = $option{ref_list}[-1] if $option{ref_list};
    $option{$_} = _expand_home( $option{$_} ) for grep { defined $option{$_} } qw(dir project);

    # job.help joins policies here rather than going to Tira::CLI::Job with the
    # other job verbs, because it is the same KIND of thing as tira.policies: a
    # document printed whole, not a command that touches a board. Routing it
    # through the job dispatcher would have meant a verb taking no --id, no
    # --schedule and no project, sitting beside seven that do. TKT-886.
    #
    if ( $option{help} || $command eq 'policies' || $command eq 'job.help' ) {
        require Tira::CLI::Usage;
        print $command eq 'policies' ? Tira::CLI::Usage::_policy_help()
          : $command eq 'job.help'   ? Tira::CLI::Usage::_job_help()
          :                            Tira::CLI::Usage::_usage( $command, $type );
        return 0;
    }

    return _error( $tira, 'toon', "Unsupported output format '$option{output}' - "
        . '--output/-o names the response FORMAT (toon, json or human) on every command here, '
        . 'never a destination path. attachment.get always writes its raw content to stdout, '
        . "so save it with shell redirection: > FILE" )
      if $command eq 'attachment.get' && $option{output} !~ /\A(?:toon|json|human)\z/;
    return _error( $tira, 'toon', 'Table output is available only for dashboard commands' )
      if $option{output} eq 'table' && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;
    return _error( $tira, 'toon', 'Browser output is available only for dashboard and onboard commands' )
      if $option{output} =~ /\Abrowser(?:=|\z)/
      && $command !~ /\A(?:dashboard(?:\.(?:sow|epic|ticket))?|onboard)\z/;

    # One way to say which board: the environment, holding a name the machine
    # resolves. There were three - a flag, this, and the working directory -
    # and three ways to say one thing is three behaviours to keep in agreement.
    # They had already stopped agreeing. The internal name stays because the
    # engine is told which board it is working on and always was. TKT-250.
    $option{project} = $environment_project;

    # --show-logs only means anything to a served board: the record it turns on
    # is read through /logs by a page, and there is no page in any other output
    # format. Accepted-and-ignored is the fault this file refuses everywhere
    # else - a flag that parses and does nothing reads as confirmation, which is
    # how --field was stored and dropped by every command that did not read it.
    # Refused by name rather than defaulted away from. EPC-007, TKT-852.
    die "--show-logs needs -o browser: the record it keeps is read through the "
      . "page the board serves, and there is no page in '$option{output}'\n"
      if $option{show_logs} && $option{output} !~ /\Abrowser(?:=|\z)/;

    # --with-police is refused outside a served board for the same reason, and
    # the reason is worth repeating rather than pointing at: the flag's whole
    # purpose is that ONE TERMINAL carries the board and the bridge. A JSON dump
    # exits immediately, so there is no terminal to share and nothing for police
    # to run alongside - the flag would parse, do nothing, and read as
    # confirmation that it had worked. His words are about terminals: "So the
    # user doesn't need to run 2 terminals. All in 1 go." EPC-014, TKT-897.
    die "--with-police needs -o browser: it runs police alongside the served "
      . "board so one terminal carries both, and '$option{output}' does not "
      . "serve anything to run alongside\n"
      if $option{with_police} && $option{output} !~ /\Abrowser(?:=|\z)/;

    my ( $browser_host, $browser_port );
    if ( $option{output} =~ /\Abrowser(?:=(.*))?\z/ ) {
        my $given = $1;
        if ( $command eq 'onboard' ) {
            # No project exists yet, so there is no remembered address to fall
            # back to - and a fixed default port would collide the moment two
            # projects tried to onboard at once. 127.0.0.1 rather than
            # 0.0.0.0: this is a disposable setup session, not a board meant
            # to be reached from another machine. 0.0.0.0 is refused outright
            # here, not merely defaulted away from - unlike tira.dashboard,
            # Tira::OnboardWeb has no login at all (by design: one submission
            # and done), so a network-reachable onboard session would be a
            # genuinely unauthenticated project-creation endpoint. TKT-527.
            ( $browser_host, $browser_port ) = ( '127.0.0.1', undef );
            if ( defined $given && length $given ) {
                return _error( $tira, 'toon',
                    "Unsupported browser endpoint '$given' - onboard has no login, so 0.0.0.0 is refused; use 127.0.0.1 or localhost\n" )
                  if $given =~ /\A0\.0\.0\.0(?::[0-9]+)?\z/;
                ( $browser_host, $browser_port ) = $given =~ /\A(127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
                  or return _error( $tira, 'toon', "Unsupported browser endpoint '$given'\n" );
            }
            require Tira::CLI::Serve;
            $browser_port = Tira::CLI::Serve::_free_port() if !defined $browser_port;
        }
        else {
            # Precedence, stated once: an address on the command line wins, the
            # project's remembered address is next, the original default last.
            my $endpoint = defined $given && length $given ? $given : do {
                my $stored = eval { $tira->project_show( project => $option{project} )->{dashboard} };
                join ':', ( $stored->{host} // '0.0.0.0' ), ( $stored->{port} // 7899 );
            };
            require Tira::CLI::Serve;
            my $valid = eval {
                ( $browser_host, $browser_port ) = Tira::CLI::Serve::_browser_endpoint($endpoint);
                1;
            };
            return _error( $tira, 'toon', $@ || 'Invalid browser endpoint' ) if !$valid;
        }
    }

    # tira.onboard -o browser skips the interactive STDIN wizard entirely: a
    # disposable server collects the same answers over HTTP instead, then
    # calls back into the exact command dispatch every other onboard/create
    # answer reaches, so nothing forks into a second, divergent creation path.
    if ( $command eq 'onboard' && defined $browser_host ) {
        my $create = sub {
            my ($fields) = @_;
            my %merged = ( %option, %{$fields} );
            return _invoke( $tira, 'onboard', undef, \%merged );
        };
        # Same pre-fill the CLI wizard gives itself (_wizard_defaults) - the
        # browser form gets the identical suggested directory and defaults
        # lookup so editing an existing project is just as safe here.
        my $suggested = $option{dir}
          // eval { $tira->discover_project( defined $option{project} ? ( project => $option{project} ) : () ) }
          // '.';
        require Tira::CLI::Serve;
        my $served = eval {
            ( $onboard_browser_server || \&Tira::CLI::Serve::_serve_onboard_browser )->(
                host => $browser_host, port => $browser_port, create => $create,
                dir  => $suggested,
                defaults => sub { require Tira::CLI::Wizard;
                    Tira::CLI::Wizard::_wizard_defaults( $tira, $_[0] ) },
                questions => $tira->onboarding_questions,
            );
            1;
        };
        return _error( $tira, 'toon', $@ || 'Unable to serve the onboarding session' ) if !$served;
        return 0;
    }

    # Only tira.onboard ever prompts. project.new stays purely argument-driven,
    # so no script or agent invoking it can be left waiting on input, and
    # onboard needs no terminal detection: without input it reaches end of
    # stream immediately and aborts rather than blocking.
    if ( $command eq 'onboard' ) {
        # The wizard and its line editor are in Tira::CLI::Wizard, loaded here
        # because tira.onboard is the only command that prompts. TKT-607.
        require Tira::CLI::Wizard;
        my ( $answers, $guided_status ) = Tira::CLI::Wizard::_project_wizard( $tira, $guided_input // \*STDIN, \%option );
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

        # Whose board this is, recorded before anything forks. After a
        # pre-forked server has started there is no way for a process to tell
        # whether it is the master or a worker by asking itself, and the
        # difference decides whether a restart can possibly work.
        local $SERVING_PID = $$;

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
            #
            # Only the process that launched it may do that. This closure runs
            # in a worker under a pre-forked server, and a worker is not the
            # board: the master owns the listening socket, so a worker that
            # execs into a fresh dashboard cannot bind the port, dies, and is
            # replaced - taking the request with it. Four boards did exactly
            # that every sixty-five seconds for twenty hours without ever
            # upgrading, and it is why the page appeared to stop refreshing on
            # its own. Proved on an isolated board rather than reasoned about.
            require Tira::CLI::Serve;
            my $restarted = Tira::CLI::Serve::_serving_pid() == $$
              && Tira::CLI::Serve::_restart_if_updated(
                $restarter || \&Tira::CLI::Serve::_restart_into,
                $command, $type, $option{project} );

            # And when it cannot, it says so instead of failing quietly once a
            # minute. The page reads this payload every sixty seconds already.
            if ( !$restarted ) {
                require Tira::CLI::Serve;
                my $on_disk = Tira::CLI::Serve::_version_on_disk();
                $dashboard->{_stale} = $on_disk
                  if defined $on_disk && $on_disk ne $Tira::VERSION;
            }
            $dashboard->{_version} = $Tira::VERSION;
            return $tira->format_output( $dashboard, output => 'json', project => $option{project} );
        };
        # His decision, taken here and said out loud. A board serving sessions
        # that never expire is a different thing from one that does, and
        # somebody starting it should be able to tell without reading a manual.
        # His msg on TKT-852, answering what --show-logs should mean: "A logs
        # panel inside the browser dashboard itself, so the log is read in the
        # page rather than in the terminal." Off unless asked for, because a
        # board that records every request it answers should do so because
        # somebody wanted to look, not by default.
        if ( $option{show_logs} ) {
            $Tira::DashboardWeb::SHOW_LOGS = 1;
            print {*STDERR} "This board keeps its recent requests and shows them in the page.\n"
              . "The last 200 are held in memory and nothing is written to disk - they are\n"
              . "served to the page that shows them, and nowhere else.\n";
        }

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

        # Resolved here, because here is where the resolver is.
        #
        # A board may be referred to by something other than its path, and that
        # is deliberate: the agent working a project is never told where the
        # board actually sits. Only this process can turn one into the other -
        # it holds the resolver - and the workers that serve the board are
        # started fresh with nothing but the environment. Handing them what was
        # typed made every request fail inside a worker, with the port bound and
        # the board apparently up.
        my $serving = eval { $tira->discover_project( project => $option{project} ) };
        return _error( $tira, 'toon', $@ || 'Unable to resolve the board to serve' )
          if !defined $serving;

        my %providers = browser_providers( tira => $tira, project => $serving,
            store => $option{store} );
        require Tira::CLI::Serve;

        # POLICE BESIDE THE BOARD, in one terminal. His first sentence on
        # TKT-897: "So the user doesn't need to run 2 terminals. All in 1 go."
        #
        # Forked HERE rather than inside the serving code, for two reasons. The
        # serving side is engine source and t/106 holds the engine to inviting
        # no processes at all; and this is the only place that already holds the
        # Tira object and the store the pass needs, so nothing has to be
        # reconstructed in a child that starts with less context than its parent.
        #
        # The CHILD claims, not the parent, because the claim names a pid and
        # the pid that matters is the one actually watching. Marked as the
        # dashboard's, which is what makes a later tira.police stand down rather
        # than kill it - his answer to Q-117.
        my $police_child;
        if ( $option{with_police} ) {
            $police_child = ( $police_starter || \&Tira::CLI::Serve::_start_police_beside_board )->(
                tira => $tira, project => $serving, store => $option{store} );

            # Said rather than swallowed, and the board still served: losing the
            # bridge is worse with no explanation than with one, and it is not a
            # reason to refuse somebody the board they asked for.
            print {*STDERR} "tira: could not start police beside the board - serving "
              . "without it; run d2 tira.police in another terminal\n"
              if !$police_child;
        }

        my $served = eval {
            ( $browser_server || \&Tira::CLI::Serve::_serve_browser )->(
                host => $browser_host, port => $browser_port, render => $render, data => $data,

                # Which board, and how to show it. The workers load the
                # application themselves and cannot be handed a closure over
                # any of this, so it travels in the environment - and serve()
                # refuses without a project rather than starting workers that
                # die on load.
                project => $serving, type => $type,
                with_title => defined $option{title},    # TKT-779: was $option{with_title}, never assigned

                # TKT-897, his first sentence. Passed rather than acted on here
                # because the serving side owns the process the police pass has
                # to live and die beside - a pass started here would outlive a
                # server that failed to bind, and the claim it holds would point
                # at a pid nobody could find.
                with_police => $option{with_police} ? 1 : 0,
                %tls, %providers,
            );
            1;
        };

        # THE PASS DIES WITH THE BOARD. A police child outliving the server it
        # was started beside would hold the singleton claim while nothing served
        # the board - so the next tira.police would stand down in favour of a
        # dashboard that is gone. Reaped as well as signalled, so the claim is
        # released before this process returns.
        ( $police_stopper || \&Tira::CLI::Serve::_stop_police_beside_board )->($police_child)
          if $police_child;

        return _error( $tira, 'toon', $@ || 'Unable to serve dashboard' ) if !$served;
        return 0;
    }

    if ( $option{output} eq 'human' && $option{count} && ref $result eq 'HASH' ) {
        print "$result->{count}\n";
        return _finish( $tira, \%option, $command, 0 );
    }
    if ( $option{output} eq 'human' && $option{refs_only} && ref $result eq 'ARRAY' ) {
        print _utf8_bytes( join '', map { "$_\n" } @{$result} );
        return _finish( $tira, \%option, $command, 0 );
    }
    # What was asked for, so the readable format can show that rather than
    # drawing its whole card template against a record it no longer has. Asking
    # for one field used to print a filled card as an empty one - no
    # description, unassigned, no priority - and leave out the field itself.
    my $formatted = eval {
        $tira->format_output( $result, output => $option{output}, project => $option{project},
            ( defined $option{field_selection} ? ( fields => $option{field_selection} ) : () ) );
    };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print _utf8_bytes($formatted);
    my $status = ( defined $option{if_changed} && ref $result eq 'HASH' && $result->{unchanged} ) ? 1 : 0;

    # Findings, told apart from clean and from could-not-look. An error already
    # exits 2, so this takes 1 and the three answers a checker needs are all
    # expressible. TKT-279.
    # Counting rows is the fallback, not the rule: it is right for every command
    # whose output IS its findings, and wrong for any that summarises, groups or
    # adds a heading. TKT-291 asks for grouping on this same command, so the
    # count has to come from the command rather than from what it printed.
    $status = 1
      if $option{exit_nonzero_if_any}
      && ( defined $option{findings_count}
        ? $option{findings_count}
        : ( ref $result eq 'ARRAY' && @{$result} ) );
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

# Where Tira's own board is, asked for by name rather than by path. The
# dashboard already resolves a skill name to its directory, and on somebody
# else's machine it resolves to their copy - which is right, because a bug
# report belongs to whoever owns the Tira that has the bug.
#
# Through a seam, so a test can answer the question without a real installation
# and without the answer ever being a path this skill hands out.
sub _tira_home {
    my $resolver = _dd_path_resolver();
    my $home = eval { $resolver->('tira') };
    die "Could not find Tira's own board to report this to. Report it to whoever\n"
      . "maintains Tira instead.\n"
      if !defined $home || $home eq '';
    return $home;
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

        # Global aliases only, not path_aliases - which merges in whatever
        # repo-local .developer-dashboard.json is found by walking up from
        # the working directory, and a repo-local file can name the same
        # alias a global one already names. From two directories that
        # themselves held such a file, the identical name resolved to that
        # repo's board instead of the one a global alias had always meant -
        # silently, because config merging does not distinguish "this repo
        # extends the alias set" from "this repo means something different
        # by a name already taken". TKT-368. A board selector is a
        # user-level, stable idea by design (TKT-250: one way to name a
        # board, nothing to fall back on) - it is not a project setting a
        # repo should be able to override by merely being nearby.
        $paths->register_named_paths( $config->global_path_aliases );
        return $paths->resolve_dir($name);
    };
}









# The viewer decides whether an attachment can be shown as text from its
# content_type and from nothing else - it keeps no extension list of its own,
# which is the point of TKT-645. record_show does not carry that field, and
# should not: computing it stats the stored file and sometimes reads its first
# bytes, and a record is read on every gate, every police pass and every board
# render. attachment_list already computes it on request, from the one
# implementation, so the card dialog asks there and stamps the answer on by sha.
#
# Comment, question and answer attachments are stamped too, because the viewer
# opens those from the same strip and cannot tell where an entry came from.
#
# Failure is deliberately silent: an unreadable attachment store costs the
# preview, not the card.
sub _stamp_attachment_types {
    my ( $tira, $project, $ref, $record ) = @_;
    return if ref $record ne 'HASH';
    my $listed = eval {
        $tira->attachment_list(
            project => $project, ref => $ref, meta_only => 1 );
    } or return;
    my %type_of;
    for my $entry ( @{ $listed->{attachments} // [] } ) {
        next if !defined $entry->{sha} || !defined $entry->{content_type};
        $type_of{ _attachment_key($entry) } = $entry->{content_type};
    }
    return if !keys %type_of;

    my @lists = ( $record->{attachments} );
    push @lists, $_->{attachments} for @{ $record->{comments} // [] };
    for my $question ( @{ $record->{questions} // [] } ) {
        push @lists, $question->{attachments};
        push @lists, [ $question->{voice} ] if $question->{voice};
        push @lists, $question->{answer}{attachments} if $question->{answer};
    }
    for my $list (@lists) {
        next if ref $list ne 'ARRAY';
        for my $entry ( @{$list} ) {
            next if ref $entry ne 'HASH' || !defined $entry->{sha};
            my $key = _attachment_key($entry);
            next if !exists $type_of{$key};
            $entry->{content_type} = $type_of{$key};
        }
    }
    return;
}

# Attachments are content-addressed, so the sha alone does not identify one:
# the same bytes attached under two names are two entries sharing a sha, and
# the type follows the name as much as the content. A valid SVG is also valid
# text, and keying on the sha alone stamped both copies with whichever the
# listing reached last - the .svg came back as text/plain and would have opened
# in the text pane instead of rendering. Found by review, then reproduced.
sub _attachment_key {
    my ($entry) = @_;
    return join "\0", $entry->{sha} // '', lc( $entry->{extension} // '' );
}

# One provider set feeds both the CLI-launched Dancer2 server and the
# standalone dashboard.psgi, so browser mutations can never drift from the
# engine's validated command surface.
# 701 lines of provider coderefs used to sit here, needed by the one invocation
# that serves a board and read by everybody changing anything else. They are in
# Tira::CLI::Browser now, loaded when a board is actually served - the shape
# this file already used for Tira::DashboardWeb and Tira::OnboardWeb.
#
# The name stays. Twenty test files and the dashboard call
# Tira::CLI::browser_providers, so it still exists and still answers; a refactor
# that renames its own front door is not behaviour-preserving. TKT-607.
sub browser_providers {
    require Tira::CLI::Browser;
    return Tira::CLI::Browser::providers(@_);
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
    require Tira::CLI::Serve;
    my $context = {
        dir => $dir, file => $file, ttl => $option->{cache_ttl},
        fingerprint => Tira::CLI::Serve::_board_fingerprint($root),
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






# Is there a coding agent on this machine at all? Its own sub so a
# test can drive both answers, rather than proving whichever one this
# particular machine happens to give.
# PATH is separated by a colon on POSIX and a semicolon on Windows, and a
# program there is executable because of its extension rather than a mode bit.
# Splitting on a colon and looking for an extensionless file found nothing on
# Windows however much was installed, and answered "no agent" rather than
# failing - so onboarding quietly offered nothing.

# One search for "is this program here", used by everything that asks.
#
# There were two. This one knew that a program on Windows is called name.exe
# and that -x there answers for the extension rather than the file; the one the
# world gatherer used knew neither, so it found no git on Windows and every
# fact built on git came back empty. Two searches for the same thing drift
# apart the first time somebody fixes only the one they are looking at, which
# is exactly what happened.
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

            # PATHEXT is conventionally upper case and the program on disk
            # conventionally is not. Windows itself does not care, because its
            # filesystem does not - but the same code runs under WSL, on
            # network shares, and in NTFS directories with case sensitivity
            # turned on, where it does. Trying both costs nothing and stops
            # this depending on which of those it happens to be.
            for my $spelling ( $suffix, lc $suffix ) {
                my $candidate = File::Spec->catfile( $dir, "$name$spelling" );
                return 1 if $WINDOWS ? -f $candidate : -x $candidate;
            }
        }
    }
    return 0;
}




sub _attachment_content_type {
    my ( $extension, $path ) = @_;
    return Tira::_attachment_content_type( $extension, $path );
}

# Who is doing this, for the work log, set once for whatever runs next.
#
# Every record write journals the change and stamps it with the author the
# engine happens to be holding, and only four methods ever set one. So a
# checklist item, a gate, a piece of evidence and an assignment were all written
# by nobody - and gate.add and evidence.add collected an author, stored it
# inside the entry, and did not use it here. A project spent two days on a card
# that appeared to move by itself, because a headless agent resuming their
# session moved it every fifteen minutes and the history could not say so.
#
# This is the layer that knows: it has already resolved --author, or TIRA_AUTHOR
# said once rather than on every command. The methods that validate the author
# themselves still do, and overwrite this with the same answer.
#
# A name the board does not know is not recorded. A log that writes down any
# name is worse than one that writes down none, because an unknown name reads as
# accounted for - and a command run before its project exists has nobody to be.
sub _journal_identity {
    my ( $tira, $args ) = @_;
    my $author = $args->{author};
    return undef if !defined $author || $author eq '';
    return eval {
        my $root = $tira->discover_project( %{$args} );
        $tira->_journal_attribution( project => $root, author => $author );
    };
}

# Whether a move would skip ahead in the board's own declared column order.
# Returns a refusal message naming the correct next column(s), or undef when
# the move is fine - backward (redoing work after a step back), sideways to
# the same column, or into discard, which is always exempt regardless of
# position: abandoning work is not skipping it. Measured against the owner's
# own example: chain backlog -> planning -> doc -> code, a move straight from
# backlog to code refuses naming planning. TKT-426.
#
# A column's next step is normally derived from array position, one value -
# correct for a linear chain, wrong at a genuine fork, where more than one
# column is a legitimate forward step and which one depends on the card's
# own path (owner's example: a chain ending 'e2e testing', which then forks
# to either 'done' or 'deploying'). A column carrying an explicit --next set
# (tira.column.update --next) is checked against that set instead of the
# single positional successor; a column with nothing configured keeps
# deriving its one next step from position, unchanged. TKT-430.
#
# A skip that would otherwise refuse is allowed anyway when every column
# strictly between the origin and the destination already carries a passing
# gate named exactly like that column - a naming convention, not a new
# mapping (owner's own answer, Q-053): nothing in Tira ties a gate name to a
# column, so the column's own name is the gate's name. A card whose
# intermediate stages already passed does not need a mechanical walk through
# columns it never substantively occupied - gate.add already exists to
# prove what happened, and the chain check should trust it. TKT-429.
# The columns for whatever board this call is about, whether or not the caller
# said which.
#
# column_list needs a concrete board type. record_show and record_move do not -
# they resolve a record by ref alone (TKT-532). So a caller who omits the type
# gets a column lookup that returns nothing, and in a GUARD that reads as
# "nothing to refuse": the gate does not fail closed, it fails silent and open.
# Reproduced on a copy of a real board - a card walked from backlog to
# in-review through nine gated columns with 75 required actions pending and not
# one refusal.
#
# The browser move provider already recovered the type from the record it had
# just loaded, with the principle recorded there: "a caller is never required
# to say what the engine can already tell for itself". That recovery is here
# instead of in one branch, so the next caller cannot forget it - six call
# sites needed it and only one had it. TKT-597.
sub _columns_for {
    my ( $tira, $args, $known ) = @_;
    if ( !defined $args->{type} || $args->{type} eq '' ) {
        my $type = ref $known eq 'HASH' ? $known->{type} : undef;
        if ( !defined $type || $type eq '' ) {
            my $seen = eval { $tira->record_show( %{$args} ) };
            $type = ref $seen eq 'HASH' ? $seen->{type} : undef;
        }

        # Written back into the caller's own arguments rather than kept to a
        # local copy. The chain guard ends its refusal with the move to make
        # instead - "d2 tira.<type>.move" - and formats it from %args, so
        # recovering the type for the lookup alone left the gate correctly
        # closed and the caller told to run "d2 tira..move", with an
        # uninitialized warning beside it. The other two guards name a command
        # of their own (required-action.update, question.mark) and never
        # interpolate the type, so this matters to one refusal in three; it is
        # written here rather than there because the next guard to end with a
        # typed command should not have to rediscover it. Recovering a fact and
        # then not telling the caller is how the first version of this fix
        # passed every test about the gate while still misdirecting the person
        # who hit it. Codex review, TKT-597.
        $args->{type} = $type if defined $type && $type ne '';
    }
    return eval { $tira->column_list( %{$args} ) };
}

sub _column_chain_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq ( $args{column} // '' );
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    my $from_idx = $index{$from};
    my $to_idx   = $index{ $args{column} };

    # Backward is always fine, fork or no fork.
    return undef if $to_idx <= $from_idx;

    my ($from_col) = grep { $_->{name} eq $from } @{$columns};
    my $fork = $from_col ? ( $from_col->{next} // [] ) : [];
    my $blocked;
    if ( @{$fork} ) {
        if ( !grep { $_ eq $args{column} } @{$fork} ) {
            my $options = join( ' or ', @{$fork} );
            $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $options.\n"
              . "  Move there first, e.g.:  d2 tira.$args{type}.move --ref $args{ref} --column $fork->[0]\n";
        }
    }
    elsif ( $to_idx > $from_idx + 1 ) {
        my $next_name = $columns->[ $from_idx + 1 ]{name};
        $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $next_name.\n"
          . "  Move there first:  d2 tira.$args{type}.move --ref $args{ref} --column $next_name\n";
    }
    return undef if !defined $blocked;

    my @log = @{ $current->{gate_passing_log} // [] };
    my $all_gated = 1;
    SKIPPED: for my $j ( $from_idx + 1 .. $to_idx - 1 ) {
        my $name = $columns->[$j]{name};
        next SKIPPED if grep { ( $_->{gate} // '' ) eq $name && ( $_->{result} // '' ) eq 'pass' } @log;
        $all_gated = 0;
        last SKIPPED;
    }
    return undef if $all_gated;
    return $blocked;
}

# A column names what must be done before a card leaves it (TKT-427); the
# move refuses, naming which of that column's required items are still
# unmarked, instead of the checklist item existing as a suggestion nobody is
# made to act on. discard is exempt, same as the chain check above and for
# the same reason: abandoning work is not leaving a stage undone. Checked in
# this same CLI-only dispatch layer - the dashboard's own move provider calls
# record_move directly and is untouched.
#
# Only a forward departure is checked. A backward move is how a card escapes
# a column it cannot currently satisfy - the unmet item may be exactly what
# failed, e.g. a test column's own 'tests green' - so gating retreat the same
# way as progress would leave a card with nowhere to go. This matches the
# chain check's own backward exemption.
# What a card must already have done before it may be worked in a column.
#
# The mirror of the gate below, and deliberately not a variant of it: that one
# asks what is unfinished in the column being LEFT, this asks what is unmet in
# the column being ENTERED. The owner's example is work that belongs to neither
# column's own business - "Verify all details in the card", between backlog and
# tests-red - which is why it cannot be expressed as an exit action on the
# column before it. TKT-591.
#
# The items are populated BEFORE the refusal, on purpose. An entry gate is
# satisfied from outside the column it guards, so if the list only appeared once
# the card was inside there would be nothing to mark and no way in. The first
# attempt therefore brings the list onto the card and refuses; the second, once
# the items carry their evidence, goes through.
#
# Forward moves only, like every other gate here. A card being sent back is not
# asked to qualify for where it is retreating to (TKT-455) - the unmet thing may
# be exactly what it is going back to fix.
# Putting a column's entry template on a card, without deciding anything about
# whether the card may be there.
#
# Shared by the gate below and by the browser move provider, and the split is
# TKT-452's, stated where the browser path already makes it: the gating half is
# CLI-only, because a human dragging a card is not an agent skipping a gate,
# but keeping the card accurate for whoever reads it next is not enforcement
# and has to happen either way. A card dragged into a column would otherwise
# carry that column's exit actions and none of its entry ones, which is a card
# that lies about what was asked of it.
#
# Returns what it could NOT add, as [text, why] pairs, rather than swallowing
# the failure: the caller decides what that means. The gate refuses on it; the
# browser path, which cannot refuse, still has it to report. TKT-591.
sub _populate_entry_required_actions {
    my ( $tira, $args, $to, $columns, $record ) = @_;
    my ($to_col) = grep { $_->{name} eq $to } @{ $columns // [] };
    my @template = @{ ( $to_col ? $to_col->{entry_required_actions} : undef ) // [] };
    return [] if !@template;

    my @existing = @{ ( ref $record eq 'HASH' ? $record->{required_items} : undef ) // [] };
    my @failed;
    for my $text (@template) {

        # Matched by text and column alone - a fast-path skip only, mirroring
        # required_item_add's own authoritative check inside the lock, which
        # deliberately does not require the template marker either (TKT-652:
        # narrowing this broke t/422/TKT-445's "do the work early" case).
        next if grep { ( $_->{item} // '' ) eq $text && ( $_->{column} // '' ) eq $to } @existing;
        my $added = eval {
            $tira->required_item_add( %{$args}, item => $text, status => 'pending',
                column => $to, source => 'required-action', entry => 1 );
            1;
        };
        next if $added;
        my $why = $@ // 'no reason given';
        $why =~ s/\s+/ /g;
        $why =~ s/\A\s+|\s+\z//g;
        push @failed, [ $text, $why ];
    }
    return \@failed;
}

sub _column_entry_required_action_violation {
    my ( $tira, %args ) = @_;
    my $to = $args{column} // '';
    return undef if $to eq '' || $to eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq $to;

    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{$to};
    return undef if $index{$to} < $index{$from};

    my ($to_col) = grep { $_->{name} eq $to } @{$columns};
    my @template = @{ ( $to_col ? $to_col->{entry_required_actions} : undef ) // [] };
    return undef if !@template;

    my $unpopulated = _populate_entry_required_actions( $tira, \%args, $to, $columns, $current );
    my @unpopulated = @{$unpopulated};
    if (@unpopulated) {
        return "Cannot move $args{ref} into $to - "
          . scalar(@unpopulated)
          . " of its entry required actions could not be put on the card, so none of them can be worked.\n"
          . join( '', map { "  " . ( length $_->[0] ? _first_line( $_->[0] ) : '(an empty entry action)' )
                . "  ($_->[1])\n" } @unpopulated )
          . "  Fix the column's entry list, then move again:\n"
          . "    d2 tira.column.update --type $args{type} --name $to --entry-required-action TEXT\n";
    }

    my $refreshed = eval { $tira->record_show(%args) } // $current;
    my %exempt = map { ( ref($_) eq 'HASH' ? $_->{item} : $_ ) => 1 }
      @{ $refreshed->{required_exempt} // [] };
    my %wanted = map { $_ => 1 } @template;
    my @unmet = grep {

        # Trusted on the marker OR a live text match against the CURRENT
        # entry template - either is sufficient evidence this item is an
        # entry obligation. The marker alone survives a column rename
        # (TKT-652: an item populated under the old wording keeps gating
        # after the column's entry text changes, since its stored text no
        # longer matches %wanted but its marker still says entry). The text
        # match alone is what keeps TKT-445/t/422's "do the work early"
        # capability working: a manual required-action.add item, or one
        # written before this column ever had an entry template, has no
        # marker but still satisfies a live-matching entry requirement,
        # symmetric with how it already satisfies the exit list.
        ( $_->{column} // '' ) eq $to
          && ( $_->{entry} || $wanted{ $_->{item} // '' } )
          && !$exempt{ $_->{item} }
          && !_item_is_done($_);
    } @{ $refreshed->{required_items} // [] };
    return undef if !@unmet;

    return "Cannot move $args{ref} into $to - "
      . ( @unmet == 1 ? 'an entry required action is' : scalar(@unmet) . ' entry required actions are' )
      . " not done. The card stays in $from:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{item} ) . "\n" } @unmet )
      . "  They are on the card now, so they can be done from here.\n"
      . "  Mark one, then move again:\n"
      . "    d2 tira.required-action.update --ref $args{ref} --id $unmet[0]{id} --status done --command TEXT --proof TEXT\n";
}

# What is blocking this card HERE, answerable without attempting a move.
#
# required-action.list returns every item on a card across every column - 75 on
# the card this was measured against - so the only way to learn what is in the
# way was to try a move and be refused. That is a strange shape for a system
# whose whole purpose is telling an agent what to do next, and it is why the
# refusal was the only place the answer existed.
#
# Deliberately the SAME selection the refusal makes - the column the card is
# in, minus this card's exemptions, minus anything already done - rather than a
# second definition that could drift from it. If these two ever disagree, the
# agent is told one thing and refused for another.
#
# Not named card.required or anything like it: tira.card.required already
# exists and answers which FIELDS a complete card needs, which is a different
# question, and a third similarly-named thing would mislead. TKT-598.
# The one selection. Both the refusal and the on-demand answer call this, so
# "they cannot drift" is a fact about the code rather than a promise in a
# comment - the first version of this card left the refusal with its own copy
# of the grep while the comment beside it claimed otherwise, which codex review
# caught and which is the same shape as a POD promising a report nothing wrote.
sub _unmet_in_column {
    my ( $record, $column ) = @_;
    return [] if ref $record ne 'HASH';
    return [] if !defined $column || $column eq '';
    my %exempt = map { ( ref($_) eq 'HASH' ? $_->{item} : $_ ) => 1 }
      @{ $record->{required_exempt} // [] };
    return [ grep {
        ( $_->{column} // '' ) eq $column
          && !$exempt{ $_->{item} }
          && !_item_is_done($_);
    } @{ $record->{required_items} // [] } ];
}

# Answering the same question on demand. The card must exist: turning a failed
# read into an empty list would say "nothing is blocking you" about a ref that
# is missing, misspelled or unreadable, and say it with exit 0 - while the same
# command without --blocking says "Record 'X' not found" and exits 2. Codex
# probed exactly that. A question about a card that is not there has no answer,
# so the error is left to travel.
sub _outstanding_here {
    my ( $tira, %args ) = @_;
    my $current = $tira->record_show(%args);
    return _unmet_in_column( $current, $current->{column} );
}

sub _column_required_action_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq ( $args{column} // '' );
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    return undef if $index{ $args{column} } < $index{$from};

    # The column's template is a baseline, not an absolute: a card can carry
    # its own exemptions from specific items (tira.<type>.update
    # --exempt-required TEXT), for a situation the column-wide template does
    # not fit. Checked here rather than by the card silently omitting the
    # item, so the exemption is a decision on record, not an absence nobody
    # can tell from a genuine oversight. TKT-439.
    # An exemption recorded before TKT-473 is a bare string; one recorded
    # since carries {item, reason, exempted_at, author}. Both name the item
    # the same way to _unmet_in_column, which is where the exemption is now
    # honoured for this guard and for the on-demand answer alike.

    # Required items are their own list, tagged by the column they belong
    # to - not a card's checklist, which stays purely manual. Gating reads
    # this list directly rather than cross-referencing the column's live
    # template, so a card-specific item an agent added
    # (tira.required-action.add) gates exactly like a template-derived one -
    # it was never part of the column's template to begin with. TKT-445.
    # Status is free text, same as checklist - only the comparison against
    # "done" is case-insensitive, so --status Done is not read as still
    # outstanding and refused forever with a message that names the very
    # word the person already used. TKT-434.
    my @unmet = @{ _unmet_in_column( $current, $from ) };
    return undef if !@unmet;

    # One item per line with the id beside it, and the suggested command
    # carrying a REAL id from that list.
    #
    # This used to join the item texts with '; ' and then hand back a command
    # containing the literal REQ-NNN - so acting on the refusal meant running
    # required-action.list, finding each item by matching its text, and reading
    # off the id. On a card with 75 items across a dozen columns that is a
    # cross-reference by eye, and it put proofs against the wrong ids twice on
    # this board. The ids were in @unmet the whole time; the map took the text
    # and dropped them.
    #
    # Measured before it was changed: refusing a real card out of planning
    # produced one line of over a thousand characters covering 12 items whose
    # own texts contain semicolons, backticks and inline command examples -
    # joined with '; ' into prose that has to be re-parsed by eye to see where
    # one item ends and the next begins. TKT-598.
    return "Cannot move $args{ref} out of $from - "
      . ( @unmet == 1 ? '1 required action is' : scalar(@unmet) . ' required actions are' )
      . " not done:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{item} ) . "\n" } @unmet )
      . "  Mark one, then move again:\n"
      . "    d2 tira.required-action.update --ref $args{ref} --id $unmet[0]{id} --status done --command TEXT --proof TEXT\n";
}

# The other half of TKT-427, applied after a move succeeds: the destination
# column's required-action template is added to the card's checklist,
# skipping anything it already carries so re-entering a column never
# duplicates. A backward move resets to undone every required item belonging
# to a column from the new position through the old one, inclusive on both
# ends - owner's own example, EPC-002 comment 17:11:14: chain
# backlog->planning->doc->code->test->review, a card at test moved back to
# planning resets required items for test, code, doc AND planning itself,
# because redoing the work means every one of those checks - including the
# column landed on - needs satisfying again on the way back through. Until
# 3.13 the destination was excluded, so an item already done there stayed
# done even though the card was landing back on that exact column; the
# owner asked for it included (TG msg 4342). TKT-455. discard is excluded
# on both sides: its position in the declared column order is not a
# statement about how much work it undoes. Since TKT-678, an item declared --administrative-action on its column is exempt from this reset entirely - see the admin-exemption check in _apply_column_required_actions below.
sub _populate_column_required_actions {
    my ( $tira, $args, $to, $columns, $required_items ) = @_;
    my ($to_col) = grep { $_->{name} eq $to } @{$columns};
    for my $text ( @{ $to_col->{required_actions} // [] } ) {

        # Matched by text and column alone, the same as it always has been -
        # TKT-445/t/422 established that a manual required-action.add item
        # satisfies this column's own template exactly like a
        # template-derived one, and this dedup existing before that item is
        # what makes "do the work early" not create a spurious duplicate.
        next if grep { $_->{item} eq $text && $_->{column} eq $to } @{$required_items};
        $tira->required_item_add( %{$args}, item => $text, status => 'pending', column => $to, source => 'required-action' );
    }
    return;
}

# The preventive half of TKT-583, and the owner placed it at the move on
# purpose: "remind the agent when the move a card into a new column ... Go
# through them 1 by 1 and provide the proof and command 1 at a time. DO NOT
# LEAVE IT AT LAST AND USE THE SAME PROOF FOR ALL REQUIRED ACTION ITEMS."
#
# The refusal in required_item_update catches a reuse once it is attempted.
# This is earlier: the move is when the new column's list arrives, and the
# reuse happens when an agent reaches the end of that column's work holding a
# list it never read item by item and one recent command. Reminding here is
# the last moment before the habit has anything to act on.
#
# Printed to STDERR so it reaches a person without joining the command's
# machine-readable output, and only when the column actually brought
# required actions with it - a reminder that fires on every move is one
# nobody reads. TSK-168.
# Whether a required item is finished, asked once.
#
# TKT-657. Four places compared a status against 'done' by hand. Three
# lowercased first and _remind_one_at_a_time did not, so an item marked 'Done'
# - the capital the CLI accepts, and which TKT-434 deliberately made the gates
# tolerate - was DONE to every gate and OUTSTANDING to the move-in reminder,
# which then told an agent to work items already finished.
#
# The drift is the argument for the predicate, not the tidiness. This was the
# third instance of one fault in a single day: the dashboard compared against
# the literal 'done' (TKT-601), tools/card-holes did it twice in opposite
# directions and refused a real release (TKT-671), and these four were the
# third. Four hand-written comparisons cannot be guarded as a set - TKT-671's
# ledger greps tools/ for exactly this and cannot see lib/ - but a named
# predicate can be grepped for, and t/422 does.
#
# Nothing is normalised on write. 'Done' stays 'Done' on the card; this is the
# one place that reads it.
sub _item_is_done {
    my ($item) = @_;
    return lc( ( ref $item eq 'HASH' ? $item->{status} : $item ) // '' ) eq 'done';
}

sub _remind_one_at_a_time {
    my ( $tira, $args, $column ) = @_;
    return if !defined $column || $column eq '';

    my $record = eval { $tira->record_show( %{$args} ) } or return;
    my @here = grep { ( $_->{column} // '' ) eq $column && !_item_is_done($_) }
      @{ $record->{required_items} // [] };
    return if !@here;

    print {*STDERR} "\n"
      . "This column brought " . scalar(@here) . " required action(s) with it.\n"
      . "Read them first, then work them ONE AT A TIME, each with its own\n"
      . "--command and --proof from the run that actually satisfied it.\n"
      . "Do not leave them to the end and do not use the same proof for all of\n"
      . "them - one piece of evidence cannot prove two different instructions.\n\n";
    return;
}

# An answer that was read, acted on, and never judged.
#
# Reading is automatic - question_list stamps read_at on the way past, and
# lib/Tira.pm says so: "Reading is what marks an answer read - the agent does
# nothing extra." Judging is a deliberate tira.question.mark that nothing asks
# for until answer-unjudged fires hours later, by which time the card is
# finished and the agent has moved on. Observed twice in one session on this
# board, hours apart, by the agent that had just filed the card about it.
#
# So the prompt is moved to the moment it belongs to: a card does not leave the
# column an answer was given in while that answer carries no mark.
#
# This reads the question's own mark rather than raising a required-action item
# to stand in for it, and that is the point rather than a shortcut. A required
# item is marked done with a command and a proof like any other, so an agent
# can satisfy it in the same sweep as everything else without ever forming a
# view - which is the "acknowledgement the agent can click through" TKT-584's
# third acceptance criterion rules out. There is nothing here to satisfy but
# the act itself.
#
# Four things stay ungated on purpose. An UNANSWERED question: waiting on the
# owner is its normal state and question-unanswered is a different rule about a
# different person. A DISCARDED one: nobody owes a judgement on a withdrawn
# question. An answer marked NOT-OK: the gate wants an assessment, not
# agreement, and answer-not-ok-unresolved already watches what follows a cross.
# And READING: a check that consulted read_at would release itself on the way
# past, which is not a check.
#
# answer-unjudged is untouched and stays the backstop for whatever escapes
# this - a card discarded, or a board where the move never comes. TKT-584.
sub _unjudged_answer_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq ( $args{column} // '' );

    # Forward moves only, the same index comparison the required-action gate
    # makes. A backward move is unconditional by TKT-455's design, because the
    # thing left unmet may be exactly what the card is retreating to fix - and
    # an unjudged answer is a particularly good reason to retreat, since the
    # person who would judge it may be why the card is going back. Written
    # without this at first, which refused a card being sent back to fix
    # something; found by probing, not by a test, because none of t/407's
    # assertions moved a card backward.
    my $columns = _columns_for( $tira, \%args, $current );
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    return undef if $index{ $args{column} } < $index{$from};

    my @unjudged = grep {
        $_->{answer} && !$_->{discarded_at} && !( $_->{answer}{mark} // '' );
    } @{ $current->{questions} // [] };
    return undef if !@unjudged;

    return "Cannot move $args{ref} out of $from - "
      . ( @unjudged == 1 ? 'an answer has' : scalar(@unjudged) . ' answers have' )
      . " not been judged:\n"
      . join( '', map { "  $_->{id}  " . _first_line( $_->{text} ) . "\n" } @unjudged )
      . "  Judge it, then move again:\n"
      . "    d2 tira.question.mark --ref $args{ref} --id $unjudged[0]{id} --mark ok|not-ok\n";
}

# One line of a question, short enough to sit in a refusal beside its id.
sub _first_line {
    my ($text) = @_;
    my ($line) = split /\n/, ( $text // '' );
    $line //= '';
    return length($line) > 72 ? substr( $line, 0, 69 ) . '...' : $line;
}

# A card returning to the queue, and the tasks that still say somebody is on it.
#
# The board already understands that retreating undoes claims of progress: a
# backward move resets the required items between destination and origin,
# keeping their proof (TKT-455). Tasks were never part of that, so a card could
# sit in backlog while its tasklist went on reading "working" until somebody
# ran a second command nobody prompts for. The owner asked for it to happen on
# the move itself.
#
# Anchored to backlog because it is the default builtin column - a fix point
# every board has, so this needs no per-board configuration. A retreat that
# stops short of the queue is not the same statement about the work.
#
# Three decisions, each deliberate:
#
#   A DONE task is left alone. It records work that actually happened, and a
#   card retreating does not unmake it.
#
#   The reset CROSSES the session boundary. Tasklist items are session-scoped
#   (TKT-537), and on a multi-agent board the tasks most needing reset belong
#   to somebody else's session - a reset that respected the boundary would do
#   nothing in exactly the case it exists for.
#
#   A task naming MORE THAN ONE card is not reset, and is named in the output.
#   Q-088: "Never reset a task with more than one linked card, and say so in
#   the output so it is visible rather than silent." There is no status true
#   about both cards at once, and a silent skip is indistinguishable from the
#   feature being broken - the person moving the card is the only one who can
#   judge whether that task needed resetting by hand. TKT-596.
sub _reset_linked_tasks_on_return {
    my ( $tira, $args, $to ) = @_;
    return if ( $to // '' ) ne 'backlog';
    my $ref = $args->{ref};
    return if !defined $ref || $ref eq '';

    # Only project and all_sessions are meant to reach tasklist_list - not
    # the move's whole argument set. A move carrying --status (an option
    # move itself does nothing with, parsed only because Getopt shares one
    # @spec across every command) used to splat straight through and
    # tasklist_list treats status as a filter, dying on a value it does not
    # recognise - silently cancelling the reset below. TKT-632.
    my $items = eval {
        $tira->tasklist_list( project => $args->{project}, all_sessions => 1 );
    };
    if ( ref $items ne 'ARRAY' ) {
        my $why = $@ || 'no reason given';
        $why =~ s/\s+/ /g;
        printf {*STDERR} "\nCould not check for linked tasks to reset: %s\n", substr( $why, 0, 200 );
        return;
    }

    my ( @reset, @skipped, @failed );
    for my $item ( @{$items} ) {
        my @refs = @{ $item->{refs} // [] };
        next if !grep { $_ eq $ref } @refs;
        next if ( $item->{status} // 0 ) != 1;
        if ( @refs > 1 ) { push @skipped, $item; next }

        # A failure here is SAID, not swallowed. Written first as a bare eval
        # whose failure left the task neither reset nor mentioned - the task
        # would go on reading "working" and the move would report nothing,
        # which is indistinguishable from there having been no task at all.
        # That is the same silent-skip fault this card's own multi-ref rule
        # exists to avoid, one line lower down.
        my $ok = eval {
            $tira->tasklist_update(
                %{$args}, id => $item->{id}, status => 'pending',
                session => $item->{session} // '',
            );
            1;
        };
        if   ($ok) { push @reset,  $item }
        else       { push @failed, [ $item, $@ ] }
    }
    return if !@reset && !@skipped && !@failed;

    print {*STDERR} "\n";
    printf {*STDERR} "%d task(s) reset to pending, because %s went back to the queue:\n",
      scalar @reset, $ref
      if @reset;
    printf {*STDERR} "  %s  %s\n", $_->{id}, _first_line( $_->{text} ) for @reset;
    if (@skipped) {
        printf {*STDERR} "%d task(s) left alone, each linked to more than one card -\n"
          . "check by hand whether they should still say working:\n", scalar @skipped;
        printf {*STDERR} "  %s  %s  (also on %s)\n", $_->{id}, _first_line( $_->{text} ),
          join( ', ', grep { $_ ne $ref } @{ $_->{refs} // [] } )
          for @skipped;
    }
    if (@failed) {
        printf {*STDERR} "%d task(s) could NOT be reset and still say working -\n"
          . "reset them by hand:\n", scalar @failed;
        for my $pair (@failed) {
            my ( $item, $why ) = @{$pair};
            $why //= 'no reason given';
            $why =~ s/\s+/ /g;
            printf {*STDERR} "  %s  %s  (%s)\n", $item->{id},
              _first_line( $item->{text} ), substr( $why, 0, 80 );
        }
    }
    print {*STDERR} "\n";
    return;
}

sub _apply_column_required_actions {
    my ( $tira, $args, $from, $to, $columns, $record ) = @_;
    return
      if !defined $from || !defined $to || $from eq 'discard' || $to eq 'discard'
      || $from eq $to || ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return if !exists $index{$from} || !exists $index{$to};
    my $from_idx = $index{$from};
    my $to_idx   = $index{$to};

    # Required items live on their own list, each tagged with the column it
    # applies to (TKT-445) - not the card's checklist, which this mechanism
    # never touches again. Dedup and reset both match on (column, item)
    # rather than item text alone, so an identical required-action string
    # declared on two different columns can never be confused for one item.
    my @required_items = @{ $record->{required_items} // [] };

    if ( $to_idx > $from_idx ) {
        _populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );
    }
    elsif ( $to_idx < $from_idx ) {
        my %admin; for my $col ( @{$columns} ) { $admin{ $col->{name} } = { map { ( $_, 1 ) } @{ $col->{administrative_actions} // [] } } }
        my @reset; for my $item (@required_items) {
            next if !defined $item->{column} || !exists $index{ $item->{column} };
            my $item_idx = $index{ $item->{column} };
            next if $item_idx < $to_idx || $item_idx > $from_idx;
            next if $admin{ $item->{column} }{ $item->{item} };    # TKT-678/Q-100: declared per-item exemption

            # Same case-insensitive comparison as the move-out gate above -
            # an item marked --status Done is genuinely done, and must reset
            # on the way back through exactly as --status done would. TKT-434.
            next if !_item_is_done($item);
            $tira->required_item_update( %{$args}, id => $item->{id}, status => 'pending', source => 'required-action' );
            push @reset, $item->{item};
        }

        # A backward move-in is still a move-in: the destination column's own
        # template must be on the card even if it was never populated on an
        # earlier forward pass - which happens when the template was declared
        # after the card had already left that column once, exactly what
        # TKT-458 hit in practice. TKT-464.
        _populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );

        # zen-framework's report (TKT-525): a card moved all the way back
        # into Backlog - always the structurally-first column, so this reset
        # is the most extreme case the branch above already handles - looked
        # broken because nothing said why a done item, proof intact, now
        # reads pending. The reset is correct (TKT-455); what was missing was
        # an explanation on the card itself. Michael's answer to Q-079: keep
        # the reset, add the comment. One comment per move, not one per item,
        # and only when something actually reset - a backward move that
        # resets nothing has nothing to explain.
        if (@reset) {
            eval {
                $tira->comment_add( %{$args},
                    text => "Moved backward from $from to $to: " . scalar(@reset)
                      . ' required item(s) reset to pending, proof kept - '
                      . join( ', ', @reset )
                      . '. This is the intended backward-move design (redoing work from here means every check between here and where you were needs satisfying again), not something undone by hand.',
                );
            };
        }
    }
    return;
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

    # Before anything is dispatched, because a record command returns long
    # before the misleading-option table is reached and the whole point is that
    # nothing acts on an option it will not use.
    _refuse_unread_options( $command, $option );

    my %args = %{$option};
    delete @args{qw(output help apply repair_columns recursive include_deleted include_discard full dry_run attach set_key_details set_deliverables set_acceptance set_test_steps set_bdd set_atdd set_labels set_affects_versions set_scope_in set_scope_out field_selection exclude_fields include_empty older_than stale with_level all columns_json nested mark members columns sow_prefix epic_prefix ticket_prefix sow_columns epic_columns ticket_columns)};

    # Set here so every command carries it, rather than in each method that
    # writes - which is how only four of them ever did.
    local $tira->{_journal_author} = _journal_identity( $tira, \%args );
    if ( defined $option->{field_selection} || defined $option->{exclude_fields}
        || $option->{include_empty} || defined $option->{since}
        || $option->{brief} || defined $option->{truncate} ) {
        my $comment_scope = ( defined $option->{field_selection} || defined $option->{since} )
          && !defined $option->{exclude_fields} && !$option->{include_empty}
          && !$option->{brief} && !defined $option->{truncate};
        die "Read options are available on show, list, and export commands\n"
          if $command !~ /\A(?:record\.(?:show|list)|export|next)\z/
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
    #
    # create is not refused here any more (TKT-362): at create time there is
    # no ref yet, so this message's own advice printed the unrunnable
    # placeholder "<this record>". create_record does the link itself and
    # applies hierarchy_link's own validation, so a bad parent still fails -
    # just with a message that names something that exists.
    if ( defined $option->{parent} && $command =~ /\A(?:record|sow|epic|ticket)\.update\z/ ) {
        my $child = $option->{ref} // '<this record>';
        die "A parent is set with hierarchy.link, not by updating the record:\n"
          . "  tira.hierarchy.link --parent $option->{parent} --child $child\n";
    }

    die "All is available on the warning.clear and login.logout commands\n"
      if $option->{all} && $command ne 'warning.clear' && $command ne 'login.logout';
    die "A password belongs to the login.register and login.check commands\n"
      if defined $option->{password} && $command !~ /\Alogin\.(?:register|check)\z/;
    die "A column layout belongs to the column.apply command\n"
      if defined $option->{columns_json} && $command ne 'column.apply';
    # Both option tables are checked HERE rather than beside the %method
    # dispatch they were written next to. That placement was the bug within the
    # bug: %method is reached only after a long if/elsif chain, and record.*
    # returns from it some seven hundred lines earlier - so a guard sitting
    # with %method never ran for the create verbs, which are exactly the ones
    # --dry-run writes records on. Every command passes through this block.
    # TKT-625.
    require Tira::CLI::Options;
    for my $misleading ( @{ Tira::CLI::Options::misleading_for($command) } ) {
        my ( $given, $meant ) = @{$misleading};
        next if !defined $option->{$given} || $option->{$given} eq '';
        ( my $flag = $given ) =~ tr/_/-/;
        ( my $instead = $meant ) =~ tr/_/-/;
        die "$command does not act on --$flag. Use --$instead, which is what it reads.\n";
    }
    # The other shape of the fault %MISLEADING_OPTIONS catches: an option this
    # command does not act on, for which there is no "you meant this one" - it
    # simply is not implemented here, and its name promises the opposite of what
    # happens. One global @spec means every command parses --dry-run; only
    # bulk_import and replace_records read it. So tira.import --dry-run previews
    # and writes nothing, and tira.ticket.create --dry-run CREATED THE CARD.
    #
    # Measured at a cost: eight probes run to discover which options
    # ticket.create accepts, all but one carrying --dry-run in the belief that it
    # prevented a write, eight live junk cards on the board - TKT-617 through
    # TKT-624 - all discarded afterwards.
    #
    # An allow-list, not a list of the offenders. dry_run is read in exactly two
    # places, so naming those two refuses it everywhere else by construction.
    # Enumerating the verbs that swallow it would have to be right about all of
    # them, and what is owed is every verb that shares the fault, not the four
    # that were convenient to test. That is also why this is not shaped like its
    # neighbour above: %MISLEADING_OPTIONS is narrow because deriving it is
    # impossible, while this one is exact because the flag has exactly two
    # readers. TKT-625.
    die "$command does not act on --dry-run: nothing is previewed here, the "
      . "change is made. tira.import and tira.replace are the commands that "
      . "honour it.\n"
      if $option->{dry_run} && $command ne 'import' && $command ne 'replace';

    die "Nested belongs to the project.new, project.create and onboard commands\n"
      if $option->{nested} && $command !~ /\A(?:project\.(?:new|create)|onboard)\z/;
    die "A mark belongs to the question.mark command\n"
      if defined $option->{mark} && $command ne 'question.mark';
    die "A reason and options belong to the question.ask and question.update commands, "
      . "to police.suspend, to rule.suspend, to policy.decline, and to column.roles "
      . "when it takes a role back\n"
      if ( defined $option->{reason} || $option->{options} )
      && $command !~ /\Aquestion\.(?:ask|update)\z/
      && $command ne 'police.suspend'
      && $command ne 'rule.suspend'
      && $command ne 'policy.decline'
      && $command ne 'column.roles';
    die "A voice note belongs to the question.ask, question.update and question.voice commands\n"
      if defined $option->{voice} && $command !~ /\Aquestion\.(?:ask|update|voice)\z/;
    die "Remove belongs to the question.voice and question.attach commands\n"
      if $option->{remove} && $command !~ /\Aquestion\.(?:voice|attach)\z/;
    die "--caller-kind is available on the question.ask command\n" if defined $option->{caller_kind} && $command ne 'question.ask';
    die "Naming a question belongs to the attachment.list command\n"
      if $option->{questions} && $command ne 'attachment.list';
    # notify.moves reads it too, and adding the verb without widening this made
    # the whole per-column switch unreachable: every --watch it was documented
    # to take was refused before it was dispatched. The guard that exists to
    # stop an option being silently dropped had instead stopped it being given.
    die "Watch is available on the column.update and notify.moves commands\n"
      if defined $option->{watched} && $command !~ /\A(?:column\.update|notify\.moves)\z/;
    die "Queue is available on the column.update command\n" if defined $option->{queue} && $command ne 'column.update';
    die "Required-action is available on the column.update command\n"
      if defined $option->{required_action} && $command ne 'column.update';
    die "Entry-required-action is available on the column.update command\n"
      if defined $option->{entry_required_action} && $command ne 'column.update';
    die "Administrative-action is available on the column.update command\n" if defined $option->{administrative_action} && $command ne 'column.update';
    die "Blocking is available on the required-action.list command\n"
      if defined $option->{blocking} && $command ne 'required-action.list';
    die "Next is available on the column.update command\n"
      if defined $option->{next} && $command ne 'column.update';
    die "Notify-after is available on the column.update, project.update, project.new and onboard commands\n"
      if defined $option->{notify_after}
      && $command !~ /\A(?:column\.update|project\.update|project\.new|onboard)\z/;

    # --column is the reflex flag on record.move, record.list, notify.record
    # and search - the one every other command on this board takes. The four
    # commands that identify a column itself name it with --name instead, and
    # --column was accepted by option parsing (it is a real flag, just for a
    # different command) and then silently ignored: column.update --column X
    # updated nothing named by --column, and with --name absent entirely it
    # died "Column '' not found" - a specific, false claim about the board
    # when the actual fault was the reflex flag. TKT-305.
    die "This command identifies a column with --name, not --column\n"
      if defined $option->{column} && $command =~ /\Acolumn\.(?:add|update|rename|remove)\z/;
    # --session is also the tasklist commands' own scoping flag (TKT-504) -
    # a different meaning on a different feature, not a project reminder
    # setting, so tasklist.* is exempt from this guard same as the three
    # project commands are. The nested task.attach/ref sub-verbs
    # (tasklist.task.attach.add, .discard, .ref.link, .ref.unlink) are
    # dotted four deep, not two - tasklist\.[a-z]+ never matched them, so
    # --session was refused on exactly the commands TKT-538 needed it most
    # on, since those are the ones that mutate an existing item by id.
    die "Reminder settings belong to the project.update, project.new and onboard commands\n"
      if $command !~ /\A(?:project\.update|project\.new|onboard|tasklist\.[a-z](?:[a-z.]*[a-z])?)\z/
      && grep { defined $option->{$_} } qw(collector agent heartbeat);

    # --session is not a reminder setting, and grouping it with three that are
    # is what refused it on search. Both documents describe search's tasklist
    # matching as "scoped to the caller's own --session ... exactly as
    # tasklist.list is" - and it was, in the engine, reachable only through
    # TIRA_AGENT_SESSION because the flag itself was rejected here with a
    # message naming three commands, none of them the one typed.
    #
    # Given its own guard rather than another name appended to that one: the
    # comment above records this whitelist being patched once already for the
    # same class of miss (tasklist's four-deep sub-verbs matched by a
    # two-level pattern), and a scoping argument sharing a list with
    # collector/agent/heartbeat will keep collecting these. TKT-580.
    die "A session scopes the tasklist, search and project commands\n"
      if defined $option->{session}
      && $command !~ /\A(?:project\.update|project\.new|onboard|search|tasklist\.[a-z](?:[a-z.]*[a-z])?)\z/;
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
        die "Multiple refs are only available on show\n"
          if $command !~ /\A(?:record\.show|tasklist\.next|release\.record)\z/;
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
        set_scope_in => 'scope_in_replace', set_scope_out => 'scope_out_replace',
    );
    for my $set ( keys %sets ) {
        next if !defined $option->{$set};
        my $append = $set eq 'set_labels' ? 'labels'
          : $set eq 'set_affects_versions' ? 'affects_versions'
          : $set eq 'set_scope_in' ? 'scope_in'
          : $set eq 'set_scope_out' ? 'scope_out'
          : $sets{$set} =~ s/_replace\z//r;
        die "Cannot combine append and replacement for '$append'\n" if defined $args{$append};
        $args{ $sets{$set} } = _json_array_input( $option->{$set} );
    }
    $args{label} = $option->{labels}[0] if $command =~ /\Acolumn\.(?:add|rename)\z/ && $option->{labels};

    return $tira->create_project( name => $option->{name}, dir => $option->{dir} // '.' ) if $command eq 'project.create';
    if ( $command eq 'project.new' || $command eq 'onboard' ) {
        require Tira::CLI::Wizard;
        return Tira::CLI::Wizard::project_new_or_onboard( $tira, \%args, $option, $command );
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
        require Tira::CLI::Records;
        return Tira::CLI::Records::question_verbs( $tira, \%args, $option, $command );
    }
    # Reports by default and writes only when asked. History is the permanent
    # record of a board, and a record somebody's tooling quietly rewrites is not
    # evidence any more - so the repair is a flag somebody types, not a default.
    return $tira->doctor( %args, ( $option->{repair} ? ( repair => 1 ) : () ) )
      if $command eq 'doctor';

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
        require Tira::CLI::Records;
        return Tira::CLI::Records::record_create( $tira, \%args, $option );
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
    if ( $command eq 'dwell.report' ) {
        my %dwell = ( project => $args{project} );
        $dwell{type} = $args{type} if defined $args{type};
        return $tira->dwell_report(%dwell);
    }
    if ( $command eq 'check.owner' ) {
        return $tira->check_owner( project => $args{project}, ref => $args{ref} );
    }
    if ( $command eq 'card.holes' ) {
        my %holes = ( project => $args{project} );
        $holes{type} = $args{type} if defined $args{type};
        return $tira->card_holes(%holes);
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
    return $tira->changelog_check(%args) if $command eq 'changelog.check';
    return $tira->replace_records( %args, dry_run => $option->{dry_run} ) if $command eq 'replace';
    return $tira->project_show(%args) if $command eq 'project.show';

    # Reading and setting are one command, because the answer is one fact and
    # two commands would invite a board where it was set and never read.
    return { mode => $tira->project_mode(%args) } if $command eq 'project.mode';
    return { max => $tira->project_limit(%args) } if $command eq 'project.limit';
    if ( $command eq 'project.gates' ) {
        return { gates => $tira->project_gates(%args) } if !$option->{gate_names};
        return { gates => $tira->project_gates_set( %args, names => $option->{gate_names} ) };
    }
    return $tira->conversation_add(%args) if $command eq 'conversation.add';
    return $tira->conversation_list(%args) if $command eq 'conversation.list';
    return $tira->agent_sessions(%args) if $command eq 'agent.sessions';
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

    # Telling the owner a card moved, set once by the agent. His words: a
    # police sentry rather than an agent sentry, so the notifying costs no
    # tokens. TKT-349.
    if ( $command eq 'notify.moves' ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::notify_moves( $tira, \%args, $option );
    }
    if ( $command eq 'column.apply' ) {
        my $layout = eval { Tira::json_object()->utf8->decode( $option->{columns_json} // '' ) };
        die "A column layout must be JSON: a list of objects with a name\n" if ref $layout ne 'ARRAY';
        return $tira->column_apply( project => $args{project}, type => $args{type}, columns => $layout );
    }
    return $tira->column_sync( %args, apply => $option->{apply} ) if $command eq 'column.sync';

    if ( $command eq 'column.roles' ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::column_roles( $tira, \%args, $option );
    }

    if ( $command =~ /\Arecord\.(show|list|update|move|discard|restore|clone|missing)\z/ ) {
        my $action = $1;

        return $tira->record_missing(%args) if $action eq 'missing';

        # question.list computes a question's status (new/answered/discarded)
        # through Tira's own _question_view; record_show/record_show_many
        # return the stored entry as-is, which carries no status key at all -
        # a discarded question and a live one were distinguishable only by
        # discarded_at, invisible to a caller filtering on the documented
        # field. Applied here, at the CLI boundary, rather than inside
        # record_show itself: record_show is reused internally (by
        # question_update and others) as a fetch-then-mutate primitive, and a
        # view-shaped record fed back into _replace_record would write the
        # computed fields into storage. TKT-322.
        if ( $action eq 'show' && $args{refs} ) {
            my $result = $tira->record_show_many(%args);
            for my $record ( values %{ $result->{records} } ) {
                next if ref $record->{questions} ne 'ARRAY';
                $record->{questions} = [ map { Tira::_question_view($_) } @{ $record->{questions} } ];
            }
            return $result;
        }
        if ( $action eq 'show' ) {
            my $record = $tira->record_show(%args);
            $record->{questions} = [ map { Tira::_question_view($_) } @{ $record->{questions} } ]
              if ref $record->{questions} eq 'ARRAY';
            return $record;
        }
        return $tira->record_list(%args) if $action eq 'list';
        return $tira->record_update(%args) if $action eq 'update';
        if ( $action eq 'move' ) {

            # The CLI/agent path only - checked here, in the dispatch layer,
            # rather than inside record_move itself, so a direct engine call
            # (the browser dashboard's own move provider in browser_providers
            # calls record_move directly, never through here) is untouched.
            # The owner's own instruction: a human on the dashboard is not an
            # agent skipping a gate. TKT-426.
            my $blocked = _column_chain_violation( $tira, %args );
            die $blocked if defined $blocked;
            my $action_blocked = _column_required_action_violation( $tira, %args );
            die $action_blocked if defined $action_blocked;
            my $unjudged = _unjudged_answer_violation( $tira, %args );
            die $unjudged if defined $unjudged;

            # Last of the four, and deliberately so: it is the only one that
            # WRITES before it refuses, putting the destination's entry items
            # on the card so they can be worked from outside. Running it after
            # the others means a move refused for an unfinished exit action or
            # an unjudged answer does not also drag in a list belonging to a
            # column the card was never going to reach. TKT-591.
            my $entry_blocked = _column_entry_required_action_violation( $tira, %args );
            die $entry_blocked if defined $entry_blocked;

            my $before  = eval { $tira->record_show(%args) };
            my $from    = $before ? $before->{column} : undef;
            my $result  = $tira->record_move(%args);
            my $columns = _columns_for( $tira, \%args, $result );
            _apply_column_required_actions( $tira, \%args, $from, $args{column}, $columns, $result )
              if ref $columns eq 'ARRAY';
            _remind_one_at_a_time( $tira, \%args, $args{column} );
            _reset_linked_tasks_on_return( $tira, \%args, $args{column} );

            # Re-read rather than returning $result as-is: the required-action
            # population/reset above writes to the checklist after record_move
            # already captured its snapshot, so the caller's own output would
            # otherwise show the move without the side effect it just caused.
            return $tira->record_show(%args);
        }
        return $tira->record_discard(%args) if $action eq 'discard';
        return $tira->record_restore(%args) if $action eq 'restore';
        return $tira->record_clone(%args);
    }

    return $tira->gates_install(%args) if $command eq 'gates.install';
    return $tira->work_log(%args) if $command eq 'worklog.show';

    # policy.bridge.logs is the name; police.log is what it was called until
    # 1.41 and still answers, because renaming a shipped command breaks every
    # board that used it. tira.police runs the owner's watching loop and this
    # reads what that loop wrote - they shared a prefix and nothing else, which
    # cost another project's agent three corrections and, in between, every
    # suspension and escalation it should have been reading.
    if ( $command eq 'rule.suspend' ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::rule_suspend( $tira, \%args, $option );
    }

    # The definition of a complete card, for anything that is not this program.
    # The engine owns it; the push gate is python and cannot share a variable,
    # so it asks. TKT-241.
    if ( $command eq 'column.endings' ) {
        return $tira->column_endings(%args);
    }
    if ( $command eq 'card.required' ) {
        return Tira->card_required;
    }

    # What to pick up, from the board that already decided it. The ordering
    # belongs to priority-skipped, so it is asked rather than sorted again -
    # the rule and this command cannot give different answers. Reading every
    # card and sorting by hand was 1.95 MB of JSON on this project's own board
    # to find the eleven that were waiting. TKT-274.
    if ( $command eq 'next' ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::next_card( $tira, \%args, $option );
    }

    # What is still true, rather than everything that ever happened. The bridge
    # is a stream and the log is flat, so neither could answer it and the answer
    # depended on somebody remembering to look. TKT-237.
    # tira.police.outstanding is in Tira::CLI::Police - the ledger read, and
    # the --fresh pass that runs one inline before reading it. TKT-607.
    if ( $command eq 'police.outstanding' ) {
        require Tira::CLI::Police;
        return Tira::CLI::Police::police_outstanding( $tira, \%args, $option );
    }

    # When the last pass ran, rather than what it found. outstanding answers as
    # of the last pass and an empty list cannot carry when that was, so this is
    # the command that can - kept separate from the payload rather than folded
    # into it, because two other projects pipe and index that list. Q-096.
    # TKT-684.
    if ( $command eq 'police.freshness' ) {
        require Tira::CLI::Police;
        return Tira::CLI::Police::police_freshness( $tira, \%args, $option );
    }

    if (   $command eq 'police.suspend'
        || $command eq 'police.log'
        || $command eq 'policy.bridge.logs' )
    {
        require Tira::CLI::Police;
        my $store = $option->{store}
          // Tira::CLI::Police::_police_store( $tira->discover_project(%args) );
        return $tira->enforcement_log( %args, store => $store )
          if $command eq 'police.log' || $command eq 'policy.bridge.logs';
        my $quiet = $tira->police_suspend(
            %args, store => $store,
            seconds => $option->{seconds}, reason => $option->{reason} );

        # The owner sees every suspension as it happens, so quiet is never
        # something that simply occurs.
        print {*STDERR} "$quiet->{terminal}\n";
        return $quiet;
    }

    # tira.police and tira.policy.bridge are in Tira::CLI::Police - the pass
    # itself, and the line-buffered bridge that is left running for days.
    if ( $command eq 'police' || $command eq 'policy.bridge' ) {
        require Tira::CLI::Police;
        return Tira::CLI::Police::police_run( $tira, \%args, $option, $command );
    }

    # The police, bridge and dev-report verbs are in Tira::CLI::Police,
    # loaded when one of them actually runs rather than on every CLI
    # call. require is idempotent, so each entry into that module says
    # where it is going instead of relying on an earlier branch having
    # been taken. TKT-607.
    require Tira::CLI::Police;
    return Tira::CLI::Police::report_to_tira( $tira, \%args, $option )
      if $command eq 'dev.found.bug_or_improvement';

    # The four backup verbs are in Tira::CLI::Backup, loaded when one of them is
    # actually run. Named here as a concern rather than as four lines, which is
    # what makes this file an index: the reader learns that backup exists and
    # where it lives, without reading 249 lines of git plumbing to change
    # something else. TKT-607.
    if ( $command =~ /\Abackup(?:\.(?:restore|export|import))?\z/ ) {
        require Tira::CLI::Backup;
        return Tira::CLI::Backup::backup( $tira, \%args ) if $command eq 'backup';
        return Tira::CLI::Backup::backup_restore( $tira, \%args, $option ) if $command eq 'backup.restore';
        return Tira::CLI::Backup::backup_export( $tira, \%args, $option ) if $command eq 'backup.export';
        return Tira::CLI::Backup::backup_import( $tira, \%args, $option ) if $command eq 'backup.import';
    }

    return $tira->policy_decline(%args) if $command eq 'policy.decline';
    return $tira->policy_declined(%args) if $command eq 'policy.declined';

    # Repeated jobs. EPC-014, TKT-837 - bodies in Tira::CLI::Job.
    if ( $command =~ /\Ajob\.(?:add|list|update|delete|start|run|stop|feed)\z/ ) {
        require Tira::CLI::Job;
        return Tira::CLI::Job::dispatch( $tira, \%args, $option, $command );
    }

    # A parallel system to ticket/epic/sow, deliberately lighter - no gates,
    # checklists, or required-actions. TKT-504.
    return $tira->tasklist_list(%args) if $command eq 'tasklist.list';
    return $tira->tasklist_sessions(%args) if $command eq 'tasklist.sessions';
    return $tira->tasklist_add( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.add';
    return $tira->tasklist_update(%args) if $command eq 'tasklist.update';

    # TKT-507: array-list operations on the tasklist queue.
    return $tira->tasklist_next( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.next';
    return $tira->tasklist_shift(%args) if $command eq 'tasklist.shift';
    return $tira->tasklist_pop(%args) if $command eq 'tasklist.pop';
    return $tira->tasklist_unshift( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.unshift';
    return $tira->tasklist_slice( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.slice';
    return $tira->tasklist_remove(%args) if $command eq 'tasklist.remove';
    return $tira->tasklist_import(%args) if $command eq 'tasklist.import';

    # TKT-508: prune, per-item attach/ref sub-verbs.
    return $tira->tasklist_prune(%args) if $command eq 'tasklist.prune';
    return $tira->tasklist_task_attach_add( %args, files => $option->{files} // [] )
      if $command eq 'tasklist.task.attach.add';
    return $tira->tasklist_task_attach_discard( %args, files => $option->{files} // [] )
      if $command eq 'tasklist.task.attach.discard';
    return $tira->tasklist_task_ref_link( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.task.ref.link';
    return $tira->tasklist_task_ref_unlink( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.task.ref.unlink';

    # What the agent has not decided about. It is the only party that can
    # declare a policy, and police prints this for the owner rather than for it.
    return $tira->policy_undeclared(%args) if $command eq 'policy.undeclared';

    # The whole set in one place, for the review he does behind the agent.
    return $tira->policy_review(%args) if $command eq 'policy.review';

    if ( $command =~ /\Apolicy\.(add|list|remove)\z/ ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::policy_verbs( $tira, \%args, $option, $command );
    }

    if ( $command =~ /\Alogin\.(register|check|status|logout)\z/ ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::login_verbs( $tira, \%args, $option, $command );
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
        'release.record' => 'release_record',
        'checklist.list' => 'checklist_list', 'checklist.add' => 'checklist_add',
        'checklist.update' => 'checklist_update',
        'required-action.list' => 'required_item_list', 'required-action.add' => 'required_item_add',
        'required-action.update' => 'required_item_update',
        'search' => 'search', 'search.index' => 'search_index', 'dashboard' => 'dashboard',
        'dashboard.sow' => 'dashboard', 'dashboard.epic' => 'dashboard', 'dashboard.ticket' => 'dashboard',
        'outstanding' => 'outstanding_summary',
    );
    my $method = $method{$command} or die "Unsupported Tira command '$command'\n";

    # An option this command will not act on is refused rather than discarded.
    # The parser is shared, so every command sees every option, and the wrong
    # name looks accepted instead of unknown - assign.set took --assignee, threw
    # it away, printed the whole unchanged card and exited zero. A card sat in
    # implement for an hour with nobody on it because of that.
    #
    # Narrow on purpose. There is no per-command list of the options each one
    # uses, and inventing one for every command would refuse things that work
    # today. What is declared is the set where one option names the job another
    # option does, which is the set that misleads.
    # --blocking narrows the list to what would refuse a move out of the column
    # the card is in now. Without it required-action.list answers every item on
    # the card across every column - 75 on the card this was measured against -
    # so the only way to learn what is actually in the way was to attempt a move
    # and read the refusal.
    #
    # A flag on the existing command rather than a new verb, deliberately:
    # tira.card.required already exists and answers which FIELDS a complete card
    # needs, so a third similarly-named command would mislead. And the answer
    # comes from the same helper the refusal uses, so the two cannot drift into
    # telling an agent one thing and refusing it for another. TKT-598.
    return _outstanding_here( $tira, %args )
      if $command eq 'required-action.list' && $option->{blocking};

    $args{person} = $option->{people}[0] if $command =~ /\Aassign\.(?:add|remove)\z/ && $option->{people};
    $args{people} = $option->{people} // [] if $command eq 'assign.set';
    $args{recursive} = $option->{recursive} if $command eq 'hierarchy.show';
    if ( $command eq 'hierarchy.link' ) {
        $args{priority} = $option->{priority} if defined $option->{priority};
        $args{assignee} = $option->{assignee} if defined $option->{assignee};
    }
    # Argument preparation, not a command body: this block sets fields on %args
    # and FALLS THROUGH to the dispatch below. TKT-607 lifted it into
    # Tira::CLI::Board and turned `prepare and continue` into `prepare in
    # another package, discard, and return` - every browser and table board
    # came back with no column order at all. It is back where it belongs, and
    # tools/lift-block now refuses a block whose last statement is not a return.
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
    # Several files, one invocation. The cost this fixes is per command
    # RESOLUTION, not per attachment: measured on 2.64, an unknown tira command
    # costs 0.50s while the attachment work itself is about 0.05s, and a 400-card
    # board is no slower than a 1-card one. Six files in a shell loop was 3.87s,
    # of which roughly 3.0s was finding the command six times.
    #
    # So looping HERE is the whole fix and looping in a shell is what was slow -
    # which is why t/275 asserts this is one invocation rather than only that the
    # files arrived. Same shape as comment.add --attach below, which has batched
    # all along and which nothing documented as a batch. TKT-338.
    #
    # A file part-way through that cannot be read still dies - a bad path is
    # still a mistake worth stopping for - but the files attached before it are
    # returned rather than lost with the die, because his second ask was exactly
    # this: a killed batch should leave a readable record of how far it got,
    # not force reading the card back to find out what landed. Caught by testing
    # the failure path this card exists because of, rather than only the happy
    # one: the first version of this loop reported nothing at all on a partial
    # failure, reproducing in a new shape the blindness it was written to fix.
    if ( $command eq 'attachment.add' && $option->{files} && @{ $option->{files} } > 1 ) {
        require Tira::CLI::Board;
        return Tira::CLI::Board::attachment_add_files( $tira, \%args, $option );
    }

    if ( $command eq 'comment.add' && $option->{attach} ) {
        my $comment = $tira->$method(%args);
        $tira->comment_attach( %args, comment => $comment->{id}, file => $_ ) for @{ $option->{attach} };
        return $tira->comment_list(%args)->[-1];
    }
    return $tira->$method(%args);
}





# Running a program for its effect rather than its words. _reading throws the
# exit status away, which is right for reading the machine - a box with no
# Docker has no containers - and wrong for a backup, where "it did not work" is
# the only answer that matters.

# The schema this Tira understands. A board written by a newer one may hold
# shapes these readers have never seen, and no amount of care here can invent
# them - so it is refused rather than half-restored. The other direction needs
# nothing: an older board already works, because this codebase applies defaults
# on read instead of migrating.
our $SCHEMA_VERSION = 2;






































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
    require Tira::CLI::Usage;
    $message = Tira::CLI::Usage::_names_the_option($message);
    my $formatted = eval { $tira->format_output( { error => $message }, output => $output ) };
    $formatted = Tira::json_object()->canonical->pretty->encode( { error => $message } ) if !defined $formatted;
    print STDERR _utf8_bytes($formatted);
    return 2;
}

sub _utf8_bytes {
    my ($text) = @_;
    return utf8::is_utf8($text) ? encode_utf8($text) : $text;
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

=head1 THIS MODULE IS AN INDEX

Since 4.74 the command bodies are not here. C<Tira::CLI> holds what every
command passes through - C<run>'s argument handling, the one shared
C<GetOptions> table, the generic dispatch in C<_invoke>, and the four move
guards with the bookkeeping that follows a successful move - and the bodies live
in modules of their own:

    Tira::CLI::Browser   the provider hash a served board is built from
    Tira::CLI::Police    the pass, the bridge, the singleton, the world scan
    Tira::CLI::Serve     the machine - processes, containers, ports, hand-over
    Tira::CLI::Wizard    onboard's questions, and the line editor that asks them
    Tira::CLI::Backup    the four backup verbs, and the readers others ask
    Tira::CLI::Usage     usage lines, policy help, and "did you mean"
    Tira::CLI::Records   creating a record, and the question verbs
    Tira::CLI::Board     columns, the next card, logins, policies

Each is loaded with C<require> at the point one of its verbs actually runs, so
C<tira.ticket.list> compiles none of them and C<tira.backup> compiles two. Every
entry into a module carries its own C<require> rather than relying on an earlier
branch having been taken: C<require> consults C<%INC> and returns, so the
repetition is free, and a reader at any call site can see where control goes.

The dependencies between those modules are loaded the same way, inside the sub
that needs them rather than at the top of the file. A C<use> at the top is
correct and turns a lazy chain eager - C<Tira::CLI::Board> loading
C<Tira::CLI::Police> loading C<Tira::CLI::Serve> made C<tira.next> compile four
modules for the sake of one helper.

THE GUARDS DID NOT MOVE, and that is deliberate rather than incidental: their
call order is load-bearing, it is documented below under
L</The four guards on the move path>, and C<t/430> asserts that heading is still
in this file. A refactor that separates the guards from the sentence describing
them fails the build.

C<t/431> resolves every name every module uses - unqualified calls, code
references, qualified calls into packages nothing loads, and functions imported
only here. All four of those forms compile cleanly and die at runtime, and all
four happened while this split was being made.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

C<project.new> and C<onboard> share one branch, and it validates C<--mode>
before C<project_new> is called rather than after. The order is the point:
C<project_mode> runs once the project exists, so an invalid value used to
produce a failed command and a fully created project at the same time, with
nothing to roll back. The accepted values come from
C<onboarding_questions()> rather than being written out here, so the two
cannot disagree.

Moving a card into a column that carries required actions prints a reminder
naming how many arrived and to work them one at a time, each with its own
C<--command> and C<--proof>. It is the preventive half of TKT-583's refusal:
the reuse happens at the end of a column's work, holding a list nobody read
item by item, so the reminder lands at the moment the list arrives rather
than when the damage is already attempted. Printed to STDERR, so it stays out
of C<-o json> output, and only when the column actually brought outstanding
items - a reminder that fires on every move is one nobody reads. TSK-168.

C<@spec>, built at the top of this sub, is one flat list shared by every
command. Until 4.90 it declared C<'attach=s@'> twice (TKT-775) - harmless,
but Getopt::Long's own duplicate-specification warning bypasses the
C<$SIG{__WARN__}> capture below and printed to STDERR on every invocation.
One array for every command means a stray duplicate is noise on all of them.

=head2 _unmet_in_column

The one selection of what a card still owes a column: items tagged with that
column, minus the card's own exemptions (C<--exempt-required>, TKT-439), minus
anything already done - the comparison against C<done> being case-insensitive
so C<--status Done> is not read as outstanding (TKT-434).

Three readers call it: the move refusal, C<required-action.list --blocking>,
and - since 4.75 - the browser, through C<Tira::CLI::Browser>'s
C<unmet_in_column> provider and the C<unmet_in_column> field it sets on a
record. That matters more than the saved lines: the first version of TKT-598
left the refusal with its own copy of this grep while the comment beside it
claimed the two could not drift, which is a promise rather than a fact and is
exactly what codex review caught. An agent told one thing and refused for
another is the failure this shape prevents.

The third reader was the same temptation a second time. TKT-665's first attempt
counted the unmet items in JavaScript, which would have passed the test written
for it - that test asserts the provider agrees with this sub and says nothing
about what the dialog then does with the answer. C<isDone> in JavaScript against
C<_item_is_done> in Perl is precisely the drift TKT-657 fixed. The rule this
sub exists to enforce is that nobody else decides what a column still owes.

=head2 _outstanding_here

Answers what is blocking a card in the column it currently occupies, without a
move being attempted. C<required-action.list --blocking> is the way an agent
asks; without it that command returns every item on the card across every
column - 75 on the card this was measured against - so being refused was the
only way to find out.

The record must exist. Turning a failed read into an empty list would answer
"nothing is blocking you" for a ref that is missing, misspelled or unreadable,
and answer it with exit 0, while the same command without C<--blocking> reports
that the record was not found. Codex review probed exactly that. A question
about a card that is not there has no answer, so the error travels.

Deliberately not named after C<tira.card.required>, which already exists and
answers which FIELDS a complete card needs. TKT-598.

=head2 The four guards on the move path

Four guards run on every move, in this order, and the first to refuse is the
only refusal a caller ever sees - each returns early, so a card failing two of
them is told about one.

  1  _column_chain_violation              did it come the way the board says
  2  _column_required_action_violation    is the column it is LEAVING finished
  3  _unjudged_answer_violation           is an answer still waiting on a judge
  4  _column_entry_required_action_violation  is the column it is ENTERING ready
     for it

The order is worth knowing because it is not the order a reader guesses. Entry
is checked LAST, after the chain, the exit actions and the unjudged answer -
so a card that has skipped a column and also has an unmet entry item is told
about the chain, and only meets the entry list once the earlier refusals are
cleared.

All four decline to interfere with the same three things: a move to C<discard>,
a move that does not change column, and a backward move. A retreat is
unconditional by TKT-455's design, because what is unmet may be exactly what
the card is going back to fix.

=head2 _column_chain_violation

Refuses a move that does not follow the order the board declares - "the next
column should be X", or "should be X or Y" where a column names a fork with
C<tira.column.update --next>. It compares the position of the column being left
with the position of the one being entered, so a card cannot jump a column by
naming a later one.

=head2 _column_required_action_violation

Refuses to let a card LEAVE a column while that column's required actions are
unfinished, naming each unmet item with its id so the refusal can be acted on
rather than only understood. Forward moves only.

=head2 _unjudged_answer_violation

Refuses to move a card forward while a question on it has an answer nobody has
judged. An answer that has been given and not read is not the same as a question
resolved, and this is the gate that says so. Forward moves only, for the reason
above: the person who would judge it may be why the card is going back.

=head2 _column_entry_required_action_violation

The gate for what a card must ALREADY have done before it may be worked in a
column, declared with C<tira.column.update --entry-required-action>. Where
C<_column_required_action_violation> asks what is unfinished in the column being
LEFT, this asks what is unmet in the column being ENTERED - two of the four
guards above, not a pair on their own. The two
are separate templates because they answer different questions: the owner's
example is work belonging to neither column - "verify all details in the card",
between backlog and tests-red - which cannot be expressed as an exit action on
the column before it.

The destination's items are put on the card BEFORE the refusal, which is what
makes an entry gate satisfiable. The work happens outside the column that
demands it, so a list appearing only once the card was inside would leave
nothing to mark and no way in. The first attempt brings the list and refuses;
the second, once the items carry their evidence, goes through.

Forward moves only, like every other gate here: a card being sent back is not
asked to qualify for where it is retreating to (TKT-455).

A population that fails refuses the move rather than allowing it. Written first
as a bare C<eval>, which did the one thing this must never do - a column
declared with an empty entry action stored it, C<required_item_add> refused the
blank item, the error went nowhere, and the card walked in past a gate that
believed it had nothing to enforce.

=head2 _item_is_done

Whether a required item's status means finished, asked in one place.

Four call sites compared a status against C<done> by hand - the entry gate,
C<_outstanding_here>, the exit gate and C<_remind_one_at_a_time> - and the last
of them did not lowercase first. An item marked C<Done>, the capital the CLI
accepts and which TKT-434 deliberately made the gates tolerate, was therefore
finished to every gate and outstanding to the move-in reminder.

Nothing is normalised on write: C<Done> stays C<Done> on the card and this is
the one place that reads it. Undoing that would undo TKT-434, so t/422 pins the
stored value as well as the comparison.

A predicate rather than a corrected expression because the fault had recurred
three times in a day across the dashboard, C<tools/card-holes> and here, and
four inline comparisons cannot be guarded as a set - a named predicate can be
grepped for, which is what makes a fourth drift catchable. TKT-657.

=head2 _stamp_attachment_types

Puts C<content_type> on the attachments the card dialog is about to be shown.

The browser viewer decides whether a file can be rendered as text from that
field and from nothing else - it holds no extension list of its own, which is
what TKT-645 was for. C<record_show> does not compute the field, so the dialog
was asking a question its payload could not answer and offering the download
message for every source file on every real card.

C<record_show> is deliberately left alone. Computing a content type stats the
stored file and sometimes reads its first 8KB, and a record is read on every
gate, every police pass and every board render; C<attachment_list> already
computes it, from the one implementation, when asked. So the type is fetched
there and stamped on by C<sha> and extension together - attachments are
content-addressed, so the same bytes under two names share a sha while
legitimately needing different types, and a valid SVG is also valid text.

Comment, question, voice and answer attachments are stamped as well: the viewer
opens them from the same strip and has no way to tell where an entry came from.

Failure is silent on purpose. An attachment store that cannot be read costs the
preview, not the card - the alternative is a dialog that will not open at all.
TKT-645.

=head2 _populate_entry_required_actions

Puts a column's entry template on a card without deciding anything about
whether the card may be there, and returns what it could NOT add as
C<[text, why]> pairs rather than swallowing the failure.

Called from three places, and the third arrived late. The CLI move guard and
the browser move provider both call it on the way in; C<record.create> did not,
so a card created straight into a gated column received no entry items and was
born past a gate it could never be asked to pass. Creation calls it now, and
does NOT refuse on what it returns - a required action's proof is a command and
its output, and before the card exists there is nothing to run a command
against, so the items are recorded pending and the caller is told on STDERR.
What it could not place is reported there with its reason and left out of the
list the caller is told it owes, so the message never names an item that is not
on the card. TKT-681.

Shared by the gate above and by the browser move provider, and the split is
TKT-452's: the gating half is CLI-only, because a human dragging a card is not
an agent skipping a gate (TKT-426), but keeping the card accurate for whoever
reads it next is not enforcement and has to happen either way. A card dragged
into a column would otherwise carry that column's exit actions and none of its
entry ones - a card that misreports what was asked of it.

The caller decides what a failure means. The gate refuses on it. The browser
provider cannot - it has already moved the card and answers a dashboard that
has no way to show a refusal - so it writes what it could not place to STDERR,
where whoever runs the dashboard will find it in the server log. Neither
swallows it, which is the only property that matters here. TKT-591.

=head2 _columns_for

Returns the column list for the board a record belongs to, given the parsed
arguments and, when the caller already has it, the record itself. The board
type is taken from C<--type> when supplied, then from the record in hand, and
failing both by resolving the ref through C<record_show>.

Every move guard begins by asking which columns exist and returns C<undef> -
meaning "nothing to refuse" - when it cannot find out. C<column_list> needs a
concrete type; C<record_move> and C<record_show> do not, because they resolve a
record by ref alone. A caller who omitted C<--type> therefore got a move that
succeeded and a gate that never ran. Reproduced on a copy of a real board: a
card walked from backlog to in-review through nine gated columns with 75
required actions pending and not one refusal.

Four call sites use it: the three move guards - chain order, required actions,
unjudged answers - and the post-move required-action bookkeeping. The browser
move provider recovers the type its own way, from the record C<record_move>
just returned, and is where the principle came from: a caller is never required
to say what the engine can already tell for itself (TKT-532). It is left as it
is because it works and predates this; consolidating the two is a separate
change.

Recovering the type is about knowing which columns exist, not about refusing
the caller: a typeless move whose required actions are satisfied still goes
through. When the ref resolves to nothing the return is not an arrayref and the
guard returns C<undef> - "nothing to refuse" - exactly as it did before. That
is not the guard failing closed: the move fails afterwards because the record
does not exist, which is a different mechanism doing the stopping. TKT-597.

=head2 browser_providers

Returns the flat hash of named coderefs L<Tira::DashboardWeb> requires to build
its Dancer2 app - one entry per route, so a browser mutation can never drift
from the engine's own validated command surface.

The coderefs themselves are in L<Tira::CLI::Browser>, and this loads that module
with C<require> when a board is actually served rather than with C<use> at the
top - the shape this file already used for L<Tira::DashboardWeb> and
L<Tira::OnboardWeb>. They were 701 lines of the 6,048 that had to be read to
change any command at all, needed by the one invocation that serves a board.

THE NAME IS THE FRONT DOOR AND DID NOT MOVE. Twenty test files and the dashboard
call C<Tira::CLI::browser_providers>, so it still exists and still answers. What
each provider does, and the TKT-516 and TKT-540 history of the tasklist ones, is
documented where the code is. TKT-607.

=head2 The --dry-run allow-list

C<--dry-run> is read by two commands, C<import> and C<replace>, and parsed by
all of them, because one global option spec serves every command. Every command
but those two therefore accepted the flag and wrote anyway:
C<tira.ticket.create --dry-run> created the card and printed it back as though
nothing unusual had been asked, which cost eight junk cards on the Tira board
itself - TKT-617 through TKT-624, all discarded afterwards.

The refusal is written as an allow-list naming the two readers rather than a
list of the commands that swallowed the flag. A list of offenders can only ever
cover the verbs somebody thought of, and the deliverable was every verb that
shares the fault; naming the readers refuses the rest by construction, so
C<tira.comment.add --dry-run> is refused by the same line as
C<tira.ticket.create --dry-run> without ever being named. That shape is
available only because this flag has exactly two readers. It is not the general
per-command option catalogue C<%MISLEADING_OPTIONS> declines to be, and the
reason it declines is unchanged: there is no way to derive which options each
command reads, so a general version would refuse things that work today.

C<%MISLEADING_OPTIONS> and C<%OPTION_READ_BY> live in L<Tira::CLI::Options> as
of TKT-837, lifted to make room under F<t/430>'s cap. C<_refuse_unread_options>
keeps a forwarder in this package on purpose: three test files disable the
guard by localising it here to prove what the refusal is worth, and calling the
lifted subroutine at its new address moved the name out from under them.

Its position is the other half. Written beside the C<%method> dispatch, where
the misleading-option guard was, it would not have run for the create verbs at
all - C<record.*> returns from the if/elsif chain some seven hundred lines
earlier - which is how the fix was discovered to change nothing at first. Both
guards now sit in the block every command passes through. TKT-625.

=head2 run's onboard -o browser branch

TKT-517: C<-o browser> is accepted for the C<onboard> command as well as
C<dashboard>. Rather than the interactive STDIN wizard, C<run> starts a
disposable L<Tira::OnboardWeb> server (via the injectable
C<onboard_browser_server> seam, C<_serve_onboard_browser> by default) on
C<127.0.0.1> and a dynamically-picked free port (C<_free_port>), unless an
explicit C<-o browser=host:port> was given. Its C<create> provider calls
back into the exact C<_invoke($tira, 'onboard', undef, \%merged)> dispatch
the interactive wizard's own answers reach, so nothing forks into a second,
divergent project-creation path. TKT-527: an explicit C<-o browser=0.0.0.0:PORT>
is refused for C<onboard> specifically (naming why) - this server has no
login, so C<0.0.0.0> would be a genuinely unauthenticated project-creation
endpoint; C<127.0.0.1>/C<localhost>/the plain default are unaffected, and
C<dashboard>'s own C<0.0.0.0> handling (a separate branch) is untouched.

=cut
